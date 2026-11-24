import CoreGraphics
import Foundation

enum FillTaskStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case imported
    case recognizing
    case awaitingAIConsent
    case resolving
    case reviewing
    case exporting
    case completed
    case failed

    var title: String {
        switch self {
        case .draft: "待导入"
        case .imported: "已导入"
        case .recognizing: "正在识别"
        case .awaitingAIConsent: "待本地核对"
        case .resolving: "待恢复核对"
        case .reviewing: "等待确认"
        case .exporting: "正在导出"
        case .completed: "已完成"
        case .failed: "处理失败"
        }
    }
}

enum TaskInputMode: String, Codable, Sendable {
    case reusableProfile
    case materialOCR
}

enum MaterialKind: String, Codable, Sendable {
    case image
    case pdf
    case docx

    var systemImage: String { self == .image ? "photo" : "doc.richtext" }
}

enum MaterialProcessingStatus: String, Codable, Sendable {
    case pending
    case recognizing
    case completed
    case failed
}

struct NormalizedRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct MaterialAsset: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var kind: MaterialKind
    var pageCount: Int
    var relativePath: String
    var status: MaterialProcessingStatus

    init(
        id: UUID = UUID(),
        displayName: String,
        kind: MaterialKind,
        pageCount: Int,
        relativePath: String,
        status: MaterialProcessingStatus = .pending
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.pageCount = pageCount
        self.relativePath = relativePath
        self.status = status
    }
}

struct FieldSource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let materialID: UUID
    var materialName: String
    let pageIndex: Int
    let excerpt: String
    let confidence: Double

    var locationDescription: String { pageIndex < 0 ? "Word 正文" : "第 \(pageIndex + 1) 页" }

    init(
        id: UUID = UUID(),
        materialID: UUID,
        materialName: String,
        pageIndex: Int,
        excerpt: String,
        confidence: Double
    ) {
        self.id = id
        self.materialID = materialID
        self.materialName = materialName
        self.pageIndex = pageIndex
        self.excerpt = excerpt
        self.confidence = confidence
    }
}

struct FormAsset: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var pageCount: Int
    var relativePath: String
    var templateID: String

    var isWord: Bool { (relativePath as NSString).pathExtension.lowercased() == "docx" }

    init(
        id: UUID = UUID(),
        displayName: String,
        pageCount: Int,
        relativePath: String,
        templateID: String
    ) {
        self.id = id
        self.displayName = displayName
        self.pageCount = pageCount
        self.relativePath = relativePath
        self.templateID = templateID
    }
}

struct OCRBlock: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let text: String
    let pageIndex: Int
    let boundingBox: NormalizedRect
    let confidence: Double
    let materialID: UUID

    var locationDescription: String { pageIndex < 0 ? "Word 正文" : "第 \(pageIndex + 1) 页" }

    init(
        id: UUID = UUID(),
        text: String,
        pageIndex: Int,
        boundingBox: NormalizedRect,
        confidence: Double,
        materialID: UUID
    ) {
        self.id = id
        self.text = text
        self.pageIndex = pageIndex
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.materialID = materialID
    }
}

enum FieldKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullName
    case gender
    case birthDate
    case school
    case college
    case major
    case studentID
    case phone
    case email
    case address

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullName: "姓名"
        case .gender: "性别"
        case .birthDate: "出生日期"
        case .school: "学校"
        case .college: "学院"
        case .major: "专业"
        case .studentID: "学号"
        case .phone: "手机"
        case .email: "邮箱"
        case .address: "地址"
        }
    }

    var allowsCloudResolution: Bool {
        switch self {
        case .school, .college, .major: true
        default: false
        }
    }
}

enum ProfileItemCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case identity
    case contact
    case education
    case course
    case skill
    case language
    case certificate
    case award
    case project
    case internship
    case work
    case campus
    case volunteer
    case selfIntroduction
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .identity: "身份信息"
        case .contact: "联系信息"
        case .education: "教育与学籍"
        case .course: "课程成绩"
        case .skill: "技能"
        case .language: "语言能力"
        case .certificate: "证书"
        case .award: "获奖"
        case .project: "项目经历"
        case .internship: "实习经历"
        case .work: "工作经历"
        case .campus: "校园经历"
        case .volunteer: "志愿经历"
        case .selfIntroduction: "自我介绍"
        case .other: "其他信息"
        }
    }

    var allowsMultiple: Bool {
        switch self {
        case .identity, .contact, .selfIntroduction: false
        default: true
        }
    }
}

enum ProfileItemSensitivity: String, Codable, Sendable {
    case normal
    case personal
    case highlySensitive
}

