import Foundation

enum ExplanationTextRole: String, Codable, Sendable {
    case label
    case section
    case instructions
    case optionLabel
}

enum OutboundTextReviewState: String, Codable, Sendable {
    case pendingReview
    case allowed
    case removed
    case blocked
}

struct ReviewableExplanationText: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fieldID: String
    let role: ExplanationTextRole
    let optionID: String?
    var value: String
    var state: OutboundTextReviewState
    var reason: String?
}

struct FieldExplanationDraft: Codable, Hashable, Sendable {
    var requestID: UUID
    var fields: [DynamicFormField]
    var texts: [ReviewableExplanationText]

    var canSend: Bool {
        !texts.contains { $0.state == .pendingReview || $0.state == .blocked }
            && texts.contains { $0.state == .allowed }
    }

    mutating func allow(_ textID: UUID) {
        guard let index = texts.firstIndex(where: { $0.id == textID }),
              texts[index].state == .pendingReview else { return }
        texts[index].state = .allowed
        texts[index].reason = nil
    }

    mutating func remove(_ textID: UUID) {
        guard let index = texts.firstIndex(where: { $0.id == textID }) else { return }
        texts[index].state = .removed
        texts[index].value = ""
        texts[index].reason = "已从拟发送内容移除"
    }

    mutating func allowAllPending() {
        for index in texts.indices where texts[index].state == .pendingReview {
            texts[index].state = .allowed
        }
    }
}

struct FieldExplanationRequest: Codable, Hashable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var requestId: UUID
    var fields: [FieldExplanationRequestField]
}

struct FieldExplanationRequestField: Codable, Hashable, Sendable {
    var id: String
    var label: String?
    var section: String?
    var instructions: String?
    var kind: FormFieldKind
    var options: [FieldExplanationRequestOption]
}

struct FieldExplanationRequestOption: Codable, Hashable, Sendable {
    var id: String
    var label: String
}

struct FieldExplanationResponse: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var requestId: UUID
    var explanations: [FieldExplanationResult]
}

struct FieldExplanationResult: Codable, Hashable, Sendable {
    var fieldId: String
    var canonicalKey: String?
    var summary: String
    var confidence: Double
    var reasonCode: String
}

enum FieldExplanationRequestError: Error, Equatable, LocalizedError {
    case pendingReview
    case blockedContent
    case noSendableFields
    case invalidResponse
    case retryable(String, beforeModel: Bool = false)
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .pendingReview: "拟发送内容尚未完成核对。"
        case .blockedContent: "拟发送内容包含禁止发送的信息。"
        case .noSendableFields: "没有可发送的字段说明。"
        case .invalidResponse: "字段解释响应无效。"
        case let .retryable(message, _), let .blocked(message): message
        }
    }
}

struct FieldExplanationRequestBuilder: Sendable {
    /// Document field and option IDs can contain widget names or personal text.
    /// Stable draft positions provide anonymous transport IDs across retries.
    static func remoteFieldID(at index: Int) -> String { "field-\(index + 1)" }

    private let sensitivePatterns = [
        #"\b1[3-9]\d{9}\b"#,
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        #"(?:19|20)\d{2}[年./-]\d{1,2}[月./-]\d{1,2}日?"#,
        #"(?:学号|学生编号)[：:\s]*[A-Za-z0-9-]{6,24}"#,
        #"(?<![0-9A-Za-z])\d{17}[0-9Xx](?![0-9A-Za-z])"#
    ]

    func makeDraft(fields: [DynamicFormField], requestID: UUID = UUID()) -> FieldExplanationDraft {
        let unresolved = fields.filter {
            [.needsReview, .allowedForRemoteExplanation, .unresolved].contains($0.meaning.state)
        }
        var texts: [ReviewableExplanationText] = []
        for field in unresolved {
            append(field.label, role: .label, fieldID: field.id, optionID: nil, to: &texts)
            append(field.section, role: .section, fieldID: field.id, optionID: nil, to: &texts)
            append(field.instructions, role: .instructions, fieldID: field.id, optionID: nil, to: &texts)
            for option in field.options {
                append(option.label, role: .optionLabel, fieldID: field.id, optionID: option.id, to: &texts)
            }
        }
        return FieldExplanationDraft(requestID: requestID, fields: unresolved, texts: texts)
    }

    func build(from draft: FieldExplanationDraft) throws -> FieldExplanationRequest {
        if draft.texts.contains(where: { $0.state == .blocked }) {
            throw FieldExplanationRequestError.blockedContent
        }
        if draft.texts.contains(where: { $0.state == .pendingReview }) {
            throw FieldExplanationRequestError.pendingReview
        }
        let allowed = draft.texts.filter { $0.state == .allowed }
        let fields = draft.fields.enumerated().compactMap { index, field -> FieldExplanationRequestField? in
            let fieldTexts = allowed.filter { $0.fieldID == field.id }
            guard !fieldTexts.isEmpty else { return nil }
            func value(_ role: ExplanationTextRole) -> String? {
                fieldTexts.first { $0.role == role }?.value
            }
            let options = field.options.enumerated().compactMap { optionIndex, option -> FieldExplanationRequestOption? in
                guard let text = fieldTexts.first(where: {
                    $0.role == .optionLabel && $0.optionID == option.id
                }) else { return nil }
                return FieldExplanationRequestOption(id: "option-\(optionIndex + 1)", label: text.value)
            }
            return FieldExplanationRequestField(
                id: Self.remoteFieldID(at: index),
                label: value(.label),
                section: value(.section),
                instructions: value(.instructions),
                kind: field.kind,
                options: options
            )
        }
        guard !fields.isEmpty else { throw FieldExplanationRequestError.noSendableFields }
        return FieldExplanationRequest(
            schemaVersion: FieldExplanationRequest.schemaVersion,
            requestId: draft.requestID,
            fields: fields
        )
    }

