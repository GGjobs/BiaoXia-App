import Foundation

/// Wire types intentionally contain no local UUIDs, file paths or document coordinates.
enum FormPlanMode: String, Codable, Sendable { case fact, generated, manual }
struct FormPlanField: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var section: String
    var instructions: String
    var kind: FormFieldKind
    var mode: FormPlanMode
    var maximumCharacters: Int?
    var minimumSelections: Int?
    var maximumSelections: Int?
    var options: [FieldExplanationRequestOption]
}
struct FormPlanRequest: Codable, Hashable, Sendable {
    var schemaVersion = 1
    var requestId = UUID()
    var fields: [FormPlanField]
    var sources: [AnswerSourceSnippet]
}
struct FormPlanEvidence: Codable, Hashable, Sendable {
    var sourceId: String
    var quote: String
}
enum FormPlanStatus: String, Codable, Sendable { case suggested, missing, conflict, manual }
struct FormPlanSuggestion: Codable, Hashable, Sendable, Identifiable {
    var fieldId: String
    var status: FormPlanStatus
    var answer: String?
    var selectedOptionIDs: [String]
    var evidence: [FormPlanEvidence]
    var reason: String
    var generated: Bool
    var id: String { fieldId }
}
struct FormPlanResponse: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var requestId: UUID
    var suggestions: [FormPlanSuggestion]
}
protocol FormPlanning: Sendable {
    func plan(_ request: FormPlanRequest) async throws -> FormPlanResponse
}

/// Local source snapshots support stale-result detection even after the reviewed text is edited.
struct FormPlanSource: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var originID: String
    var title: String
    var originalText: String
    var text: String
    var recordID: UUID?
}
struct FormPlanTarget: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var original: DynamicFormField
    var field: FormPlanField
}
struct FormPlanBatch: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var request: FormPlanRequest
    var response: FormPlanResponse?
    var error: String?
    /// Local-only mapping. Never encoded into the Relay request.
    var sourceOrigins: [String: String]?
    /// Local-only constituent IDs for packed snippets; absent in legacy drafts.
    var sourceMembers: [String: [String]]?
    /// For a merge request, maps each AI draft to evidence from original material.
    var evidenceLineage: [String: [FormPlanEvidence]]?
}
struct FormPlanDraft: Codable, Hashable, Sendable {
    var id = UUID()
    var fingerprint: DocumentFingerprint
    var structureVersion: Int
    var sources: [FormPlanSource]
    var targets: [FormPlanTarget]
    var batches: [FormPlanBatch] = []
    /// Each round is explicitly authorized; a restored draft never sends it automatically.
    var mergeRounds: [[FormPlanBatch]]?
    var adoptedFieldIDs: Set<String> = []
    // A saved draft never grants authority to send on launch. Only the send button invokes the service.
    var lastAuthorizedAt: Date?
    /// Nil in historical drafts: they must be prepared again under item permissions.
    var sharingPolicyVersion: Int? = nil
    /// A single-field request uses the same planner and permission boundary.
    var scopeFieldID: String? = nil
}
struct FormPlanAnswerSource: Codable, Hashable, Sendable {
    var title: String
    var quote: String
    var originID: String
}

