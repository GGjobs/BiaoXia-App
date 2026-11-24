import Foundation

struct LocalRuleAnswerMatcher: AnswerMatching {
    private struct Candidate {
        let value: String
        let record: ProfileRecord
        let componentKey: String
        let isConfirmed: Bool
    }

    func match(
        fields: [DynamicFormField],
        subjects: [ProfileSubject],
        records: [ProfileRecord]
    ) async throws -> [String: PersonalAnswer] {
        var answers: [String: PersonalAnswer] = [:]
        for field in fields {
            if let existing = field.answer,
               existing.modifiedByUser || [.confirmed, .intentionallyBlank].contains(existing.confirmationState) {
                answers[field.id] = existing
                continue
            }
            answers[field.id] = answer(for: field, subjects: subjects, records: records)
        }
        return answers
    }

    private func answer(
        for field: DynamicFormField,
        subjects: [ProfileSubject],
        records: [ProfileRecord]
    ) -> PersonalAnswer {
        if FormRecordMatcher.key(for: field) != nil {
            let records = FormRecordMatcher.candidates(field: field, records: records, subjects: subjects)
            guard records.count == 1, let record = records.first else {
                return unresolved(records.isEmpty ? "资料中没有可用答案" : "请选择用于本字段的资料", sourceIDs: records.map(\.id))
            }
            let value = FormRecordMatcher.value(record: record, field: field)
            guard !value.isEmpty else { return unresolved("所选资料没有对应内容，请补充") }
            return PersonalAnswer(value: value, selectedOptionIDs: [], sourceRecordIDs: [record.id],
                confirmationState: .suggested, modifiedByUser: false, reviewReasons: ["请核对所用资料及内容"])
        }
        guard let canonicalKey = canonicalKey(for: field) else {
            return unresolved("未知字段，需人工填写")
        }
        let subjectResult = targetSubject(for: field, subjects: subjects)
        guard case let .success(subject) = subjectResult else {
            return unresolved(subjectResult.reason)
        }

        let matchingRecords = recordsForContext(
            field: field,
            canonicalKey: canonicalKey,
            subjectID: subject.id,
            records: records
        )
        let matches = candidates(
            canonicalKey: canonicalKey,
            subjectID: subject.id,
            records: matchingRecords
        )
        guard !matches.isEmpty else {
            if canonicalKey == "fullname", !subject.displayName.isEmpty {
                return validate(
                    value: subject.displayName,
                    selectedOptionIDs: [],
                    sourceRecordIDs: [],
                    field: field,
                    confirmed: subject.kind == .selfPerson,
                    reasons: subject.kind == .selfPerson ? [] : ["关系人物姓名需人工确认"]
                )
            }
            return unresolved(field.constraints.isRequired ? "缺少必填资料" : "资料中没有可用答案")
        }

        let distinct = Dictionary(grouping: matches, by: { normalize($0.value) })
        if distinct.count > 1 {
            let values = distinct.values.compactMap(\.first)
            if containsQualifiedVariant(values.map(\.value)) {
                return unresolved("候选存在包含关系或限定词变体冲突", sourceIDs: values.map { $0.record.id })
            }
            return unresolved("存在多个不同候选，已停止自动匹配：" + values.map { "\($0.value)（\($0.record.components["label"] ?? "身份资料")）" }.sorted().joined(separator: "；"), sourceIDs: values.map { $0.record.id })
        }

        let group = distinct.values.first ?? []
        let candidate = group.sorted {
            if $0.isConfirmed != $1.isConfirmed { return $0.isConfirmed }
            return $0.record.updatedAt > $1.record.updatedAt
        }.first!
        var reasons: [String] = []
        if !candidate.isConfirmed {
            reasons.append("来源尚未确认")
        }
        let selection = selection(for: candidate.value, field: field)
        if let reason = selection.reason {
            reasons.append(reason)
        }
        return validate(
            value: selection.value,
            selectedOptionIDs: selection.optionIDs,
            sourceRecordIDs: group.map { $0.record.id },
            field: field,
            confirmed: candidate.isConfirmed,
            reasons: reasons
        )
    }

    private func recordsForContext(
        field: DynamicFormField,
        canonicalKey: String,
        subjectID: UUID,
        records: [ProfileRecord]
    ) -> [ProfileRecord] {
        let subjectRecords = records.filter { $0.subjectID == subjectID }
        let context = [field.section, field.label, field.instructions]
            .compactMap { $0 }
            .joined(separator: " ")
        guard ["school", "college", "major"].contains(canonicalKey),
              context.contains("最高"),
              context.contains("学历") || context.contains("学位") else {
            return subjectRecords
        }

        let educationRecords = subjectRecords.filter { $0.kind == .education }
        let ranked = educationRecords.compactMap { record -> (ProfileRecord, Int)? in
            let level = record.components.first { key, _ in
                ["educationlevel", "degree", "学历", "学位"].contains(normalizeKey(key))
            }?.value ?? ""
            guard let rank = educationRank(level) else { return nil }
            return (record, rank)
        }
        guard let highest = ranked.map(\.1).max() else { return subjectRecords }
        return ranked.filter { $0.1 == highest }.map(\.0)
    }

