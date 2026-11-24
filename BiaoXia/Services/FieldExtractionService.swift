import Foundation

protocol FieldExtracting: Sendable {
    func extract(from blocks: [OCRBlock]) -> (
        candidates: [FieldCandidate],
        resolved: [ResolvedField]
    )
}

protocol ProfileItemExtracting: Sendable {
    func extractItems(from blocks: [OCRBlock], materials: [MaterialAsset]) -> [ProfileItem]
}

struct FieldDefinition: Sendable {
    let key: FieldKey
    let aliases: [String]
    let validationPattern: String?
    let normalizer: @Sendable (String) -> String
}

struct RuleBasedFieldExtractor: FieldExtracting {
    private struct RawMatch {
        let value: String
        let block: OCRBlock
        let labelQuality: Double
    }

    private let definitions: [FieldDefinition] = [
        FieldDefinition(
            key: .fullName,
            aliases: ["姓名", "名字"],
            validationPattern: #"^[\p{Han}·]{2,12}$"#,
            normalizer: Self.clean
        ),
        FieldDefinition(
            key: .gender,
            aliases: ["性别"],
            validationPattern: #"^(男|女|其他)$"#,
            normalizer: Self.normalizeGender
        ),
        FieldDefinition(
            key: .birthDate,
            aliases: ["出生日期", "出生年月", "生日"],
            validationPattern: #"^\d{4}-\d{2}-\d{2}$"#,
            normalizer: Self.normalizeDate
        ),
        FieldDefinition(
            key: .school,
            aliases: ["学校", "就读学校", "院校"],
            validationPattern: #"^[\p{Han}A-Za-z0-9（）()·]{4,40}$"#,
            normalizer: Self.clean
        ),
        FieldDefinition(
            key: .college,
            aliases: ["学院", "院系"],
            validationPattern: #"^[\p{Han}A-Za-z0-9（）()·]{2,40}$"#,
            normalizer: Self.clean
        ),
        FieldDefinition(
            key: .major,
            aliases: ["专业", "主修"],
            validationPattern: #"^[\p{Han}A-Za-z0-9（）()·]{2,40}$"#,
            normalizer: Self.clean
        ),
        FieldDefinition(
            key: .studentID,
            aliases: ["学号", "学生编号"],
            validationPattern: #"^[A-Za-z0-9-]{6,24}$"#,
            normalizer: Self.compact
        ),
        FieldDefinition(
            key: .phone,
            aliases: ["手机", "手机号", "联系电话", "电话"],
            validationPattern: #"^1[3-9]\d{9}$"#,
            normalizer: Self.digitsOnly
        ),
        FieldDefinition(
            key: .email,
            aliases: ["邮箱", "电子邮箱", "Email", "E-mail"],
            validationPattern: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#,
            normalizer: { Self.compact($0).lowercased() }
        ),
        FieldDefinition(
            key: .address,
            aliases: ["地址", "联系地址", "住址"],
            validationPattern: #"^.{6,80}$"#,
            normalizer: Self.clean
        )
    ]

    var materialLabels: [String] { definitions.flatMap(\.aliases) }

    func extract(from blocks: [OCRBlock]) -> (
        candidates: [FieldCandidate],
        resolved: [ResolvedField]
    ) {
        let ordered = blocks.sorted(by: readingOrder)
        var allCandidates: [FieldCandidate] = []
        var resolved: [ResolvedField] = []

        for definition in definitions {
            var rawMatches = labeledMatches(for: definition, in: ordered)
            rawMatches += patternMatches(for: definition, in: ordered)
            let candidates = applyingSemanticConflictRules(
                to: mergeAndScore(rawMatches, definition: definition),
                fieldKey: definition.key
            ).sorted { $0.score > $1.score }
            allCandidates += candidates

            if let best = candidates.first {
                resolved.append(
                    ResolvedField(
                        key: definition.key,
                        value: best.value,
                        candidateID: best.id,
                        confidence: best.score,
                        sourceBlockIDs: best.sourceBlockIDs,
                        resolvedByAI: false,
                        modifiedByUser: false
                    )
                )
            } else {
                resolved.append(
                    ResolvedField(
                        key: definition.key,
                        value: "",
                        candidateID: nil,
                        confidence: 0,
                        sourceBlockIDs: [],
                        resolvedByAI: false,
                        modifiedByUser: false
                    )
                )
            }
        }

        return (allCandidates, resolved)
    }

