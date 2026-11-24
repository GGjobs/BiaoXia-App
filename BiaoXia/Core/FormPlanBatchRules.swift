import Foundation

private struct PlannedSourceChunk {
    let id: String
    let sourceIDs: [String]
    let text: String
}

extension FormPlanRules {
    /// The same reviewed text is sent for each field group, spread over bounded requests.
    static func makeSourceBatches(_ draft: FormPlanDraft) throws -> [FormPlanBatch] {
        guard !draft.targets.isEmpty, !draft.sources.isEmpty else {
            throw ModuleFailure.blocked("请选择字段和资料。")
        }
        guard draft.sources.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ModuleFailure.blocked("所选资料中有空片段，请补充文字或取消选择。")
        }
        guard draft.sources.allSatisfy({ source in
            (source.recordID == nil && !source.originID.hasPrefix("profile-item-"))
                || String(source.text.prefix(while: { $0 != "\n" })).utf16.count <= 500
        }) else {
            throw ModuleFailure.blocked("建档记录的人物说明过长，请核对该记录。")
        }
        let groups = try fieldGroups(draft.targets.map(\.field))
        var limit = 6000
        while limit > 0 {
            let chunks = sourceChunks(draft.sources, maximumUnits: limit)
            if let batches = try packSourceBatches(groups: groups, chunks: chunks) { return batches }
            if limit == 1 { break }
            limit = max(1, limit / 2)
        }
        throw ModuleFailure.blocked("单个字段要求与最小资料片段仍超过 32 KB，请缩短该字段的填写要求或选项。")
    }

    private static func fieldGroups(_ fields: [FormPlanField]) throws -> [[FormPlanField]] {
        var groups: [[FormPlanField]] = []
        for field in fields {
            if let index = groups.firstIndex(where: { group in
                group.count < 8 && (group + [field]).filter({ $0.mode == .generated }).count <= 3
                    && estimatedOutputTokens(group + [field]) <= 4096
                    && fits(fields: group + [field], sources: [.init(id: "source-1", text: "字")])
            }) {
                groups[index].append(field)
            } else {
                guard fits(fields: [field], sources: [.init(id: "source-1", text: "字")]) else {
                    throw ModuleFailure.blocked("字段“\(field.label)”的要求或选项过长，单独发送也超过 32 KB。")
                }
                groups.append([field])
            }
        }
        return groups
    }

    /// Reserve JSON/evidence overhead and estimate Chinese output at 1.5 tokens per character.
    /// A field exceeding this estimate stays alone; the group budget prevents later additions.
    static func estimatedOutputTokens(_ fields: [FormPlanField]) -> Int {
        256 + fields.reduce(0) { total, field in
            total + Int(Double(field.mode == .generated ? field.maximumCharacters ?? 500 : 150) * 1.5) + 180
        }
    }

    private static func sourceChunks(_ sources: [FormPlanSource], maximumUnits: Int) -> [PlannedSourceChunk] {
        var chunks: [PlannedSourceChunk] = []
        var pending: [FormPlanSource] = []
        func packedText(_ items: [FormPlanSource]) -> String {
            if items.count == 1 { return items[0].text }
            return items.enumerated().map { "[资料 \($0.offset + 1)]\n\($0.element.text)" }.joined(separator: "\n")
        }
        func flush() {
            guard !pending.isEmpty else { return }
            chunks.append(.init(id: "source-\(chunks.count + 1)", sourceIDs: pending.map(\.id), text: packedText(pending)))
            pending = []
        }
        for source in sources {
            if source.text.utf16.count <= maximumUnits {
                if packedText(pending + [source]).utf16.count > maximumUnits { flush() }
                pending.append(source)
                continue
            }
            flush()
            let hasPerson = source.recordID != nil || source.originID.hasPrefix("profile-item-")
            let header = hasPerson ? String(source.text.prefix(while: { $0 != "\n" })) + "\n" : ""
            let payloadLimit = max(1, maximumUnits - header.utf16.count)
            var segment = ""
            var units = 0
            var isFirst = true
            func appendSegment() {
                guard !segment.isEmpty else { return }
                let prefix = isFirst ? "" : header
                chunks.append(.init(id: "source-\(chunks.count + 1)", sourceIDs: [source.id], text: prefix + segment))
                isFirst = false
                segment = ""
                units = 0
            }
            for character in source.text {
                let size = String(character).utf16.count
                if units + size > (isFirst ? maximumUnits : payloadLimit) { appendSegment() }
                segment.append(character)
                units += size
                if character == "\n", units >= (isFirst ? maximumUnits : payloadLimit) * 3 / 4 { appendSegment() }
            }
            appendSegment()
        }
        flush()
        return chunks
    }

    private static func packSourceBatches(groups: [[FormPlanField]], chunks: [PlannedSourceChunk]) throws -> [FormPlanBatch]? {
        var batches: [FormPlanBatch] = []
        for fields in groups {
            var index = 0
            while index < chunks.count {
                var selected: [PlannedSourceChunk] = []
                while index < chunks.count && selected.count < 20 {
                    let candidate = selected + [chunks[index]]
                    let snippets = candidate.map { AnswerSourceSnippet(id: $0.id, text: $0.text) }
                    if !fits(fields: fields, sources: snippets) { break }
                    selected = candidate
                    index += 1
                }
                guard !selected.isEmpty else { return nil }
                let request = FormPlanRequest(fields: fields, sources: selected.map { .init(id: $0.id, text: $0.text) })
                try validate(request)
                batches.append(FormPlanBatch(request: request,
                    sourceMembers: Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.sourceIDs) })))
            }
        }
        return batches
    }

    private static func fits(fields: [FormPlanField], sources: [AnswerSourceSnippet]) -> Bool {
        let request = FormPlanRequest(fields: fields, sources: sources)
        return (try? JSONEncoder().encode(request).count) .map { $0 <= 32 * 1024 } ?? false
    }

    private static func source(for evidence: FormPlanEvidence, batch: FormPlanBatch, draft: FormPlanDraft) -> FormPlanSource? {
        guard !evidence.quote.isEmpty,
              batch.request.sources.contains(where: { $0.id == evidence.sourceId && $0.text.contains(evidence.quote) }) else { return nil }
        let ids = batch.sourceMembers?[evidence.sourceId]
            ?? [batch.sourceOrigins?[evidence.sourceId] ?? evidence.sourceId]
        let matches = draft.sources.filter { ids.contains($0.id) && $0.text.contains(evidence.quote) }
        return matches.count == 1 ? matches[0] : nil
    }

    static func source(for evidence: FormPlanEvidence, targetID: String, draft: FormPlanDraft) -> FormPlanSource? {
        let matches = draft.batches.filter { $0.request.fields.contains { $0.id == targetID } }
            .compactMap { source(for: evidence, batch: $0, draft: draft) }
        let ids = Set(matches.map(\.id))
        return ids.count == 1 ? matches.first : nil
    }

    /// Bad or cross-source quotations invalidate only their field, never unrelated suggestions.
    static func validateOriginalEvidence(_ response: FormPlanResponse, batch: FormPlanBatch, draft: FormPlanDraft) -> FormPlanResponse {
        var checked = response
        for index in checked.suggestions.indices {
            if checked.suggestions[index].evidence.contains(where: { source(for: $0, batch: batch, draft: draft) == nil }) {
                checked.suggestions[index] = missingEvidence(for: checked.suggestions[index].fieldId)
            }
        }
        return checked
    }

    static func missingEvidence(for fieldID: String) -> FormPlanSuggestion {
        .init(fieldId: fieldID, status: .missing, answer: nil, selectedOptionIDs: [], evidence: [],
              reason: "摘录无法唯一定位到所选原始资料，请重新生成或手动填写。", generated: false)
    }

    static func sanitizeWireEvidence(_ response: FormPlanResponse, for request: FormPlanRequest) -> FormPlanResponse {
        var checked = response
        for index in checked.suggestions.indices {
            if checked.suggestions[index].evidence.contains(where: { evidence in
                evidence.quote.isEmpty || !request.sources.contains { $0.id == evidence.sourceId && $0.text.contains(evidence.quote) }
            }) { checked.suggestions[index] = missingEvidence(for: checked.suggestions[index].fieldId) }
        }
        return checked
    }

    private static func candidates(_ draft: FormPlanDraft, targetID: String) -> [FormPlanSuggestion]? {
        let rounds = draft.mergeRounds ?? []
        let batches = rounds.reversed().first(where: { round in
            round.contains { $0.request.fields.contains { $0.id == targetID } }
        })?.filter { $0.request.fields.contains { $0.id == targetID } }
            ?? draft.batches.filter { $0.request.fields.contains { $0.id == targetID } }
        guard !batches.isEmpty, batches.allSatisfy({ $0.response != nil }) else { return nil }
        return batches.compactMap { batch in batch.response?.suggestions.first { $0.fieldId == targetID } }
    }

    static func needsMerge(_ draft: FormPlanDraft, target: FormPlanTarget) -> Bool {
        guard target.field.mode == .generated, let items = candidates(draft, targetID: target.id),
              !items.contains(where: { $0.status == .manual || $0.status == .conflict }) else { return false }
        return items.filter { $0.status == .suggested }.count > 1
    }

    static func finalSuggestion(_ draft: FormPlanDraft, target: FormPlanTarget) -> FormPlanSuggestion? {
        guard let items = candidates(draft, targetID: target.id) else { return nil }
        if let blocked = items.first(where: { $0.status == .conflict || $0.status == .manual }) { return blocked }
        let suggested = items.filter { $0.status == .suggested }
        guard let first = suggested.first else {
            return FormPlanSuggestion(fieldId: target.id, status: .missing, answer: nil, selectedOptionIDs: [], evidence: [],
                reason: items.map(\.reason).filter { !$0.isEmpty }.joined(separator: "；").prefix(1000).description, generated: false)
        }
        if suggested.flatMap(\.evidence).contains(where: { source(for: $0, targetID: target.id, draft: draft) == nil }) {
            return missingEvidence(for: target.id)
        }
        let people = Set(suggested.flatMap(\.evidence).compactMap { evidence -> String? in
            guard let source = source(for: evidence, targetID: target.id, draft: draft),
                  source.recordID != nil || source.originID.hasPrefix("profile-item-") else { return nil }
            return String(source.text.prefix(while: { $0 != "\n" }))
        })
        if people.count > 1 || people.contains(where: { $0.contains("人物归属不明") }) {
            return FormPlanSuggestion(fieldId: target.id, status: .manual, answer: nil, selectedOptionIDs: [], evidence: [],
                reason: "依据涉及不同人物或人物归属不明，请人工核对。", generated: false)
        }
        if target.field.mode == .generated {
            return suggested.count == 1 ? first : nil
        }
        let same = suggested.allSatisfy { item in
            if !target.field.options.isEmpty { return Set(item.selectedOptionIDs) == Set(first.selectedOptionIDs) }
            return normalizedAnswer(item.answer ?? "") == normalizedAnswer(first.answer ?? "")
        }
        guard same else {
            return FormPlanSuggestion(fieldId: target.id, status: .conflict, answer: nil, selectedOptionIDs: [], evidence: [],
                reason: "不同资料批次给出不同答案，请核对人物和原文。", generated: false)
        }
        var combined = first
        combined.evidence = Array(Set(suggested.flatMap(\.evidence))).sorted { ($0.sourceId, $0.quote) < ($1.sourceId, $1.quote) }
        return combined
    }

    private static func normalizedAnswer(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"，。,:：;；、-/年月日".contains($0) }
    }

    static func makeMergeBatches(_ draft: FormPlanDraft) throws -> [FormPlanBatch] {
        guard draft.batches.allSatisfy({ $0.response != nil }) else { return [] }
        var result: [FormPlanBatch] = []
        for target in draft.targets where needsMerge(draft, target: target) {
            let items = candidates(draft, targetID: target.id)!.filter { $0.status == .suggested }
            var field = target.field
            field.instructions += "\n以下来源是未经人工确认的分批 AI 草稿。只合并有原文依据的事实，不添加新事实。"
            guard field.instructions.utf16.count <= 2000 else {
                throw ModuleFailure.blocked("字段“\(field.label)”的填写要求过长，无法加入长文合成说明。")
            }
            var index = 0
            while index < items.count {
                var snippets: [AnswerSourceSnippet] = []
                var lineage: [String: [FormPlanEvidence]] = [:]
                while index < items.count && snippets.count < 20 {
                    guard let answer = items[index].answer else { break }
                    let id = "source-\(snippets.count + 1)"
                    let candidate = snippets + [AnswerSourceSnippet(id: id, text: answer)]
                    if !fits(fields: [field], sources: candidate) { break }
                    snippets = candidate
                    lineage[id] = items[index].evidence
                    index += 1
                }
                guard !snippets.isEmpty else {
                    throw ModuleFailure.blocked("字段“\(field.label)”的分批草稿过长，请在合成前缩短草稿。")
                }
                let request = FormPlanRequest(fields: [field], sources: snippets)
                try validate(request)
                result.append(FormPlanBatch(request: request, evidenceLineage: lineage))
            }
            if result.filter({ $0.request.fields.contains { $0.id == target.id } }).count >= items.count {
                throw ModuleFailure.blocked("字段“\(field.label)”的草稿无法在请求边界内继续合并，请手动核对。")
            }
        }
        return result
    }

    static func remapMergeEvidence(_ response: FormPlanResponse, batch: FormPlanBatch) -> FormPlanResponse {
        var mapped = response
        for index in mapped.suggestions.indices {
            let cited = mapped.suggestions[index].evidence.flatMap { batch.evidenceLineage?[$0.sourceId] ?? [] }
            mapped.suggestions[index].evidence = Array(Set(cited)).sorted { ($0.sourceId, $0.quote) < ($1.sourceId, $1.quote) }
        }
        return mapped
    }
}