enum FormPlanRules {
    static func isProtected(_ field: DynamicFormField) -> Bool {
        field.answer?.modifiedByUser == true || [.confirmed, .intentionallyBlank, .blocked].contains(field.answer?.confirmationState)
    }
    static func mode(for field: DynamicFormField) -> FormPlanMode {
        if ["签名", "签字", "承诺", "真实性声明"].contains(where: field.label.contains) { return .manual }
        if field.kind == .multilineText || ["自我", "评价", "申请理由", "主要事迹", "简介"].contains(where: field.label.contains) { return .generated }
        return .fact
    }
    static func fieldSnapshot(_ field: DynamicFormField) -> DynamicFormField {
        var copy = field; copy.compositionDraft = nil; return copy
    }
    static func target(_ field: DynamicFormField, number: Int) -> FormPlanTarget {
        let id = "field-\(number)"
        return FormPlanTarget(id: id, original: fieldSnapshot(field), field: FormPlanField(
            id: id, label: field.label, section: field.section ?? "", instructions: field.instructions ?? "",
            kind: field.kind, mode: mode(for: field), maximumCharacters: field.constraints.maximumCharacters,
            minimumSelections: field.constraints.minimumSelections, maximumSelections: field.constraints.maximumSelections,
            options: field.options.enumerated().map { FieldExplanationRequestOption(id: "option-\($0.offset + 1)", label: $0.element.label) }))
    }
    static func makeBatches(_ draft: FormPlanDraft) throws -> [FormPlanBatch] {
        try makeSourceBatches(draft)
    }
    static func validate(_ request: FormPlanRequest) throws {
        func require(_ value: Bool) throws { if !value { throw ModuleFailure.blocked("请裁剪发送内容：每批最多 8 个字段、20 个片段、32 KB，每片段最多 8000 字。") } }
        try require(request.schemaVersion == 1 && (1...8).contains(request.fields.count) && (1...20).contains(request.sources.count))
        try require(Set(request.fields.map(\.id)).count == request.fields.count && Set(request.sources.map(\.id)).count == request.sources.count)
        for source in request.sources { try require(!source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && source.text.utf16.count <= 8000) }
        for field in request.fields {
            try require(!field.label.isEmpty && field.label.utf16.count <= 300 && field.section.utf16.count <= 1000 && field.instructions.utf16.count <= 2000)
            try require(field.maximumCharacters.map { (1...8000).contains($0) } ?? true)
            try require(field.options.count <= 100 && Set(field.options.map(\.id)).count == field.options.count)
            try require(field.options.allSatisfy { !$0.id.isEmpty && $0.id.utf16.count <= 100 && !$0.label.isEmpty && $0.label.utf16.count <= 300 })
            let choice = field.kind == .singleChoice || field.kind == .multipleChoice
            try require(choice ? !field.options.isEmpty : field.options.isEmpty)
            try require(field.minimumSelections.map { (0...100).contains($0) } ?? true)
            try require(field.maximumSelections.map { (0...100).contains($0) } ?? true)
        }
        try require(JSONEncoder().encode(request).count <= 32 * 1024)
    }
    static func validate(_ response: FormPlanResponse, for request: FormPlanRequest) throws {
        func require(_ value: Bool) throws { if !value { throw FieldExplanationRequestError.invalidResponse } }
        try require(response.schemaVersion == 1 && response.requestId == request.requestId)
        try require(Set(response.suggestions.map(\.fieldId)).count == response.suggestions.count && response.suggestions.count <= request.fields.count)
        for result in response.suggestions {
            guard let field = request.fields.first(where: { $0.id == result.fieldId }) else { throw FieldExplanationRequestError.invalidResponse }
            try require(result.reason.utf16.count <= 1000 && result.evidence.count <= 20)
            try require(Set(result.selectedOptionIDs).count == result.selectedOptionIDs.count && result.selectedOptionIDs.allSatisfy { id in field.options.contains { $0.id == id } })
            for evidence in result.evidence {
                try require(!evidence.quote.isEmpty && evidence.quote.utf16.count <= 2000 && request.sources.contains { $0.id == evidence.sourceId && $0.text.contains(evidence.quote) })
            }
            if result.status != .suggested {
                try require(result.answer == nil && result.selectedOptionIDs.isEmpty && !result.reason.isEmpty)
                continue
            }
            try require(field.mode != .manual && !result.evidence.isEmpty && (result.generated == (field.mode == .generated)))
            if field.options.isEmpty {
                guard let answer = result.answer else { throw FieldExplanationRequestError.invalidResponse }
                try require(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.utf16.count <= min(field.maximumCharacters ?? 8000, 8000) && result.selectedOptionIDs.isEmpty)
                if !result.generated { try require(!normalized(answer).isEmpty && result.evidence.contains { normalized($0.quote).contains(normalized(answer)) }) }
            } else {
                try require(result.answer == nil && !result.generated && result.selectedOptionIDs.count >= max(1, field.minimumSelections ?? 1))
                try require(result.selectedOptionIDs.count <= (field.kind == .singleChoice ? 1 : field.maximumSelections ?? field.options.count))
            }
        }
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"，。,:：;；、-/年月日".contains($0) }
    }
    static func canAdopt(_ target: FormPlanTarget, current: DynamicFormField, result: FormPlanSuggestion, batch: Bool) -> Bool {
        result.status == .suggested && !isProtected(current) && fieldSnapshot(current) == target.original
            && mode(for: current) != .manual && (!batch || (!result.generated && target.field.mode == .fact && current.options.isEmpty))
    }
    /// Shared inputs invalidate the plan; editing one answer does not invalidate other targets.
    static func isCurrent(_ draft: FormPlanDraft, document: GeneralFormDocument, sources: [FormPlanSource]) -> Bool {
        guard draft.fingerprint == document.fingerprint && draft.structureVersion == document.structureVersion else { return false }
        return draft.sources.allSatisfy { saved in sources.contains { $0.originID == saved.originID && $0.originalText == saved.originalText } }
            && draft.targets.allSatisfy { target in
                document.fields.contains { $0.id == target.original.id && definitionSnapshot($0) == definitionSnapshot(target.original) }
            }
    }

    /// The target's own answer snapshot remains strict so old suggestions cannot overwrite edits.
    static func isTargetCurrent(_ target: FormPlanTarget, document: GeneralFormDocument) -> Bool {
        document.fields.contains { $0.id == target.original.id && !isProtected($0) && fieldSnapshot($0) == target.original }
    }

    private static func definitionSnapshot(_ field: DynamicFormField) -> DynamicFormField {
        var copy = fieldSnapshot(field)
        copy.answer = nil
        return copy
    }

}

/// Runtime-only UI state: never stored in a draft or sent to the service.
struct FormPlanProgress: Equatable, Sendable {
    enum Phase: Sendable { case reviewing, generating, queued, results }
    var draftID: UUID
    var phase: Phase = .reviewing
    var batchNumber = 0
    var totalBatches = 0
    var fieldIDs: [String] = []
    var fieldNames: [String] = []
    var queueDeadline: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var completedBatches = 0
    var notice: String?
}

/// Both time and cancellable waiting are replaceable without contacting a real Relay.
struct FormPlanClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
}