    private func labeledMatches(
        for definition: FieldDefinition,
        in blocks: [OCRBlock]
    ) -> [RawMatch] {
        var results: [RawMatch] = []
        for (index, block) in blocks.enumerated() {
            for alias in definition.aliases.sorted(by: { $0.count > $1.count }) {
                guard let aliasRange = block.text.range(
                    of: alias,
                    options: [.anchored, .caseInsensitive, .diacriticInsensitive]
                ) else { continue }

                let rawSuffix = String(block.text[aliasRange.upperBound...])
                let leadingCharacter = rawSuffix
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .first
                guard rawSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || leadingCharacter.map({ "：:|丨-—".contains($0) }) == true else {
                    continue
                }

                let suffix = rawSuffix
                    .trimmingCharacters(in: CharacterSet(charactersIn: "：:|丨-— \t"))
                let value = definition.normalizer(
                    valueBeforeNextLabel(in: suffix)
                )
                if isPlausible(value, for: definition.key) {
                    results.append(RawMatch(value: value, block: block, labelQuality: 1))
                } else if let neighbor = nearestValueBlock(
                    after: index,
                    label: block,
                    blocks: blocks
                ) {
                    let neighborValue = definition.normalizer(neighbor.text)
                    if isPlausible(neighborValue, for: definition.key) {
                        results.append(
                            RawMatch(value: neighborValue, block: neighbor, labelQuality: 0.75)
                        )
                    }
                }
                break
            }
        }
        return results
    }

    private func patternMatches(
        for definition: FieldDefinition,
        in blocks: [OCRBlock]
    ) -> [RawMatch] {
        let pattern: String?
        switch definition.key {
        case .email:
            pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        case .phone:
            pattern = #"(?<!\d)1[3-9]\d{9}(?!\d)"#
        case .birthDate:
            pattern = #"(?:19|20)\d{2}[年./-]\d{1,2}[月./-]\d{1,2}日?"#
        case .gender:
            pattern = #"(?:性别[：:\s]*)?(男|女)"#
        case .studentID:
            pattern = #"(?:学号|学生编号)[：:\s]*([A-Za-z0-9-]{6,24})"#
        default:
            pattern = nil
        }
        guard let pattern, let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return blocks.compactMap { block in
            let range = NSRange(block.text.startIndex..., in: block.text)
            guard let match = regex.firstMatch(in: block.text, range: range),
                  let swiftRange = Range(
                    match.range(at: match.numberOfRanges > 1 ? 1 : 0),
                    in: block.text
                  ) else { return nil }
            let value = definition.normalizer(String(block.text[swiftRange]))
            guard isPlausible(value, for: definition.key) else { return nil }
            return RawMatch(value: value, block: block, labelQuality: 0.45)
        }
    }

    private func mergeAndScore(
        _ rawMatches: [RawMatch],
        definition: FieldDefinition
    ) -> [FieldCandidate] {
        let grouped = Dictionary(grouping: rawMatches) { $0.value }
        return grouped.compactMap { value, matches in
            guard !value.isEmpty else { return nil }
            let averageOCR = matches.map(\.block.confidence).reduce(0, +)
                / Double(matches.count)
            let formatScore = validates(value, definition: definition) ? 1.0 : 0.25
            let labelScore = matches.map(\.labelQuality).max() ?? 0
            let distinctMaterials = Set(matches.map(\.block.materialID)).count
            let consistencyScore = distinctMaterials > 1 ? 1.0 : 0.5
            let score = min(
                1,
                averageOCR * 0.45
                    + formatScore * 0.25
                    + labelScore * 0.20
                    + consistencyScore * 0.10
            )

            return FieldCandidate(
                fieldKey: definition.key,
                value: value,
                sourceBlockIDs: Array(Set(matches.map(\.block.id))),
                score: score,
                scoreReasons: [
                    "OCR \(Int(averageOCR * 100))%",
                    formatScore == 1 ? "格式通过" : "格式待核对",
                    "标签邻近 \(Int(labelScore * 100))%",
                    distinctMaterials > 1 ? "跨材料一致" : "单一材料"
                ]
            )
        }
    }

