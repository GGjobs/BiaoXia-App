import Foundation

actor RelayAnswerCompositionService: AnswerComposing {
    let endpoint: URL
    let token: String
    let session: URLSession
    init(endpoint: URL, token: String, session: URLSession = RelaySessionDelegate.makeSession()) {
        self.endpoint = endpoint; self.token = token; self.session = session
    }
    func compose(_ payload: AnswerCompositionRequest) async throws -> AnswerCompositionResponse {
        guard payload.schemaVersion == 1, !payload.fieldLabel.isEmpty, payload.fieldLabel.count <= 300,
              payload.instructions.count <= 2000, !payload.sources.isEmpty, payload.sources.count <= 20,
              payload.sources.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 8000 }) else {
            throw FieldExplanationRequestError.blocked("请检查字段说明和所选片段；单次最多选择 20 条资料。")
        }
        let body = try JSONEncoder().encode(payload)
        guard body.count <= 32 * 1024 else { throw FieldExplanationRequestError.blocked("选中内容过长，请减少片段后发送。") }
        var request = URLRequest(url: endpoint.appending(path: "v1/compose-answer"))
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 50
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FieldExplanationRequestError.invalidResponse }
        if http.statusCode == 404 { throw FieldExplanationRequestError.blocked("当前云端尚未提供答案整理，请继续使用本地填写。") }
        guard http.statusCode == 200 else { throw DemoAccessService.responseError(status: http.statusCode, data: data) }
        let result = try JSONDecoder().decode(AnswerCompositionResponse.self, from: data)
        let validIDs = Set(payload.sources.map(\.id))
        guard result.schemaVersion == 1, result.requestId == payload.requestId,
              Set(result.sourceIDs).isSubset(of: validIDs), Set(result.sourceIDs).count == result.sourceIDs.count,
              result.missingInformation.count <= 10, result.missingInformation.allSatisfy({ $0.count <= 300 }),
              result.answer.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= min(payload.maximumCharacters ?? 8000, 8000) && !result.sourceIDs.isEmpty }) ?? result.sourceIDs.isEmpty else {
            throw FieldExplanationRequestError.invalidResponse
        }
        return result
    }
}

actor ConfiguredAnswerCompositionService: AnswerComposing {
    func compose(_ request: AnswerCompositionRequest) async throws -> AnswerCompositionResponse {
        if let configuration = try DemoAccessKeychain.load() {
            return try await RelayAnswerCompositionService(endpoint: configuration.endpoint, token: configuration.token).compose(request)
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let address = environment["BIAOXIA_RELAY_BASE_URL"], let endpoint = URL(string: address), endpoint.scheme == "https",
           let token = environment["BIAOXIA_RELAY_CLIENT_TOKEN"], !token.isEmpty {
            return try await RelayAnswerCompositionService(endpoint: endpoint, token: token).compose(request)
        }
        #endif
        throw FieldExplanationRequestError.blocked("请先在首页配置演示访问；也可继续本地填写。")
    }
}
