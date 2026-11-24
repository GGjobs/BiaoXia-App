import Foundation

/// Optional additions keep saved PDF/DOCX tasks readable without discarding user answers.
struct FormDiagnostic: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var pageIndex: Int
    var message: String
}

struct RetainedFormAnswer: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var pageIndex: Int?
    var answer: PersonalAnswer
}

struct FormExportSummary: Codable, Hashable, Sendable {
    var written: Int
    var leftBlank: Int
    var pending: Int
    var diagnosticCount: Int
    var isPartial: Bool { pending > 0 || diagnosticCount > 0 }

    init(document: GeneralFormDocument) {
        written = document.fields.filter { $0.answer?.confirmationState == .confirmed }.count
        leftBlank = document.fields.filter { $0.answer?.confirmationState == .intentionallyBlank }.count
        pending = document.fields.count - written - leftBlank
        diagnosticCount = (document.diagnostics ?? []).count + (document.retainedAnswers ?? []).count
    }
}

struct AnswerSourceSnippet: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var text: String
}

/// Only this deliberately narrow DTO crosses the network. No files, coordinates or local IDs.
struct AnswerCompositionRequest: Codable, Hashable, Sendable {
    var schemaVersion = 1
    var requestId: UUID
    var fieldLabel: String
    var instructions: String
    var maximumCharacters: Int?
    var sources: [AnswerSourceSnippet]
}

struct AnswerCompositionResponse: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var requestId: UUID
    var answer: String?
    var sourceIDs: [String]
    var missingInformation: [String]
}

struct AnswerCompositionDraft: Codable, Hashable, Sendable {
    var request: AnswerCompositionRequest
    var recordIDs: [UUID]
    var originalAnswer: PersonalAnswer?
    var response: AnswerCompositionResponse?
    var editedAnswer: String?
    var error: String?
    /// Local-only authorized item snapshots; historical raw-text drafts have none.
    var aiSources: [FormPlanSource]? = nil
}

protocol AnswerComposing: Sendable {
    func compose(_ request: AnswerCompositionRequest) async throws -> AnswerCompositionResponse
}