    private func applyingSemanticConflictRules(
        to candidates: [FieldCandidate],
        fieldKey: FieldKey
    ) -> [FieldCandidate] {
        guard [.school, .college, .major].contains(fieldKey) else { return candidates }
        let conflictingIDs = Set(candidates.flatMap { candidate in
            candidates.compactMap { other -> UUID? in
                guard candidate.id != other.id else { return nil }
                let left = semanticComparisonValue(candidate.value)
                let right = semanticComparisonValue(other.value)
                guard left != right, left.contains(right) || right.contains(left) else { return nil }
                return candidate.id
            }
        })
        guard !conflictingIDs.isEmpty else { return candidates }
        let conflictingScores = candidates
            .filter { conflictingIDs.contains($0.id) }
            .map(\.score)
        let conflictCeiling = (conflictingScores.min() ?? 0) + 0.05
        return candidates.map { candidate in
            guard conflictingIDs.contains(candidate.id) else { return candidate }
            return FieldCandidate(
                id: candidate.id,
                fieldKey: candidate.fieldKey,
                value: candidate.value,
                sourceBlockIDs: candidate.sourceBlockIDs,
                score: min(candidate.score, conflictCeiling),
                scoreReasons: candidate.scoreReasons + ["包含关系或限定词变体冲突，需人工确认"]
            )
        }
    }

    private func semanticComparisonValue(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .lowercased()
    }

    private func nearestValueBlock(
        after index: Int,
        label: OCRBlock,
        blocks: [OCRBlock]
    ) -> OCRBlock? {
        // Word 材料只保留结构关系，没有可用于猜测邻近字段的页面坐标。
        guard label.pageIndex >= 0 else { return nil }
        let upperBound = min(blocks.count, index + 5)
        let nearby = blocks[(index + 1)..<upperBound]
            .filter {
                $0.materialID == label.materialID
                    && $0.pageIndex == label.pageIndex
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !isKnownLabelOnly($0.text)
            }
        let sameLine = nearby.filter {
            abs($0.boundingBox.y - label.boundingBox.y) <= 0.025
                && $0.boundingBox.x > label.boundingBox.x
        }
        if let bestSameLine = sameLine.min(by: {
            $0.boundingBox.x < $1.boundingBox.x
        }) {
            return bestSameLine
        }
        return nearby
            .min {
                neighborDistance($0, label) < neighborDistance($1, label)
            }
    }

    private func neighborDistance(_ candidate: OCRBlock, _ label: OCRBlock) -> Double {
        let horizontal = abs(candidate.boundingBox.x - label.boundingBox.x)
        let vertical = abs(candidate.boundingBox.y - label.boundingBox.y)
        return vertical * 2 + horizontal
    }

    private func isKnownLabelOnly(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(
            in: CharacterSet(charactersIn: "：:|丨-— \t\n")
        )
        return definitions
            .flatMap(\.aliases)
            .contains { cleaned.caseInsensitiveCompare($0) == .orderedSame }
    }

    private func valueBeforeNextLabel(in suffix: String) -> String {
        var endIndex = suffix.endIndex
        for alias in definitions.flatMap(\.aliases) {
            if let range = suffix.range(
                of: alias,
                options: [.caseInsensitive, .diacriticInsensitive]
            ), range.lowerBound < endIndex {
                endIndex = range.lowerBound
            }
        }
        return String(suffix[..<endIndex])
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:|丨-—,，;； \t"))
    }