enum ProfileItemState: String, Codable, Sendable {
    case confirmed
    case autoExtracted
    case pending
}

struct ProfileItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var category: ProfileItemCategory
    var fieldID: String
    var label: String
    var value: String
    var components: [String: String]
    var confidence: Double
    var state: ProfileItemState
    var sensitivity: ProfileItemSensitivity
    var isPreferred: Bool
    var modifiedByUser: Bool
    var sources: [FieldSource]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        category: ProfileItemCategory,
        fieldID: String,
        label: String,
        value: String,
        components: [String: String] = [:],
        confidence: Double,
        state: ProfileItemState,
        sensitivity: ProfileItemSensitivity = .normal,
        isPreferred: Bool = false,
        modifiedByUser: Bool = false,
        sources: [FieldSource] = [],
        updatedAt: Date = .now
    ) {
        self.id = id
        self.category = category
        self.fieldID = fieldID
        self.label = label
        self.value = value
        self.components = components
        self.confidence = confidence
        self.state = state
        self.sensitivity = sensitivity
        self.isPreferred = isPreferred
        self.modifiedByUser = modifiedByUser
        self.sources = sources
        self.updatedAt = updatedAt
    }

    var normalizedIdentity: String {
        let normalizedValue = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let stableFieldID = fieldID.split(separator: ".").first.map(String.init) ?? fieldID
        return "\(category.rawValue)|\(stableFieldID.lowercased())|\(normalizedValue)"
    }

    var maskedValue: String {
        guard sensitivity == .highlySensitive, value.count > 4 else { return value }
        return String(repeating: "•", count: max(4, value.count - 4)) + value.suffix(4)
    }
}

struct ProfileItemChange: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let itemID: UUID
    let label: String
    let previous: ProfileItem?
    let current: ProfileItem?

    init(
        id: UUID = UUID(),
        itemID: UUID,
        label: String,
        previous: ProfileItem?,
        current: ProfileItem?
    ) {
        self.id = id
        self.itemID = itemID
        self.label = label
        self.previous = previous
        self.current = current
    }
}

struct ProfileChangeBatch: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    var changes: [ProfileItemChange]

    init(id: UUID = UUID(), createdAt: Date = .now, changes: [ProfileItemChange]) {
        self.id = id
        self.createdAt = createdAt
        self.changes = changes
    }
}

struct FormFieldValue: Identifiable, Codable, Hashable, Sendable {
    var id: String { fieldID }
    let fieldID: String
    var label: String
    var value: String
    var required: Bool
    var sourceItemIDs: [UUID]
    var modifiedByUser: Bool
}

struct FieldCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fieldKey: FieldKey
    let value: String
    let sourceBlockIDs: [UUID]
    let score: Double
    let scoreReasons: [String]

    init(
        id: UUID = UUID(),
        fieldKey: FieldKey,
        value: String,
        sourceBlockIDs: [UUID],
        score: Double,
        scoreReasons: [String]
    ) {
        self.id = id
        self.fieldKey = fieldKey
        self.value = value
        self.sourceBlockIDs = sourceBlockIDs
        self.score = score
        self.scoreReasons = scoreReasons
    }
}

struct ResolvedField: Identifiable, Codable, Hashable, Sendable {
    var id: FieldKey { key }
    let key: FieldKey
    var value: String
    var candidateID: UUID?
    var confidence: Double
    var sourceBlockIDs: [UUID]
    var resolvedByAI: Bool
    var modifiedByUser: Bool
    var sources: [FieldSource]? = nil
}

enum ProfileWorkflowStatus: String, Codable, Sendable {
    case draft
    case imported
    case recognizing
    case awaitingAIConsent
    case resolving
    case reviewing
    case confirmed
    case failed
}

struct ProfileLibrarySnapshot: Codable, Sendable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var workspaceID: UUID
    var status: ProfileWorkflowStatus
    var materials: [MaterialAsset]
    var ocrBlocks: [OCRBlock]
    var candidates: [FieldCandidate]
    var resolvedFields: [ResolvedField]
    var aiConsent: Bool?
    var recognitionCompletedPages: Int
    var recognitionTotalPages: Int
    var lastError: String?
    var updatedAt: Date
    var profileItems: [ProfileItem]?
    var pendingItems: [ProfileItem]?
    var changeHistory: [ProfileChangeBatch]?
    var subjects: [ProfileSubject]?
    var records: [ProfileRecord]?
    var formMappings: [FormVersionMapping]?
    /// Each grant binds an item to the exact content the user allowed AI to read.
    var aiSharingGrants: [UUID: String]? = nil

    static func empty(workspaceID: UUID = UUID()) -> ProfileLibrarySnapshot {
        ProfileLibrarySnapshot(
            schemaVersion: currentSchemaVersion,
            workspaceID: workspaceID,
            status: .draft,
            materials: [],
            ocrBlocks: [],
            candidates: [],
            resolvedFields: PersonalProfile.empty.resolvedFields,
            aiConsent: nil,
            recognitionCompletedPages: 0,
            recognitionTotalPages: 0,
            lastError: nil,
            updatedAt: .now,
            profileItems: [],
            pendingItems: [],
            changeHistory: []
            , subjects: []
            , records: []
            , formMappings: []
            , aiSharingGrants: [:]
        )
    }

    var isRecognized: Bool {
        !ocrBlocks.isEmpty && [.awaitingAIConsent, .resolving, .reviewing, .confirmed].contains(status)
    }
}