    private func educationRank(_ value: String) -> Int? {
        let normalized = normalize(value)
        let levels: [(Int, [String])] = [
            (6, ["博士", "doctor", "phd"]),
            (5, ["硕士", "研究生", "master"]),
            (4, ["本科", "学士", "bachelor"]),
            (3, ["大专", "专科", "associate"]),
            (2, ["高中", "中专"]),
            (1, ["初中", "小学"])
        ]
        return levels.first { _, aliases in
            aliases.contains { normalized.contains(normalize($0)) }
        }?.0
    }

    private func candidates(
        canonicalKey: String,
        subjectID: UUID,
        records: [ProfileRecord]
    ) -> [Candidate] {
        let keys = aliases(for: canonicalKey)
        return records.filter { $0.subjectID == subjectID && accepts(kind: $0.kind, for: canonicalKey) }.flatMap { record in
            record.components.compactMap { key, value in
                let normalizedKey = normalizeKey(key)
                let fieldID = record.components["fieldID"].map(normalizeKey)
                let label = record.components["label"].map(normalizeKey)
                guard keys.contains(normalizedKey)
                        || (normalizedKey == "value" && (fieldID.map(keys.contains) == true || label.map(keys.contains) == true))
                else { return nil }
                let confirmed = record.confirmedComponentKeys.contains(key)
                    || record.confirmedComponentKeys.contains("value")
                return Candidate(value: value, record: record, componentKey: key, isConfirmed: confirmed)
            }
        }
    }

    // Match the semantic component only inside the appropriate record category.
    // In particular, a course/project "name" must never become a person's name.
    private func accepts(kind: ProfileRecordKind, for key: String) -> Bool {
        switch key {
        case "fullname", "englishname", "birthdate", "gender": return kind == .identity
        case "phone", "email", "address": return kind == .contact
        case "school", "college", "major", "studentid", "educationlevel": return kind == .education
        case "employer": return kind == .employment
        default: return true
        }
    }

    /// nil means an unknown field; an empty array means a known field has no candidates.
    func candidateRecords(for field: DynamicFormField, subjects: [ProfileSubject], records: [ProfileRecord]) -> [ProfileRecord]? {
        guard let key = canonicalKey(for: field) else { return nil }
        guard case let .success(subject) = targetSubject(for: field, subjects: subjects) else { return [] }
        let scoped = recordsForContext(field: field, canonicalKey: key, subjectID: subject.id, records: records)
        let ids = Set(candidates(canonicalKey: key, subjectID: subject.id, records: scoped).map { $0.record.id })
        return records.filter { ids.contains($0.id) }
    }

    private func validate(
        value: String?,
        selectedOptionIDs: [String],
        sourceRecordIDs: [UUID],
        field: DynamicFormField,
        confirmed: Bool,
        reasons: [String]
    ) -> PersonalAnswer {
        var reviewReasons = reasons
        if let value {
            if let maximum = field.constraints.maximumCharacters, value.count > maximum {
                reviewReasons.append("答案超过最大字数")
            }
            if let maximumLines = field.constraints.maximumLines,
               value.split(separator: "\n", omittingEmptySubsequences: false).count > maximumLines {
                reviewReasons.append("答案超过最大行数")
            }
            if field.kind == .date, !validDate(value, format: field.constraints.dateFormat) {
                reviewReasons.append("日期无效或格式不符")
            }
        }
        if field.kind == .singleChoice, selectedOptionIDs.count != 1 {
            reviewReasons.append("单选答案无法唯一对应选项")
        }
        if field.kind == .multipleChoice {
            let minimum = field.constraints.minimumSelections ?? 0
            if selectedOptionIDs.count < minimum { reviewReasons.append("选择数量不足") }
            if let maximum = field.constraints.maximumSelections, selectedOptionIDs.count > maximum {
                reviewReasons.append("选择数量超限")
            }
        }
        return PersonalAnswer(
            value: value,
            selectedOptionIDs: selectedOptionIDs,
            sourceRecordIDs: Array(Set(sourceRecordIDs)),
            confirmationState: reviewReasons.isEmpty && confirmed ? .confirmed : .suggested,
            modifiedByUser: false,
            reviewReasons: reviewReasons
        )
    }

    private func selection(
        for rawValue: String,
        field: DynamicFormField
    ) -> (value: String?, optionIDs: [String], reason: String?) {
        guard [.singleChoice, .multipleChoice].contains(field.kind) else {
            return (format(rawValue, for: field), [], nil)
        }
        let pieces = field.kind == .singleChoice
            ? [rawValue]
            : rawValue.split(whereSeparator: { "、,，;；/\n".contains($0) }).map(String.init)
        var selected: [String] = []
        for piece in pieces {
            let normalizedPiece = normalize(piece)
            let matchingOptions = field.options.filter {
                normalize($0.label) == normalizedPiece || normalize($0.exportValue) == normalizedPiece
            }
            guard matchingOptions.count == 1 else {
                return (nil, [], "答案不能明确对应表单选项")
            }
            selected.append(matchingOptions[0].id)
        }
        return (rawValue, Array(Set(selected)), nil)
    }

