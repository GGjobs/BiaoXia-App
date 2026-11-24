import Foundation

actor RelayFormPlanningService: FormPlanning {
    let endpoint: URL
    let token: String
    let session: URLSession
    init(endpoint: URL, token: String, session: URLSession = RelaySessionDelegate.makeSession()) {
        self.endpoint = endpoint; self.token = token; self.session = session
    }
    func plan(_ payload: FormPlanRequest) async throws -> FormPlanResponse {
        try FormPlanRules.validate(payload)
        var request = URLRequest(url: endpoint.appending(path: "v1/plan-form"))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(payload); request.timeoutInterval = 70
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FieldExplanationRequestError.invalidResponse }
        if http.statusCode == 404 { throw ModuleFailure.blocked("当前云端尚未开放整表填写，可继续本地填写或单字段整理。") }
        guard http.statusCode == 200 else { throw DemoAccessService.responseError(status: http.statusCode, data: data, serviceName: "整表填写") }
        let result = FormPlanRules.sanitizeWireEvidence(try JSONDecoder().decode(FormPlanResponse.self, from: data), for: payload)
        // FlowStore validates after resolving local constituent sources, so one
        // cross-source quote cannot discard unrelated fields in the same response.
        return result
    }
}
actor ConfiguredFormPlanningService: FormPlanning {
    func plan(_ request: FormPlanRequest) async throws -> FormPlanResponse {
        if let configuration = try DemoAccessKeychain.load() {
            return try await RelayFormPlanningService(endpoint: configuration.endpoint, token: configuration.token).plan(request)
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let address = environment["BIAOXIA_RELAY_BASE_URL"], let endpoint = URL(string: address), endpoint.scheme == "https",
           let token = environment["BIAOXIA_RELAY_CLIENT_TOKEN"], !token.isEmpty {
            return try await RelayFormPlanningService(endpoint: endpoint, token: token).plan(request)
        }
        #endif
        throw ModuleFailure.blocked("请先在首页配置演示访问，也可继续本地填写。")
    }
}
