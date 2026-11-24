import Foundation
import Security

struct DemoAccessConfiguration: Codable, Sendable {
    let endpoint: URL
    let token: String

    init(address: String, token: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              token.utf8.count == 72,
              token.range(of: #"^bx_demo_[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw FieldExplanationRequestError.blocked("请填写有效的 HTTPS 服务地址和演示凭证。")
        }
        self.endpoint = url
        self.token = token
    }
}

enum DemoAccessKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.biaoxia.demo-access",
         kSecAttrAccount as String: "relay"]
    }

    static func load() throws -> DemoAccessConfiguration? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw storageError }
        let value = try JSONDecoder().decode(DemoAccessConfiguration.self, from: data)
        // Revalidate persisted data before sending a bearer credential.
        return try DemoAccessConfiguration(address: value.endpoint.absoluteString, token: value.token)
    }

    static func save(_ configuration: DemoAccessConfiguration) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(configuration),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw storageError }
        } else if status != errSecSuccess { throw storageError }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError }
    }

    private static var storageError: FieldExplanationRequestError {
        .blocked("无法访问安全存储，请解锁设备后重试。")
    }
}

// A redirect must never move credentials or reviewed field text to another URL.
final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private static let session = URLSession(
        configuration: .ephemeral, delegate: RelaySessionDelegate(), delegateQueue: nil
    )

    static func makeSession() -> URLSession { session }
}

struct DemoAccessStatus: Decodable, Sendable {
    let expiresAt: Double
    let limitScope: String
    let requestsPerMinute: Int
}

enum DemoAccessService {
    static func status(for configuration: DemoAccessConfiguration,
                       session: URLSession = RelaySessionDelegate.makeSession()) async throws -> DemoAccessStatus {
        var request = URLRequest(url: configuration.endpoint.appending(path: "v1/demo-access/status"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FieldExplanationRequestError.invalidResponse }
        guard http.statusCode == 200 else { throw responseError(status: http.statusCode, data: data) }
        let result = try JSONDecoder().decode(DemoAccessStatus.self, from: data)
        guard result.expiresAt.isFinite, result.expiresAt > 0,
              result.limitScope == "process", (1...60).contains(result.requestsPerMinute) else {
            throw FieldExplanationRequestError.invalidResponse
        }
        return result
    }

    static func responseError(status: Int, data: Data, serviceName: String = "字段解释") -> FieldExplanationRequestError {
        struct Failure: Decodable { let error: String }
        let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error
        switch code {
        case "DEMO_EXPIRED": return .blocked("演示已到期，请联系演示提供者延期。仍可人工填写和导出。")
        case "DEMO_REVOKED": return .blocked("演示权限已撤销，仍可人工填写和导出。")
        case "DEMO_INVALID": return .blocked("演示凭证无效，请在首页的演示访问中重新配置。")
        case "DEMO_DAILY_LIMIT": return .blocked("今日演示额度已用完，北京时间零点重置。仍可人工填写和导出。")
        case "DEMO_GLOBAL_LIMIT": return .blocked("今日云端演示总额度已用完，仍可人工填写和导出。")
        case "DEMO_RATE_LIMIT", "DEMO_BUSY": return .retryable("请求较频繁或上一次解释仍在处理，请稍后重试。", beforeModel: true)
        case "DEMO_DISABLED": return .blocked("云端演示已暂停，仍可人工填写和导出。")
        case "UPSTREAM_BALANCE": return .blocked("云端服务余额不足，请联系演示提供者。仍可人工填写和导出。")
        case "UPSTREAM_AUTH": return .blocked("云端服务配置异常，请联系演示提供者。仍可人工填写和导出。")
        case "DEMO_UNAVAILABLE", "UPSTREAM_RATE_LIMIT": return .retryable("云端暂不可用，请稍后重试或人工继续。")
        case "FORM_PLAN_TIMEOUT": return .retryable("整表填写的模型响应超时，请稍后重试，或减少本次字段与资料。")
        case "FORM_PLAN_OUTPUT_LIMIT": return .retryable("整表答案超过单次生成长度，请减少本次字段后重试。")
        case "FORM_PLAN_INVALID_JSON": return .retryable("整表填写的模型返回格式不完整，未采用答案，请重试。")
        case "FORM_PLAN_INVALID_OUTPUT": return .retryable("整表答案未通过格式或来源依据校验，未采用答案，请重试或人工填写。")
        case "FORM_PLAN_UPSTREAM": return .retryable("整表填写的上游模型服务异常，请稍后重试。")
        default:
            if status == 408 || status == 429 || status >= 500 {
                return .retryable("\(serviceName)服务暂时不可用（\(status)）。")
            }
            return .blocked("\(serviceName)请求被拒绝（\(status)）。请检查演示访问配置，或人工继续。")
        }
    }
}

actor ConfiguredFieldExplanationService: ReviewedFieldExplanationSubmitting {
    private let debugFallback = RelayFieldExplanationService.configuredForDebugRun()

    func explain(draft: FieldExplanationDraft) async throws -> [String: FieldMeaning] {
        // Load on every request so changing or removing access takes effect without
        // resetting the current form, profile, or outbound review decisions.
        if let configuration = try DemoAccessKeychain.load() {
            return try await RelayFieldExplanationService(
                endpoint: configuration.endpoint, clientToken: configuration.token, version: 2
            ).explain(draft: draft)
        }
        if let debugFallback { return try await debugFallback.explain(draft: draft) }
        throw FieldExplanationRequestError.blocked("尚未配置演示访问；可在首页配置，或在本机人工继续。")
    }
}