    private func append(
        _ rawValue: String?,
        role: ExplanationTextRole,
        fieldID: String,
        optionID: String?,
        to texts: inout [ReviewableExplanationText]
    ) {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        let blocked = sensitivePatterns.contains {
            value.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
        texts.append(
            ReviewableExplanationText(
                id: UUID(),
                fieldID: fieldID,
                role: role,
                optionID: optionID,
                value: value,
                state: blocked ? .blocked : .pendingReview,
                reason: blocked ? "检测到个人或敏感信息，禁止发送" : nil
            )
        )
    }
}

actor RelayFieldExplanationService: FieldExplaining, ReviewedFieldExplanationSubmitting {
    private let endpoint: URL
    private let clientToken: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let version: Int
    private let requestBuilder: FieldExplanationRequestBuilder

    init(
        endpoint: URL,
        clientToken: String,
        session: URLSession = RelaySessionDelegate.makeSession(),
        requestBuilder: FieldExplanationRequestBuilder = FieldExplanationRequestBuilder(),
        version: Int = 1
    ) {
        self.endpoint = endpoint
        self.clientToken = clientToken
        self.session = session
        self.requestBuilder = requestBuilder
        self.version = version
    }

    // Debug runs inject credentials at launch; no credential is embedded in the app bundle.
    // External demo builds load separately issued credentials from Keychain.
    static func configuredForDebugRun() -> RelayFieldExplanationService? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["BIAOXIA_RELAY_BASE_URL"],
              let endpoint = URL(string: address), endpoint.scheme == "https", endpoint.host != nil,
              let token = environment["BIAOXIA_RELAY_CLIENT_TOKEN"], !token.isEmpty else { return nil }
        return RelayFieldExplanationService(endpoint: endpoint, clientToken: token, version: 2)
        #else
        return nil
        #endif
    }

    func explain(fields: [DynamicFormField]) async throws -> [String: FieldMeaning] {
        let draft = requestBuilder.makeDraft(fields: fields)
        return try await explain(draft: draft)
    }

    func explain(draft: FieldExplanationDraft) async throws -> [String: FieldMeaning] {
        var payload = try requestBuilder.build(from: draft)
        payload.schemaVersion = version
        var request = URLRequest(url: endpoint.appending(path: "v\(version)/explain-fields"))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
        // Relay may try two models for 20 seconds each; allow 10 seconds for transport overhead.
        request.timeoutInterval = 50

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FieldExplanationRequestError.retryable("字段解释服务未返回 HTTP 响应。")
            }
            if http.statusCode == 404 { throw FieldExplanationRequestError.blocked("当前服务尚未支持扩展字段解释，请在本机选择资料或手动填写。") }
            guard http.statusCode == 200 else {
                throw DemoAccessService.responseError(status: http.statusCode, data: data)
            }
            let decoded = try decoder.decode(FieldExplanationResponse.self, from: data)
            let remoteMeanings = try validate(decoded, request: payload)
            return Dictionary(uniqueKeysWithValues: draft.fields.enumerated().compactMap { index, field in
                guard let meaning = remoteMeanings[FieldExplanationRequestBuilder.remoteFieldID(at: index)] else {
                    return nil
                }
                return (field.id, meaning)
            })
        } catch let error as FieldExplanationRequestError {
            throw error
        } catch is CancellationError {
            throw ModuleFailure.cancelled
        } catch let error as URLError {
            throw FieldExplanationRequestError.retryable(error.localizedDescription)
        } catch {
            throw FieldExplanationRequestError.invalidResponse
        }
    }

    private func validate(
        _ response: FieldExplanationResponse,
        request: FieldExplanationRequest
    ) throws -> [String: FieldMeaning] {
        guard response.schemaVersion == request.schemaVersion,
              response.requestId == request.requestId,
              response.explanations.count <= request.fields.count else {
            throw FieldExplanationRequestError.invalidResponse
        }
        let requestedIDs = Set(request.fields.map(\.id))
        let allowedKeys = Set([
            "fullName", "englishName", "gender", "birthDate", "school", "college",
            "major", "studentID", "phone", "email", "address", "educationLevel",
            "employer"
        ] + (version == 2 ? Array(FormRecordMatcher.aliases.keys) : []))
        var result: [String: FieldMeaning] = [:]
        for explanation in response.explanations {
            guard requestedIDs.contains(explanation.fieldId),
                  result[explanation.fieldId] == nil,
                  explanation.confidence >= 0,
                  explanation.confidence <= 1,
                  explanation.summary.count <= 80,
                  explanation.reasonCode.range(of: #"^[A-Z0-9_]{2,40}$"#, options: .regularExpression) != nil,
                  explanation.canonicalKey.map(allowedKeys.contains) ?? true else {
                throw FieldExplanationRequestError.invalidResponse
            }
            result[explanation.fieldId] = FieldMeaning(
                canonicalKey: explanation.canonicalKey,
                summary: explanation.summary,
                state: explanation.canonicalKey == nil ? .unresolved : .explained
            )
        }
        return result
    }
}
