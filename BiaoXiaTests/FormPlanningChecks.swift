import Foundation
#if !DOCX_STANDALONE
@testable import BiaoXia
#endif

/// Runs the production request/validation/adoption rules on macOS without starting a simulator.
enum FormPlanningChecks {
    static func run(repository: URL, output: URL) async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw DOCXEngineChecks.Failure(description: message) }; count += 1
        }
        func rejects(_ action: () throws -> Void, _ message: String) throws {
            do { try action() } catch { count += 1; return }
            throw DOCXEngineChecks.Failure(description: message)
        }
        let field = DynamicFormField(id: "local-name", label: "姓名", section: "本人", kind: .singleLineText,
            options: [], constraints: FormFieldConstraints(), anchors: [], meaning: FieldMeaning(state: .needsReview))
        let source = FormPlanSource(id: "source-1", originID: "local-material", title: "虚构材料", originalText: "本人姓名：林晓。父亲姓名：林山。", text: "本人姓名：林晓。父亲姓名：林山。")
        var doc = GeneralFormDocument(structureVersion: 3, fingerprint: DocumentFingerprint(algorithm: "fixture", value: "a", byteCount: 1), fields: [field])
        var draft = FormPlanDraft(fingerprint: doc.fingerprint, structureVersion: 3, sources: [source], targets: [FormPlanRules.target(field, number: 1)])
        let batches = try FormPlanRules.makeBatches(draft)
        try check(batches.count == 1, "单字段形成一个批次")
        let body = String(decoding: try JSONEncoder().encode(batches[0].request), as: UTF8.self)
        try check(!body.contains("local-material") && !body.contains("local-name") && !body.contains("originID"), "本地标识不出站")
        var suggestion = FormPlanSuggestion(fieldId: "field-1", status: .suggested, answer: "林晓", selectedOptionIDs: [], evidence: [.init(sourceId: "source-1", quote: "本人姓名：林晓")], reason: "", generated: false)
        var response = FormPlanResponse(schemaVersion: 1, requestId: batches[0].request.requestId, suggestions: [suggestion])
        try FormPlanRules.validate(response, for: batches[0].request); count += 1
        response.suggestions[0].answer = "虚构错误姓名"
        try rejects({ try FormPlanRules.validate(response, for: batches[0].request) }, "不能以合法来源掩盖虚构事实")
        response.suggestions[0] = suggestion; response.suggestions[0].generated = true
        try rejects({ try FormPlanRules.validate(response, for: batches[0].request) }, "不能通过生成标记绕过事实检查")
        response.suggestions[0] = suggestion; response.suggestions[0].evidence[0].sourceId = "source-2"
        try rejects({ try FormPlanRules.validate(response, for: batches[0].request) }, "未知来源拒绝")
        response.suggestions[0] = suggestion; response.suggestions[0].evidence[0].quote = "不存在的摘录"
        try rejects({ try FormPlanRules.validate(response, for: batches[0].request) }, "伪造摘录拒绝")
        var synthetic = batches[0]
        synthetic.request.sources[0].text = "人物：本人\n另页内容"
        synthetic.sourceOrigins = ["source-1": "source-1"]
        let crossBoundary = FormPlanResponse(schemaVersion: 1, requestId: synthetic.request.requestId,
            suggestions: [.init(fieldId: "field-1", status: .suggested, answer: "林晓", selectedOptionIDs: [],
                evidence: [.init(sourceId: "source-1", quote: "人物：本人\n另页内容")], reason: "", generated: false)])
        try check(FormPlanRules.validateOriginalEvidence(crossBoundary, batch: synthetic, draft: draft).suggestions[0].status == .missing,
            "重复人物提示不得伪装为原文跨页摘录")
        try check(FormPlanRules.canAdopt(draft.targets[0], current: field, result: suggestion, batch: true), "普通事实可批量采用")
        var edited = field
        edited.answer = PersonalAnswer(value: "人工输入", selectedOptionIDs: [], sourceRecordIDs: [], confirmationState: .suggested, modifiedByUser: true)
        try check(!FormPlanRules.canAdopt(draft.targets[0], current: edited, result: suggestion, batch: false), "手写答案受保护")
        for state in [FieldConfirmationState.confirmed, .intentionallyBlank, .blocked] {
            edited.answer?.modifiedByUser = false; edited.answer?.confirmationState = state
            try check(FormPlanRules.isProtected(edited), "确认或明确留空受保护")
        }
        try check(FormPlanRules.isCurrent(draft, document: doc, sources: [source]), "当前快照可使用")
        try check(!FormPlanRules.isCurrent(draft, document: doc, sources: []), "删除资料使旧草稿失效")
        var changed = source; changed.originalText += "新信息"
        try check(!FormPlanRules.isCurrent(draft, document: doc, sources: [changed]), "材料变化使旧草稿失效")
        doc.fields[0].label = "父亲姓名"
        try check(!FormPlanRules.isCurrent(draft, document: doc, sources: [source]), "人物字段改变使旧草稿失效")
        doc.fields[0] = field
        // Reproduce reviewing other answers before adopting an unchanged AI draft.
        let sibling = DynamicFormField(id: "local-summary", label: "经历摘要", kind: .multilineText,
            options: [], constraints: FormFieldConstraints(), anchors: [], meaning: FieldMeaning(state: .needsReview))
        var reviewDoc = doc; reviewDoc.fields.append(sibling)
        var reviewDraft = draft; reviewDraft.targets.append(FormPlanRules.target(sibling, number: 2))
        for state in [FieldConfirmationState.suggested, .confirmed, .intentionallyBlank, .blocked] {
            reviewDoc.fields[0].answer = PersonalAnswer(value: "人工核对", selectedOptionIDs: [], sourceRecordIDs: [],
                confirmationState: state, modifiedByUser: true)
            try check(FormPlanRules.isCurrent(reviewDraft, document: reviewDoc, sources: [source]), "其他答案变化不作废整表")
            try check(FormPlanRules.isTargetCurrent(reviewDraft.targets[1], document: reviewDoc), "未改经历摘要仍可核对采用")
            try check(!FormPlanRules.isTargetCurrent(reviewDraft.targets[0], document: reviewDoc), "已修改字段旧建议仍失效")
            try check(!FormPlanRules.canAdopt(reviewDraft.targets[0], current: reviewDoc.fields[0], result: suggestion, batch: false), "旧建议不能覆盖人工答案")
        }
        reviewDraft.adoptedFieldIDs.insert("field-1")
        try check(FormPlanRules.isCurrent(reviewDraft, document: reviewDoc, sources: [source]), "采用一个字段不影响其他建议")
        reviewDoc.fields[0].label = "父亲姓名"
        try check(!FormPlanRules.isCurrent(reviewDraft, document: reviewDoc, sources: [source]), "已采用字段定义变化仍触发结构校验")
        reviewDoc.fields[0] = field
        reviewDoc.structureVersion += 1
        try check(!FormPlanRules.isCurrent(reviewDraft, document: reviewDoc, sources: [source]), "结构版本变化仍失效")
        reviewDoc.structureVersion = doc.structureVersion
        try check(!FormPlanRules.isCurrent(reviewDraft, document: reviewDoc, sources: [changed]), "答案隔离不绕过来源变化校验")
        reviewDoc.planDraft = reviewDraft
        let reviewedRestore = try JSONDecoder().decode(GeneralFormDocument.self, from: JSONEncoder().encode(reviewDoc))
        try check(FormPlanRules.isCurrent(reviewedRestore.planDraft!, document: reviewedRestore, sources: [source])
            && FormPlanRules.isTargetCurrent(reviewDraft.targets[1], document: reviewedRestore), "恢复任务后仍按字段判断")
        suggestion.status = .conflict; suggestion.answer = nil; suggestion.reason = "姓名矛盾"
        try check(!FormPlanRules.canAdopt(draft.targets[0], current: field, result: suggestion, batch: false), "冲突必须人工处理")
        suggestion.status = .manual; suggestion.reason = "人物关系不明"
        try check(!FormPlanRules.canAdopt(draft.targets[0], current: field, result: suggestion, batch: false), "人物关系不明不采用")
        var long = field; long.label = "自我评价"; long.kind = .multilineText
        var signature = field; signature.label = "本人签名"
        try check(FormPlanRules.mode(for: signature) == .manual, "签名不得生成")
        draft.targets = (1...9).map { FormPlanRules.target(field, number: $0) } + [FormPlanRules.target(long, number: 10)]
        let grouped = try FormPlanRules.makeBatches(draft)
        try check(grouped.map { $0.request.fields.count } == [8, 2], "每批最多八字段且允许长文同组")
        draft.sources[0].text = String(repeating: "汉", count: 8001)
        let longBatches = try FormPlanRules.makeBatches(draft)
        try check(longBatches.allSatisfy { (try? FormPlanRules.validate($0.request)) != nil }, "长片段拆批后仍遵守协议")
        try check(longBatches.filter { $0.request.fields.contains { $0.id == "field-1" } }
            .flatMap { $0.request.sources }.map(\.text).joined() == draft.sources[0].text, "长片段原文完整覆盖")
        draft.sources = [source, source]; draft.sources[1].id = "source-2"
        draft.sources[0].text = String(repeating: "汉", count: 6000); draft.sources[1].text = draft.sources[0].text
        let largeBatches = try FormPlanRules.makeBatches(draft)
        try check(largeBatches.count >= 4 && largeBatches.allSatisfy { (try? FormPlanRules.validate($0.request)) != nil },
            "超过32KB时拆批而不放宽单次上限")
        doc.planDraft = nil
        let legacy = try JSONEncoder().encode(doc)
        try check(try JSONDecoder().decode(GeneralFormDocument.self, from: legacy).planDraft == nil, "旧快照没有整表草稿仍可读")
        draft.sources = [source]; draft.batches = batches; draft.batches[0].response = FormPlanResponse(schemaVersion: 1, requestId: batches[0].request.requestId, suggestions: [])
        draft.adoptedFieldIDs = ["field-1"]; doc.planDraft = draft
        let restored = try JSONDecoder().decode(GeneralFormDocument.self, from: JSONEncoder().encode(doc))
        try check(restored.planDraft == draft, "批次、来源和采用状态可恢复")

        // A real DOCX fixture runs through the same reviewed result types and actual writer.
        let url = repository.appending(path: "TestAssets/GeneralForms/debug/normal/F01-docx.docx")
        let originalBytes = try Data(contentsOf: url)
        var word = try await DOCXFormEngine().parse(formURL: url)
        guard let index = word.fields.firstIndex(where: { $0.label.contains("姓名") && $0.options.isEmpty }) else { throw DOCXEngineChecks.Failure(description: "缺少姓名字段") }
        let target = FormPlanRules.target(word.fields[index], number: 1)
        let request = FormPlanRequest(fields: [target.field], sources: [.init(id: "source-1", text: source.text)])
        let answer = FormPlanSuggestion(fieldId: "field-1", status: .suggested, answer: "林晓", selectedOptionIDs: [], evidence: [.init(sourceId: "source-1", quote: "本人姓名：林晓")], reason: "", generated: target.field.mode == .generated)
        try FormPlanRules.validate(FormPlanResponse(schemaVersion: 1, requestId: request.requestId, suggestions: [answer]), for: request)
        try check(FormPlanRules.canAdopt(target, current: word.fields[index], result: answer, batch: false), "Word建议通过核对规则")
        word.fields[index].answer = PersonalAnswer(value: "林晓", selectedOptionIDs: [], sourceRecordIDs: [], confirmationState: .confirmed, modifiedByUser: true,
            planSources: [.init(title: source.title, quote: answer.evidence[0].quote, originID: source.originID)])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for i in word.fields.indices where i != index && word.fields[i].constraints.isRequired {
            let field = word.fields[i]
            word.fields[i].answer = PersonalAnswer(value: field.kind == .date ? "2026-09-27" : "Lin Xiao",
                selectedOptionIDs: field.options.first.map { [$0.id] } ?? [], sourceRecordIDs: [], confirmationState: .confirmed, modifiedByUser: true)
        }
        let exported = output.appending(path: "t16-filled.docx")
        try await DOCXFormEngine().write(document: word, sourceURL: url, destinationURL: exported)
        let xml = String(decoding: try WordPackage(Data(contentsOf: exported)).part("word/document.xml"), as: UTF8.self)
        try check(xml.contains("林晓") && Data(contentsOf: url) == originalBytes, "Word写入成功且原件不变")
        return count
    }
}