    private func format(_ value: String, for field: DynamicFormField) -> String {
        guard field.kind == .date, let format = field.constraints.dateFormat else { return value }
        let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 3 else { return value }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
        guard let date = calendar.date(from: components) else { return value }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == numbers[0],
              roundTrip.month == numbers[1],
              roundTrip.day == numbers[2] else { return value }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func validDate(_ value: String, format: String?) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format ?? "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private func canonicalKey(for field: DynamicFormField) -> String? {
        let label = normalize(field.label).replacingOccurrences(of: "*", with: "")
        // A model's canonical key cannot resolve a person's ambiguous affiliation.
        // Only an explicit human meaning correction can authorize that choice.
        if (label.contains("所属单位") || label == "单位"), field.meaning.state != .userSpecified { return nil }
        if let key = field.meaning.canonicalKey { return normalizeKey(key) }
        if ["紧急联系人", "紧急联络人", "联系人", "联络人"].contains(label) { return "fullname" }
        // Prefer the most specific label, deterministically: English name must not
        // become full name, and highest-degree school must not become degree.
        var matches: [(key: String, length: Int)] = []
        for (key, aliases) in knownAliases {
            for alias in aliases where label.contains(normalize(alias)) {
                matches.append((key, normalize(alias).count))
            }
        }
        matches.sort { $0.length == $1.length ? $0.key < $1.key : $0.length > $1.length }
        return matches.first?.key
    }

    func targetSubject(
        for field: DynamicFormField,
        subjects: [ProfileSubject]
    ) -> Result<ProfileSubject, SubjectFailure> {
        let context = [field.section, field.label, field.instructions].compactMap { $0 }.joined(separator: " ")
        let relationshipTerms = ["父亲", "母亲", "父母", "配偶", "家属", "监护人", "紧急联系人", "紧急联络人", "联系人", "联络人"]
        if let term = relationshipTerms.first(where: { context.contains($0) }) {
            let candidates = subjects.filter {
                $0.relationshipToSelf?.contains(term) == true
                    || ((term.contains("联系人") || term.contains("联络人")) && $0.kind == .emergencyContact)
                    || (["父母", "家属", "监护人"].contains(term) && $0.kind == .familyMember)
            }
            guard candidates.count == 1, let subject = candidates.first else {
                return .failure(SubjectFailure(reason: candidates.isEmpty ? "缺少对应关系人物资料" : "关系人物不唯一"))
            }
            return .success(subject)
        }
        guard let selfSubject = subjects.first(where: { $0.kind == .selfPerson }) else {
            return .failure(SubjectFailure(reason: "缺少本人资料主体"))
        }
        return .success(selfSubject)
    }

    private func unresolved(_ reason: String, sourceIDs: [UUID] = []) -> PersonalAnswer {
        PersonalAnswer(
            value: nil,
            selectedOptionIDs: [],
            sourceRecordIDs: Array(Set(sourceIDs)),
            confirmationState: .unresolved,
            modifiedByUser: false,
            reviewReasons: [reason]
        )
    }

    private func containsQualifiedVariant(_ values: [String]) -> Bool {
        let normalized = values.map(normalize)
        return normalized.indices.contains { left in
            normalized.indices.contains { right in
                left != right
                    && normalized[left] != normalized[right]
                    && (normalized[left].contains(normalized[right]) || normalized[right].contains(normalized[left]))
            }
        }
    }

    private func aliases(for key: String) -> Set<String> {
        var values = knownAliases[key] ?? []
        values.append(key)
        return Set(values.map(normalizeKey))
    }

    private func normalizeKey(_ value: String) -> String {
        normalize(value).lowercased()
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s_\-:：()（）]"#, with: "", options: .regularExpression)
            .lowercased()
    }

    private var knownAliases: [String: [String]] {
        [
            "fullname": ["姓名", "名字", "本人姓名", "name"],
            "englishname": ["英文姓名", "英文名", "english name"],
            "phone": ["手机", "手机号", "联系电话", "电话"],
            "email": ["邮箱", "电子邮箱", "email"],
            "address": ["地址", "联系地址", "住址"],
            "birthdate": ["出生日期", "出生年月", "生日"],
            "gender": ["性别"],
            "school": ["学校", "院校", "毕业院校", "最高学历毕业院校"],
            "college": ["学院", "院系"],
            "major": ["专业", "主修"],
            "studentid": ["学号", "学生编号"],
            "educationlevel": ["最高学历", "学历", "学位"],
            "employer": ["单位", "工作单位", "任职单位"]
        ]
    }
}

struct SubjectFailure: Error {
    let reason: String
}

private extension Result where Failure == SubjectFailure {
    var reason: String {
        switch self {
        case .success: ""
        case let .failure(error): error.reason
        }
    }
}
