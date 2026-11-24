import Foundation
import Testing
@testable import BiaoXia

@Suite(.serialized)
struct T09BOutboundPrivacyTests {
    private let parser = PDFFormEngine()
    private let builder = FieldExplanationRequestBuilder()

    @Test func realPrivacyPDFProducesOnlyReviewedAnonymousFieldText() async throws {
        let sourceURL = fixture("boundary/B03.pdf")
        let document = try await parser.parse(formURL: sourceURL)
        var draft = builder.makeDraft(fields: document.fields)

        #expect(!draft.texts.isEmpty)
        #expect(draft.texts.allSatisfy { $0.state == .pendingReview })
        draft.allowAllPending()
        let request = try builder.build(from: draft)
        let body = try JSONEncoder().encode(request)
        let bodyText = String(decoding: body, as: UTF8.self)

        for forbidden in privacyMarkers(sourceURL: sourceURL) {
            #expect(!bodyText.contains(forbidden))
        }
        #expect(!bodyText.contains("anchors"))
        #expect(!bodyText.contains("answer"))
        #expect(!bodyText.contains("fingerprint"))
    }

    @Test func prefilledValueAndFilenameNeverEnterRequestAfterRestore() async throws {
        let sourceURL = fixture("boundary/B01_FICTIONAL_苏若岚.pdf")
        let document = try await parser.parse(formURL: sourceURL)
        var draft = builder.makeDraft(fields: document.fields)
        draft.allowAllPending()

        let persisted = try JSONEncoder().encode(draft)
        let restored = try JSONDecoder().decode(FieldExplanationDraft.self, from: persisted)
        let request = try builder.build(from: restored)
        let bodyText = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

        #expect(!bodyText.contains("苏若岚"))
        #expect(!bodyText.contains(sourceURL.lastPathComponent))
        #expect(request.fields.allSatisfy { field in
            field.label != nil || field.section != nil || field.instructions != nil || !field.options.isEmpty
        })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["T09B_LIVE_RELAY"] == "1"))
    func liveRelayAcceptsProductionRequestFromRealPDF() async throws {
        let configuration = try liveRelayConfiguration()
        let sourceURL = fixture("boundary/B03.pdf")
        let document = try await parser.parse(formURL: sourceURL)
        var draft = builder.makeDraft(fields: document.fields)
        draft.allowAllPending()

        let service = RelayFieldExplanationService(
            endpoint: configuration.baseURL,
            clientToken: configuration.token,
            session: URLSession(configuration: .ephemeral)
        )
        let meanings = try await service.explain(draft: draft)

        #expect(!meanings.isEmpty)
        #expect(Set(meanings.keys).isSubset(of: Set(document.fields.map(\.id))))
    }

    @Test(
        "Unsupported PDFs retain a local limitation without constructing an outbound draft",
        arguments: ["boundary/B05.pdf", "boundary/B06.pdf"]
    )
    func unsupportedPDFStopsBeforeOutboundReview(relativePath: String) async throws {
        do {
            _ = try await parser.parse(formURL: fixture(relativePath))
            Issue.record("不支持的 PDF 不应进入字段解释请求构造。")
        } catch let error as PDFFormEngineError {
            guard case .limitation(.scannedOrMixedContent, _) = error else {
                Issue.record("应保留扫描或混合内容限制，实际为：\(error)")
                return
            }
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["T09B_LIVE_RELAY"] == "1"),
        arguments: ["boundary/B03.pdf", "boundary/B01_FICTIONAL_苏若岚.pdf"]
    )
    func liveRelayRetryAuditsActualHTTPAndDiskRestoration(relativePath: String) async throws {
        let configuration = try liveRelayConfiguration()
        let sourceURL = fixture(relativePath)
        let document = try await parser.parse(formURL: sourceURL)
        var draft = builder.makeDraft(fields: document.fields)
        draft.allowAllPending()
        let diskURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("t09b-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diskURL) }
        try JSONEncoder().encode(draft).write(to: diskURL, options: .atomic)

        T09BAuditedTransport.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [T09BAuditedTransport.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let service = RelayFieldExplanationService(
            endpoint: configuration.baseURL, clientToken: configuration.token, session: session
        )
        do {
            _ = try await service.explain(draft: draft)
            Issue.record("Injected transport failure must not report success.")
        } catch let error as FieldExplanationRequestError {
            guard case .retryable = error else {
                Issue.record("Transport timeout must remain retryable.")
                return
            }
        }

        let restored = try JSONDecoder().decode(
            FieldExplanationDraft.self, from: Data(contentsOf: diskURL)
        )
        #expect(restored.requestID == draft.requestID)
        let meanings = try await service.explain(draft: restored)
        #expect(!meanings.isEmpty)
        #expect(Set(meanings.keys).isSubset(of: Set(document.fields.map(\.id))))
        let bodies = T09BAuditedTransport.bodies
        #expect(bodies.count == 2)
        let expectedRequest = try builder.build(from: restored)
        for body in bodies {
            let text = String(decoding: body, as: UTF8.self)
            for marker in privacyMarkers(sourceURL: sourceURL) {
                #expect(!text.contains(marker))
            }
            let request = try JSONDecoder().decode(FieldExplanationRequest.self, from: body)
            #expect(request == expectedRequest)
        }
        if let serverLog = T09BAuditedTransport.serverLog {
            for marker in privacyMarkers(sourceURL: sourceURL) {
                #expect(!serverLog.contains(marker))
            }
            for text in restored.texts where !text.value.isEmpty {
                #expect(!serverLog.contains(text.value))
            }
            let logRecords = serverLog.split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}") else { return nil }
                return (try? JSONSerialization.jsonObject(with: Data(line[start...end].utf8))) as? [String: Any]
            }
            let matchingLog = try #require(logRecords.first {
                ($0["requestId"] as? String)?.lowercased() == restored.requestID.uuidString.lowercased()
            })
            #expect(Set(matchingLog.keys).isSubset(of: Set([
                "requestId", "durationMs", "statusCode", "model", "attempts", "tokenUsage"
            ])))
            #expect(matchingLog["statusCode"] as? Int == 200)
        }

        // A recovered draft is untrusted: persist a newly blocked item and ensure
        // production validation rejects it before this session receives a request.
        var blocked = restored
        let index = try #require(blocked.texts.indices.first)
        blocked.texts[index].state = .blocked
        try JSONEncoder().encode(blocked).write(to: diskURL, options: .atomic)
        let blockedRestored = try JSONDecoder().decode(
            FieldExplanationDraft.self, from: Data(contentsOf: diskURL)
        )
        do {
            _ = try await service.explain(draft: blockedRestored)
            Issue.record("A blocked recovered draft must not be sent.")
        } catch is FieldExplanationRequestError {
            #expect(T09BAuditedTransport.bodies.count == 2)
        }
        print("T09-B audited live retry passed; requestID=\(restored.requestID); injectedTimeout=1; realResponses=1; blockedBeforeHTTP=1; serverLogAvailable=\(T09BAuditedTransport.serverLog != nil)")
    }

    private func privacyMarkers(sourceURL: URL) -> [String] {
        [
            "苏若岚",
            "FICTIONAL_HIDDEN_星屿实验室",
            "FICTIONAL_COMMENT_苏若岚",
            "FICTIONAL_METADATA_苏若岚",
            sourceURL.lastPathComponent
        ]
    }

    private func liveRelayConfiguration() throws -> (baseURL: URL, token: String) {
        let values = try secretsConfiguration()
        guard let rawURL = values["RELAY_BASE_URL"],
              let configuredURL = URL(string: rawURL),
              let token = values["RELAY_CLIENT_TOKEN"],
              !token.isEmpty,
              !rawURL.contains("example") else {
            throw FieldExplanationRequestError.blocked("未配置真实 Relay。")
        }
        let legacyPaths = ["/v1/resolve-fields", "/v1/extract-profile"]
        let baseURL = legacyPaths.contains(configuredURL.path)
            ? configuredURL.deletingLastPathComponent().deletingLastPathComponent()
            : configuredURL
        return (baseURL, token)
    }

    private func secretsConfiguration() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Secrets.xcconfig")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].hasPrefix("//") else { return }
            result[parts[0]] = parts[1]
                .replacingOccurrences(of: "$()", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    private func fixture(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TestAssets/GeneralForms/debug/\(relativePath)")
    }
}

/// Captures the exact production HTTP body without logging it. Only the first
/// transport attempt is injected; the second is forwarded to the real Relay.
private final class T09BAuditedTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var capturedBodies: [Data] = []
    private nonisolated(unsafe) static var capturedServerLog: String?
    private var forwardingTask: Task<Void, Never>?

    static var bodies: [Data] { lock.withLock { capturedBodies } }
    static var serverLog: String? { lock.withLock { capturedServerLog } }
    static func reset() { lock.withLock { capturedBodies = []; capturedServerLog = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let injectFailure = Self.lock.withLock {
            Self.capturedBodies.append(body)
            return Self.capturedBodies.count == 1
        }
        if injectFailure {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        var forwarded = request
        forwarded.httpBodyStream = nil
        forwarded.httpBody = body
        // FC can return this invocation's log tail without enabling SLS storage.
        forwarded.setValue("Tail", forHTTPHeaderField: "X-Fc-Log-Type")
        forwardingTask = Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: forwarded)
                if let encoded = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Fc-Log-Result"),
                   let logData = Data(base64Encoded: encoded), let log = String(data: logData, encoding: .utf8) {
                    Self.lock.withLock { Self.capturedServerLog = log }
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() { forwardingTask?.cancel() }
}
