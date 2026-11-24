import Foundation

/// Extended records are selected by both category and field identity: awards must not
/// accidentally consume every record stored in the broader experience category.
enum FormRecordMatcher {
    static let aliases: [String: [String]] = [
        "skills": ["技能", "语言能力", "skill", "language"],
        "certificates": ["证书", "certificate"], "awards": ["获奖", "奖项", "award"],
        "coreCourses": ["核心课程", "课程", "course"],
        "projectName": ["项目名称"], "projectRole": ["项目角色", "参赛角色", "个人分工"],
        "projectSummary": ["项目简介", "项目描述", "项目经历"],
        "selfIntroduction": ["个人简介", "自我介绍"],
        "experienceHighlights": ["经历摘要", "实践经历", "实习经历", "工作经历", "校园经历", "志愿经历"]
    ]
    static func key(for field: DynamicFormField) -> String? {
        if let key = field.meaning.canonicalKey {
            // Explicit meaning must not be overwritten by a broad label keyword.
            return aliases.keys.first(where: { $0.lowercased() == key.lowercased() })
        }
        let label = field.label.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*：:")))

        var matches: [(String, Int)] = []
        for (key, labels) in aliases {
            for candidate in labels where label.caseInsensitiveCompare(candidate) == .orderedSame {
                matches.append((key, candidate.count))
            }
        }
        matches.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return matches.first?.0
    }
    static func isSingleProject(_ field: DynamicFormField) -> Bool {
        ["projectName", "projectRole", "projectSummary"].contains(key(for: field) ?? "")
    }
    static func candidates(field: DynamicFormField, records: [ProfileRecord], subjects: [ProfileSubject]) -> [ProfileRecord] {
        let matcher = LocalRuleAnswerMatcher()
        guard case let .success(subject) = matcher.targetSubject(for: field, subjects: subjects) else { return [] }
        if key(for: field) == nil,
           let basic = matcher.candidateRecords(for: field, subjects: subjects, records: records) {
            return basic.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        let key = key(for: field)
        return records.filter { record in
            guard record.subjectID == subject.id else { return false }
            let identity = (record.components["fieldID"] ?? "").split(separator: ".").first.map { $0.lowercased() } ?? ""
            switch key {
            case "skills": return record.kind == .skill
            case "certificates": return record.kind == .certificate
            case "awards": return identity == "award" || identity == "awards"
            case "coreCourses": return record.kind == .course
            case "projectName", "projectRole", "projectSummary": return record.kind == .project
            case "selfIntroduction": return identity == "selfintroduction"
            case "experienceHighlights": return record.kind == .employment || ["campus", "volunteer", "internship", "work"].contains(identity)
            default: return true // Explicit manual selection is available for unknown fields.
            }
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    static func value(record: ProfileRecord, field: DynamicFormField) -> String {
        func first(_ keys: [String]) -> String {
            keys.compactMap { record.components[$0] }.first { !$0.isEmpty } ?? ""
        }
        switch key(for: field) {
        case "projectName": return first(["title", "name", "名称", "项目名称"])
        case "projectRole": return first(["role", "角色", "分工"])
        case "projectSummary": return first(["description", "描述", "value"])
        case "coreCourses": return first(["name", "value"])
        default: return record.components["value"] ?? record.displayValue
        }
    }
}