    private func validates(_ value: String, definition: FieldDefinition) -> Bool {
        guard let pattern = definition.validationPattern else { return !value.isEmpty }
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func isPlausible(_ value: String, for key: FieldKey) -> Bool {
        guard !value.isEmpty else { return false }
        switch key {
        case .fullName: return value.count <= 12 && !value.contains("@")
        case .gender: return ["男", "女", "其他"].contains(value)
        case .birthDate: return value.count == 10
        case .school, .college, .major: return (2...40).contains(value.count)
        case .studentID: return (6...24).contains(value.count)
        case .phone: return value.count == 11
        case .email: return value.contains("@")
        case .address: return value.count >= 6
        }
    }

    private func readingOrder(_ lhs: OCRBlock, _ rhs: OCRBlock) -> Bool {
        if lhs.materialID != rhs.materialID {
            return lhs.materialID.uuidString < rhs.materialID.uuidString
        }
        if lhs.pageIndex != rhs.pageIndex {
            return lhs.pageIndex < rhs.pageIndex
        }
        if abs(lhs.boundingBox.y - rhs.boundingBox.y) > 0.02 {
            return lhs.boundingBox.y < rhs.boundingBox.y
        }
        return lhs.boundingBox.x < rhs.boundingBox.x
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:|丨-—,，;； \t\n"))
    }

    private static func compact(_ value: String) -> String {
        clean(value).replacingOccurrences(of: " ", with: "")
    }

    private static func digitsOnly(_ value: String) -> String {
        value.filter(\.isNumber)
    }

    private static func normalizeGender(_ value: String) -> String {
        let cleaned = clean(value)
        if cleaned.contains("男") { return "男" }
        if cleaned.contains("女") { return "女" }
        if cleaned.contains("其他") { return "其他" }
        return cleaned
    }

    private static func normalizeDate(_ value: String) -> String {
        let numbers = value.split(whereSeparator: { !$0.isNumber })
        guard numbers.count >= 3,
              let year = Int(numbers[0]),
              let month = Int(numbers[1]),
              let day = Int(numbers[2]) else {
            return clean(value)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

struct RuleBasedProfileItemExtractor: ProfileItemExtracting {
    private struct Definition {
        let labels: [String]
        let category: ProfileItemCategory
        let fieldID: String
        let sensitivity: ProfileItemSensitivity
    }

    private let definitions: [Definition] = [
        .init(labels: ["民族"], category: .identity, fieldID: "ethnicity", sensitivity: .personal),
        .init(labels: ["籍贯"], category: .identity, fieldID: "nativePlace", sensitivity: .personal),
        .init(labels: ["政治面貌"], category: .identity, fieldID: "politicalStatus", sensitivity: .personal),
        .init(labels: ["身份证号", "证件号码"], category: .identity, fieldID: "identityNumber", sensitivity: .highlySensitive),
        .init(labels: ["紧急联系人"], category: .contact, fieldID: "emergencyContact", sensitivity: .highlySensitive),
        .init(labels: ["学历"], category: .education, fieldID: "educationLevel", sensitivity: .normal),
        .init(labels: ["班级"], category: .education, fieldID: "className", sensitivity: .personal),
        .init(labels: ["入学时间"], category: .education, fieldID: "enrollmentDate", sensitivity: .personal),
        .init(labels: ["毕业时间"], category: .education, fieldID: "graduationDate", sensitivity: .personal),
        .init(labels: ["技能"], category: .skill, fieldID: "skill", sensitivity: .normal),
        .init(labels: ["语言能力", "语言"], category: .language, fieldID: "language", sensitivity: .normal),
        .init(labels: ["证书"], category: .certificate, fieldID: "certificate", sensitivity: .normal),
        .init(labels: ["获奖", "奖项"], category: .award, fieldID: "award", sensitivity: .normal),
        .init(labels: ["项目经历", "项目"], category: .project, fieldID: "project", sensitivity: .normal),
        .init(labels: ["实习经历", "实习"], category: .internship, fieldID: "internship", sensitivity: .normal),
        .init(labels: ["工作经历", "工作"], category: .work, fieldID: "work", sensitivity: .normal),
        .init(labels: ["校园经历"], category: .campus, fieldID: "campus", sensitivity: .normal),
        .init(labels: ["志愿经历", "志愿服务"], category: .volunteer, fieldID: "volunteer", sensitivity: .normal),
        .init(labels: ["个人简介", "自我介绍"], category: .selfIntroduction, fieldID: "selfIntroduction", sensitivity: .personal),
    ]

    var materialLabels: [String] { definitions.flatMap(\.labels) }

    func extractItems(from blocks: [OCRBlock], materials: [MaterialAsset]) -> [ProfileItem] {
        let materialByID = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
        var items: [ProfileItem] = []

        for block in blocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let course = courseItem(from: text, block: block, materialByID: materialByID) {
                items.append(course)
            }
            for definition in definitions {
                guard let match = labeledValue(in: text, labels: definition.labels) else { continue }
                let source = source(for: block, materialByID: materialByID)
                let components = componentsForExperience(match.value)
                items.append(
                    ProfileItem(
                        category: definition.category,
                        fieldID: definition.fieldID,
                        label: match.label,
                        value: match.value,
                        components: components,
                        confidence: block.confidence,
                        state: block.confidence >= 0.92 ? .autoExtracted : .pending,
                        sensitivity: definition.sensitivity,
                        sources: [source]
                    )
                )
                break
            }
        }

        var seen = Set<String>()
        return items.filter { seen.insert($0.normalizedIdentity).inserted }
    }

    private func labeledValue(in text: String, labels: [String]) -> (label: String, value: String)? {
        for label in labels.sorted(by: { $0.count > $1.count }) {
            guard let range = text.range(of: label, options: [.anchored, .caseInsensitive]) else { continue }
            let suffix = text[range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "：:|丨-— \t"))
            guard !suffix.isEmpty else { continue }
            return (label, suffix)
        }
        return nil
    }

    private func courseItem(
        from text: String,
        block: OCRBlock,
        materialByID: [UUID: MaterialAsset]
    ) -> ProfileItem? {
        let pattern = #"课程[：:]\s*([^|｜]+)[|｜]\s*学分[：:]\s*([^|｜]+)[|｜]\s*成绩[：:]\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 4,
              let nameRange = Range(match.range(at: 1), in: text),
              let creditRange = Range(match.range(at: 2), in: text),
              let scoreRange = Range(match.range(at: 3), in: text) else { return nil }
        let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
        let credits = String(text[creditRange]).trimmingCharacters(in: .whitespaces)
        let score = String(text[scoreRange]).trimmingCharacters(in: .whitespaces)
        return ProfileItem(
            category: .course,
            fieldID: "course",
            label: name,
            value: "\(name)（\(credits) 学分，成绩 \(score)）",
            components: ["name": name, "credits": credits, "score": score],
            confidence: block.confidence,
            state: block.confidence >= 0.92 ? .autoExtracted : .pending,
            sources: [source(for: block, materialByID: materialByID)]
        )
    }

    private func componentsForExperience(_ value: String) -> [String: String] {
        let parts = value.split(separator: "｜", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return [:] }
        var result = ["title": parts[0]]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "：", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
        return result
    }

    private func source(
        for block: OCRBlock,
        materialByID: [UUID: MaterialAsset]
    ) -> FieldSource {
        FieldSource(
            id: block.id,
            materialID: block.materialID,
            materialName: materialByID[block.materialID]?.displayName ?? "未知材料",
            pageIndex: block.pageIndex,
            excerpt: block.text,
            confidence: block.confidence
        )
    }
}
