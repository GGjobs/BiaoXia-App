import CryptoKit
import Foundation

/// The only profile content eligible for AI requests. Original materials and record components
/// stay local; a grant covers this item's visible label and value, plus an anonymous person label.
struct ProfileAISharingEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let label: String
    let value: String
    let personLabel: String
    let text: String
    let fingerprint: String
    let recordID: UUID?
}

enum ProfileAISharing {
    static func entries(
        items: [ProfileItem],
        subjects: [ProfileSubject],
        records: [ProfileRecord]
    ) -> [ProfileAISharingEntry] {
        let subjectLabels = anonymousLabels(subjects: subjects)
        let selfSubjects = subjects.filter { $0.kind == .selfPerson }
        return items.compactMap { item in
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.state != .pending, !label.isEmpty, !value.isEmpty else { return nil }

            let subject: ProfileSubject?
            if let rawSubjectID = item.components["subjectID"] {
                let matches = subjects.filter { $0.id == UUID(uuidString: rawSubjectID) }
                subject = matches.count == 1 ? matches[0] : nil
            } else {
                subject = selfSubjects.count == 1 ? selfSubjects[0] : nil
            }
            let personLabel: String
            if let subject {
                personLabel = subjectLabels[subject.id] ?? "人物归属不明"
            } else if subjects.isEmpty && item.components["subjectID"] == nil {
                // Legacy libraries with no subject table contain the owner's own profile.
                personLabel = "本人"
            } else {
                personLabel = "人物归属不明"
            }

            // Person identity changes invalidate permission without sending the identity itself.
            let subjectSemantics = [
                item.components["subjectID"] ?? "",
                subject?.id.uuidString.lowercased() ?? "",
                subject?.kind.rawValue ?? "",
                subject?.displayName ?? "",
                subject?.relationshipToSelf ?? "",
                personLabel
            ]
            let fingerprint = digest([item.id.uuidString.lowercased(), label, value] + subjectSemantics)
            return ProfileAISharingEntry(
                id: item.id,
                label: label,
                value: value,
                personLabel: personLabel,
                text: "人物：\(personLabel)\n\(label)：\(value)",
                fingerprint: fingerprint,
                recordID: uniqueRecordID(for: item, subject: subject, records: records)
            )
        }
    }

    /// Fingerprint matching is deliberately separate from cross-item disclosure checks so the
    /// permission editor can explain an enabled item that is temporarily blocked by its content.
    static func isAllowed(_ entry: ProfileAISharingEntry, grants: [UUID: String]) -> Bool {
        grants[entry.id] == entry.fingerprint
    }

    static func allowedEntries(
        _ entries: [ProfileAISharingEntry],
        grants: [UUID: String]
    ) -> [ProfileAISharingEntry] {
        entries.filter { isAllowed($0, grants: grants) && blockedReason(for: $0, entries: entries, grants: grants) == nil }
    }

    static func blockedReason(
        for entry: ProfileAISharingEntry,
        entries: [ProfileAISharingEntry],
        grants: [UUID: String]
    ) -> String? {
        let label = comparisonText(entry.label)
        let value = comparisonText(entry.value)
        for denied in entries where !isAllowed(denied, grants: grants) {
            let deniedValue = comparisonText(denied.value)
            guard deniedValue.count >= 2 else { continue }
            // Identical complete values can be explicitly allowed on another item (for example,
            // duplicate school records). That exception never permits a longer narrative that
            // embeds a separately denied item, even if a third item permits the same value.
            guard value != deniedValue else { continue }
            if label.contains(deniedValue) || value.contains(deniedValue) {
                return "这项内容包含其他未允许 AI 使用的资料值，请调整内容或相关权限。"
            }
        }
        return nil
    }

    /// Fields and model-produced drafts can repeat private values too. Check every outgoing text,
    /// not only profile sources. An explicitly allowed duplicate value is already disclosed by
    /// its allowed source, so request-level checking does not reject that exact duplicate again.
    static func blockedReason(
        forText text: String,
        entries: [ProfileAISharingEntry],
        grants: [UUID: String]
    ) -> String? {
        let allowedValues = Set(entries.filter { isAllowed($0, grants: grants) }.map { comparisonText($0.value) })
        let outgoingText = comparisonText(text)
        for denied in entries where !isAllowed(denied, grants: grants) {
            let deniedValue = comparisonText(denied.value)
            guard deniedValue.count >= 2, !allowedValues.contains(deniedValue) else { continue }
            if outgoingText.contains(deniedValue) {
                return "待发送文字包含未允许 AI 使用的资料值，请调整内容或相关权限。"
            }
        }
        return nil
    }

    private static func comparisonText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func digest(_ components: [String]) -> String {
        // Length-prefixing prevents different label/value boundaries from producing the same input.
        let text = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func anonymousLabels(subjects: [ProfileSubject]) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for kind in ProfileSubjectKind.allCases {
            // UUID ordering keeps aliases unchanged when the caller reorders the subject table.
            let people = subjects.filter { $0.kind == kind }.sorted { $0.id.uuidString < $1.id.uuidString }
            for (index, subject) in people.enumerated() {
                let label: String
                switch kind {
                case .selfPerson: label = people.count == 1 ? "本人" : "本人\(index + 1)"
                case .familyMember: label = "家属\(index + 1)"
                case .emergencyContact: label = "联系人\(index + 1)"
                case .other: label = "其他人物\(index + 1)"
                }
                labels[subject.id] = label
            }
        }
        return labels
    }

    private static func uniqueRecordID(
        for item: ProfileItem,
        subject: ProfileSubject?,
        records: [ProfileRecord]
    ) -> UUID? {
        guard let subject, let kind = recordKind(for: item.category) else { return nil }
        var components = item.components
        components.removeValue(forKey: "subjectID")
        components["fieldID"] = item.fieldID.split(separator: ".").first.map(String.init) ?? item.fieldID
        components["label"] = item.label
        components["value"] = item.value
        let key = ProfileBusinessKey.make(kind: kind, subjectID: subject.id, components: components)
        let matches = records.filter {
            $0.businessKey == key && $0.subjectID == subject.id && $0.kind == kind
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func recordKind(for category: ProfileItemCategory) -> ProfileRecordKind? {
        switch category {
        case .education: .education
        case .course: .course
        case .skill, .language: .skill
        case .certificate: .certificate
        case .project: .project
        case .internship, .work: .employment
        case .campus, .volunteer, .award, .selfIntroduction: .experience
        case .identity: .identity
        case .contact: .contact
        case .other: nil
        }
    }
}
