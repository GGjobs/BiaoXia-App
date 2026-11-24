import Foundation
import Testing
@testable import BiaoXia

struct DemoAccessTests {
    private let token = "bx_demo_" + String(repeating: "a", count: 64)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEMO_ACCESS_LIVE"] == "1"))
    func liveCredentialSurvivesKeychainRoundTripAndRemoval() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["BIAOXIA_RELAY_BASE_URL"],
              let token = environment["BIAOXIA_RELAY_CLIENT_TOKEN"] else {
            Issue.record("Live configuration missing")
            return
        }
        let previous = try DemoAccessKeychain.load()
        defer {
            do {
                if let previous { try DemoAccessKeychain.save(previous) }
                else { try DemoAccessKeychain.remove() }
            } catch { Issue.record("Could not restore Keychain state") }
        }
        let configuration = try DemoAccessConfiguration(address: address, token: token)
        let status = try await DemoAccessService.status(for: configuration)
        #expect(status.expiresAt > Date().timeIntervalSince1970)
        #expect(status.limitScope == "process")
        try DemoAccessKeychain.save(configuration)
        let stored = try DemoAccessKeychain.load()
        let loaded = try #require(stored)
        // Keep credential values out of assertion diagnostics.
        let matches = loaded.token == token && loaded.endpoint == configuration.endpoint
        #expect(matches)
        let refreshed = try await DemoAccessService.status(for: loaded)
        #expect(refreshed.expiresAt == status.expiresAt)
        try DemoAccessKeychain.remove()
        let removed = try DemoAccessKeychain.load() == nil
        #expect(removed)
    }

    @Test func rejectsUnsafeEndpointsAndMalformedCredentials() throws {
        for address in ["http://example.invalid", "https://user:secret@example.invalid", "https://example.invalid?token=secret", "https://example.invalid/#secret", "relative/path"] {
            #expect(throws: FieldExplanationRequestError.self) {
                try DemoAccessConfiguration(address: address, token: token)
            }
        }
        for value in ["", "shared-token", "bx_demo_short", token + "\n"] {
            #expect(throws: FieldExplanationRequestError.self) {
                try DemoAccessConfiguration(address: "https://example.invalid", token: value)
            }
        }
        let configuration = try DemoAccessConfiguration(address: "https://example.invalid/relay", token: token)
        #expect(configuration.endpoint.appending(path: "v1/explain-fields").path == "/relay/v1/explain-fields")
    }

    @Test func demoErrorsPreserveManualRecoveryAndDistinguishBilling() {
        for code in ["DEMO_EXPIRED", "DEMO_REVOKED", "DEMO_DAILY_LIMIT", "DEMO_GLOBAL_LIMIT", "DEMO_DISABLED", "UPSTREAM_BALANCE", "UPSTREAM_AUTH"] {
            let data = Data("{\"error\":\"\(code)\"}".utf8)
            let error = DemoAccessService.responseError(status: 503, data: data)
            if case .blocked(let message) = error { #expect(message.contains("人工")) }
            else { Issue.record("Expected blocked error for \(code)") }
        }
        let billing = DemoAccessService.responseError(status: 503, data: Data(#"{"error":"UPSTREAM_BALANCE"}"#.utf8))
        #expect(billing.localizedDescription.contains("余额不足"))
    }

    @Test func unknownServerTextIsNeverShownToUser() {
        let error = DemoAccessService.responseError(status: 503, data: Data(#"{"error":"private upstream response"}"#.utf8))
        #expect(!error.localizedDescription.contains("private upstream"))
        if case .retryable = error {} else { Issue.record("Expected retryable unavailable error") }
    }

    @Test func formPlanFailuresExplainTheStageWithoutAutomaticResending() {
        for (code, expected) in [("FORM_PLAN_TIMEOUT", "超时"), ("FORM_PLAN_OUTPUT_LIMIT", "生成长度"),
                                 ("FORM_PLAN_INVALID_JSON", "格式不完整"), ("FORM_PLAN_INVALID_OUTPUT", "来源依据校验"),
                                 ("FORM_PLAN_UPSTREAM", "上游模型服务异常"), ("RESOLUTION_UNAVAILABLE", "整表填写服务")] {
            let error = DemoAccessService.responseError(status: 502,
                data: Data("{\"error\":\"\(code)\"}".utf8), serviceName: "整表填写")
            #expect(error.localizedDescription.contains(expected))
            #expect(!error.localizedDescription.contains("字段解释"))
            if case .retryable(_, beforeModel: false) = error {} else { Issue.record("Must not automatically resend model attempts") }
        }
    }
}