struct TemplateFieldManifest: Codable, Hashable, Sendable {
    let key: String
    let pageIndex: Int
    let rect: NormalizedRect
    let fontSize: Double
    let minimumFontSize: Double
    let maximumLines: Int
    let alignment: String
    let required: Bool?
    let source: String?
    let maximumItems: Int?
    let formatting: String?
}

struct TemplateManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let templateID: String
    let templateVersion: String
    let pageSize: String
    let coordinateOrigin: String
    let fields: [TemplateFieldManifest]
}

struct FillTaskSnapshot: Codable, Sendable {
    let id: UUID
    var title: String
    var status: FillTaskStatus
    var createdAt: Date
    var updatedAt: Date
    var materials: [MaterialAsset]
    var ocrBlocks: [OCRBlock]
    var candidates: [FieldCandidate]
    var resolvedFields: [ResolvedField]
    var aiConsent: Bool?
    var recognitionCompletedPages: Int
    var recognitionTotalPages: Int
    var exportRelativePath: String?
    var lastError: String?
    var inputMode: TaskInputMode?
    var form: FormAsset?
    var formValues: [FormFieldValue]?
    var schemaVersion: Int? = 1
    var generalForm: GeneralFormDocument?
    var versionMapping: FormVersionMapping?
    var checkpoint: WorkflowCheckpoint?
    var fieldExplanationDraft: FieldExplanationDraft? = nil
    var exportSummary: FormExportSummary? = nil

    static func empty(
        id: UUID = UUID(),
        profile: PersonalProfile = .empty
    ) -> FillTaskSnapshot {
        FillTaskSnapshot(
            id: id,
            title: "竞赛报名信息表",
            status: .draft,
            createdAt: .now,
            updatedAt: .now,
            materials: [],
            ocrBlocks: [],
            candidates: [],
            resolvedFields: profile.resolvedFields,
            aiConsent: nil,
            recognitionCompletedPages: 0,
            recognitionTotalPages: 0,
            exportRelativePath: nil,
            lastError: nil,
            inputMode: .reusableProfile,
            form: nil,
            formValues: nil
        )
    }

    var effectiveInputMode: TaskInputMode {
        inputMode ?? .materialOCR
    }
}

enum BiaoXiaError: LocalizedError {
    case missingTask
    case unsupportedMaterial
    case resourceMissing(String)
    case unreadableDocument(String)
    case relayUnavailable
    case aiResolutionTimedOut
    case invalidRelayResponse
    case noMaterials
    case formRequired
    case unsupportedForm
    case wordMaterialHasNoText
    case incompleteProfile
    case unsafeFilePath

    var errorDescription: String? {
        switch self {
        case .missingTask: "任务不存在"
        case .unsupportedMaterial: "支持 PDF、JPG/PNG/HEIC 图片或原生 DOCX 材料；旧版 DOC 请先另存为 DOCX。"
        case .wordMaterialHasNoText: "此 Word 没有可读取的正文文字。内嵌图片、文本框及页眉页脚暂不读取；请改用 PDF 或图片材料。"
        case let .resourceMissing(name): "缺少资源：\(name)"
        case let .unreadableDocument(name): "无法读取材料：\(name)"
        case .relayUnavailable: "AI 中转服务尚未配置或暂时不可用"
        case .aiResolutionTimedOut: "AI 服务响应较慢，请重试或改为人工确认"
        case .invalidRelayResponse: "AI 中转服务返回了无效数据"
        case .noMaterials: "请先导入至少一份材料"
        case .formRequired: "请先导入空白报名表"
        case .unsupportedForm: "请选择未加密的文字 PDF 或原生 DOCX 表格；暂不支持旧版 DOC、Excel 和图片表格。"
        case .incompleteProfile: "请先建立并确认至少一项可复用信息"
        case .unsafeFilePath: "文件路径不安全，操作已取消"
        }
    }
}
