import Foundation

struct PersonalProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4

    var fullName: String
    var gender: String
    var birthDate: String
    var school: String
    var college: String
    var major: String
    var studentID: String
    var phone: String
    var email: String
    var address: String
    var schemaVersion: Int? = currentSchemaVersion
    var evidence: [ProfileFieldEvidence]? = nil
    var items: [ProfileItem]? = nil
    var subjects: [ProfileSubject]? = nil
    var records: [ProfileRecord]? = nil

    static let empty = PersonalProfile(
        fullName: "",
        gender: "",
        birthDate: "",
        school: "",
        college: "",
        major: "",
        studentID: "",
        phone: "",
        email: "",
        address: ""
    )

    var resolvedFields: [ResolvedField] {
        FieldKey.allCases.map { key in
            let fieldEvidence = evidence?.first(where: { $0.key == key })
            return ResolvedField(
                key: key,
                value: value(for: key),
                candidateID: nil,
                confidence: fieldEvidence?.confidence ?? (value(for: key).isEmpty ? 0 : 1),
                sourceBlockIDs: [],
                resolvedByAI: fieldEvidence?.resolvedByAI ?? false,
                modifiedByUser: fieldEvidence?.modifiedByUser ?? !value(for: key).isEmpty,
                sources: fieldEvidence?.sources
            )
        }
    }

    var isComplete: Bool {
        FieldKey.allCases.allSatisfy {
            !value(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasInformation: Bool {
        informationItems.contains { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var informationItems: [ProfileItem] {
        let stored = items ?? []
        let storedFieldIDs = Set(stored.map(\.fieldID))
        let legacy = FieldKey.allCases.compactMap { key -> ProfileItem? in
            let value = value(for: key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !storedFieldIDs.contains(key.rawValue) else { return nil }
            let fieldEvidence = evidence?.first(where: { $0.key == key })
            return ProfileItem(
                category: key.profileCategory,
                fieldID: key.rawValue,
                label: key.label,
                value: value,
                confidence: fieldEvidence?.confidence ?? 1,
                state: .confirmed,
                sensitivity: key.sensitivity,
                modifiedByUser: fieldEvidence?.modifiedByUser ?? true,
                sources: fieldEvidence?.sources ?? []
            )
        }
        return stored + legacy
    }

    mutating func synchronizeLegacyFields() {
        for key in FieldKey.allCases {
            if let item = informationItems.first(where: { $0.fieldID == key.rawValue }) {
                setValue(item.value, for: key)
            }
        }
    }

    func value(for key: FieldKey) -> String {
        switch key {
        case .fullName: fullName
        case .gender: gender
        case .birthDate: birthDate
        case .school: school
        case .college: college
        case .major: major
        case .studentID: studentID
        case .phone: phone
        case .email: email
        case .address: address
        }
    }

    mutating func setValue(_ value: String, for key: FieldKey) {
        switch key {
        case .fullName: fullName = value
        case .gender: gender = value
        case .birthDate: birthDate = value
        case .school: school = value
        case .college: college = value
        case .major: major = value
        case .studentID: studentID = value
        case .phone: phone = value
        case .email: email = value
        case .address: address = value
        }
    }
}

extension FieldKey {
    var profileCategory: ProfileItemCategory {
        switch self {
        case .fullName, .gender, .birthDate: .identity
        case .school, .college, .major, .studentID: .education
        case .phone, .email, .address: .contact
        }
    }

    var sensitivity: ProfileItemSensitivity {
        switch self {
        case .fullName, .birthDate, .studentID, .phone, .email, .address: .personal
        default: .normal
        }
    }
}

struct ProfileFieldEvidence: Codable, Equatable, Sendable {
    let key: FieldKey
    var confidence: Double
    var resolvedByAI: Bool
    var modifiedByUser: Bool
    var sources: [FieldSource]
}

protocol ProfileStoring: Sendable {
    func load() async throws -> PersonalProfile
    func save(_ profile: PersonalProfile) async throws
}

actor PersonalProfileStore: ProfileStoring {
    static let shared = PersonalProfileStore()

    private let fileManager: FileManager
    private let profileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        let baseURL = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(component: "BiaoXia", directoryHint: .isDirectory)
        profileURL = baseURL.appending(component: "profile.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> PersonalProfile {
        guard fileManager.fileExists(atPath: profileURL.path) else {
            return .empty
        }
        var profile = try decoder.decode(
            PersonalProfile.self,
            from: Data(contentsOf: profileURL)
        )
        if profile.schemaVersion == nil
            || (profile.schemaVersion ?? 0) < PersonalProfile.currentSchemaVersion {
            try preserveMigrationSource(Data(contentsOf: profileURL))
            profile.schemaVersion = PersonalProfile.currentSchemaVersion
            if profile.evidence == nil {
                profile.evidence = FieldKey.allCases.compactMap { key in
                    guard !profile.value(for: key).isEmpty else { return nil }
                    return ProfileFieldEvidence(
                        key: key,
                        confidence: 1,
                        resolvedByAI: false,
                        modifiedByUser: true,
                        sources: []
                    )
                }
            }
            if profile.items == nil {
                profile.items = profile.informationItems
            }
            if profile.subjects == nil || profile.records == nil {
                let selfSubject = profile.subjects?.first(where: { $0.kind == .selfPerson })
                    ?? ProfileSubject(
                        id: UUID(),
                        kind: .selfPerson,
                        relationshipToSelf: nil,
                        displayName: profile.fullName
                    )
                profile.subjects = profile.subjects ?? [selfSubject]
                profile.records = profile.records
                    ?? migrateRecords(from: profile.informationItems, subjectID: selfSubject.id)
            }
            try save(profile)
        }
        return profile
    }

    func save(_ profile: PersonalProfile) throws {
        try fileManager.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(profile).write(
            to: profileURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: profileURL.path
        )
    }

    private func preserveMigrationSource(_ data: Data) throws {
        let backupURL = profileURL.deletingLastPathComponent()
            .appending(component: "profile.pre-migration.json")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: backupURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func migrateRecords(from items: [ProfileItem], subjectID: UUID) -> [ProfileRecord] {
        items.compactMap { item in
            let kind: ProfileRecordKind
            switch item.category {
            case .education: kind = .education
            case .course: kind = .course
            case .skill, .language: kind = .skill
            case .certificate: kind = .certificate
            case .project: kind = .project
            case .internship, .work: kind = .employment
            case .campus, .volunteer, .award, .selfIntroduction: kind = .experience
            case .identity, .contact, .other: return nil
            }
            var components = item.components
            components["fieldID"] = item.fieldID
            components["value"] = item.value
            return ProfileRecord(
                id: item.id,
                subjectID: subjectID,
                kind: kind,
                businessKey: ProfileBusinessKey.make(
                    kind: kind,
                    subjectID: subjectID,
                    components: components
                ),
                displayValue: item.value,
                components: components,
                sources: item.sources,
                confirmedComponentKeys: item.state == .confirmed ? Set(components.keys) : [],
                updatedAt: item.updatedAt
            )
        }
    }
}
