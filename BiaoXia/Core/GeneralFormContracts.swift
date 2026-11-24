import Foundation

enum FormFieldKind: String, Codable, CaseIterable, Sendable {
    case singleLineText
    case multilineText
    case date
    case singleChoice
    case multipleChoice
}

struct FormFieldOption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var label: String
    var exportValue: String
}

struct FormFieldConstraints: Codable, Hashable, Sendable {
    var isRequired: Bool = false
    var maximumCharacters: Int?
    var maximumLines: Int?
    var dateFormat: String?
    var minimumSelections: Int?
    var maximumSelections: Int?
}

enum PDFFieldAnchorKind: String, Codable, Sendable {
    case acroFormWidget
    case textRegion
    case checkboxRegion
    case manuallyAdjustedRegion
}

struct PDFFieldAnchor: Codable, Hashable, Sendable {
    var pageIndex: Int
    var rect: NormalizedRect
    var kind: PDFFieldAnchorKind
    var widgetName: String?
    var confidence: Double
}

enum FieldMeaningState: String, Codable, Sendable {
    case knownLocally
    case needsReview
    case allowedForRemoteExplanation
    case explained
    case userSpecified
    case unresolved
}

struct FieldMeaning: Codable, Hashable, Sendable {
    var canonicalKey: String?
    var summary: String?
    var state: FieldMeaningState
}

enum FieldConfirmationState: String, Codable, Sendable {
    case unresolved
    case suggested
    case confirmed
    case intentionallyBlank
    case blocked
}

struct PersonalAnswer: Codable, Hashable, Sendable {
    var value: String?
    var selectedOptionIDs: [String]
    var sourceRecordIDs: [UUID]
    var confirmationState: FieldConfirmationState
    var modifiedByUser: Bool
    var reviewReasons: [String]? = nil
    var planSources: [FormPlanAnswerSource]? = nil

    var reasonsRequiringReview: [String] { reviewReasons ?? [] }
}

struct DynamicFormField: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var label: String
    var section: String?
    var instructions: String?
    var kind: FormFieldKind
    var options: [FormFieldOption]
    var constraints: FormFieldConstraints
    var anchors: [PDFFieldAnchor]
    var meaning: FieldMeaning
    var answer: PersonalAnswer?
    /// Word 使用结构地址，不伪造 PDF 页码或坐标；旧 PDF 快照缺少此属性时仍可解码。
    var wordAnchor: WordFieldAnchor? = nil
    var labelAnchor: PDFFieldAnchor? = nil
    var selectedRecordIDs: [UUID]? = nil
    var compositionDraft: AnswerCompositionDraft? = nil
}

enum FormDocumentFormat: String, Codable, Sendable {
    case pdf, docx
}

struct WordFieldAnchor: Codable, Hashable, Sendable {
    var path: String
    var originalText: String
    var placeholder: String?
    var location: String
}

struct DocumentFingerprint: Codable, Hashable, Sendable {
    var algorithm: String
    var value: String
    var byteCount: Int64
}

struct GeneralFormDocument: Codable, Hashable, Sendable {
    static let currentStructureVersion = 3

    var structureVersion: Int
    var fingerprint: DocumentFingerprint
    var fields: [DynamicFormField]
    var format: FormDocumentFormat? = nil
    var pdfLayoutVersion: Int? = nil
    var diagnostics: [FormDiagnostic]? = nil
    var retainedAnswers: [RetainedFormAnswer]? = nil
    var planDraft: FormPlanDraft? = nil

    var effectiveFormat: FormDocumentFormat { format ?? .pdf }
}

enum PDFFormLimitation: String, Codable, Hashable, Sendable {
    case encryptedOrProtected
    case scannedOrMixedContent
    case rotatedPage
    case unsupportedStructure
    case noSupportedFields
}

enum PDFFieldLayoutState: Codable, Hashable, Sendable {
    case ready(fontSize: Double)
    /// 只验证 Word 内容和结构锚点，不表示排版或容量验收通过。
    case contentReadyNeedsExternalReview
    case needsAnchorReview
    case invalidAnswer(String)
    case overflow
}

struct PDFFieldLayoutResult: Codable, Hashable, Sendable {
    var fieldID: String
    var state: PDFFieldLayoutState
}

struct FormVersionMapping: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var documentFingerprint: DocumentFingerprint
    var structureVersion: Int
    var pdfLayoutVersion: Int? = nil
    var fieldMeanings: [String: FieldMeaning]
    var anchors: [String: [PDFFieldAnchor]]
    var updatedAt: Date
}

enum ProfileSubjectKind: String, Codable, CaseIterable, Hashable, Sendable {
    case selfPerson
    case familyMember
    case emergencyContact
    case other
}

struct ProfileSubject: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: ProfileSubjectKind
    var relationshipToSelf: String?
    var displayName: String
}

enum ProfileRecordKind: String, Codable, Sendable {
    case identity
    case contact
    case education
    case employment
    case project
    case course
    case skill
    case certificate
    case experience
}

struct ProfileRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var subjectID: UUID
    var kind: ProfileRecordKind
    var businessKey: String
    var displayValue: String
    var components: [String: String]
    var sources: [FieldSource]
    var confirmedComponentKeys: Set<String>
    var updatedAt: Date
}

enum ProfileBusinessKey {
    static func make(kind: ProfileRecordKind, subjectID: UUID, components: [String: String]) -> String {
        let stableComponents = components
            .map { key, value in
                let normalized = value.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(key.lowercased())=\(normalized.lowercased())"
            }
            .sorted()
            .joined(separator: "|")
        return "\(kind.rawValue)|\(subjectID.uuidString.lowercased())|\(stableComponents)"
    }
}

enum WorkflowStage: String, Codable, Sendable {
    case imported
    case parsed
    case explained
    case matched
    case reviewed
    case exported
}

struct WorkflowCheckpoint: Codable, Hashable, Sendable {
    var stage: WorkflowStage
    var revision: Int
    var savedAt: Date
}

enum ModuleFailure: LocalizedError, Equatable, Sendable {
    case cancelled
    case retryable(String)
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "操作已取消。"
        case .retryable(let reason), .blocked(let reason): reason
        }
    }
}

protocol FormParsing: Sendable {
    func parse(formURL: URL) async throws -> GeneralFormDocument
}

protocol FieldExplaining: Sendable {
    func explain(fields: [DynamicFormField]) async throws -> [String: FieldMeaning]
}

protocol ReviewedFieldExplanationSubmitting: Sendable {
    func explain(draft: FieldExplanationDraft) async throws -> [String: FieldMeaning]
}

protocol AnswerMatching: Sendable {
    func match(fields: [DynamicFormField], subjects: [ProfileSubject], records: [ProfileRecord]) async throws -> [String: PersonalAnswer]
}

protocol FormWriting: Sendable {
    func write(document: GeneralFormDocument, sourceURL: URL, destinationURL: URL) async throws
}

protocol FormPreflighting: Sendable {
    func preflight(document: GeneralFormDocument, sourceURL: URL) throws -> [PDFFieldLayoutResult]
}

protocol PDFRegionAdjusting: Sendable {
    func adjustingRegion(
        fieldID: String,
        to rect: NormalizedRect,
        pageIndex: Int,
        in document: GeneralFormDocument
    ) throws -> GeneralFormDocument
}
