import Foundation
#if !DOCX_STANDALONE
@testable import BiaoXia
#endif

/// Exercises the production permission projection on macOS, using fictional data only.
enum ProfileAISharingChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw DOCXEngineChecks.Failure(description: message) }
            count += 1
        }
        func rejects(_ action: () throws -> Void, _ message: String) throws {
            do { try action() } catch { count += 1; return }
            throw DOCXEngineChecks.Failure(description: message)
        }
        let privateID = "110101200001010099"
        let subject = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil,
            displayName: "未授权的人物显示名")
        let source = FieldSource(materialID: UUID(), materialName: "未授权的原始文件名.pdf", pageIndex: 0,
            excerpt: "完整 OCR 包含身份证号：\(privateID)", confidence: 1)
        let name = ProfileItem(category: .identity, fieldID: "fullName", label: "姓名", value: "林晓",
            components: ["privateComponent": privateID], confidence: 1, state: .confirmed, sources: [source])
        let student = ProfileItem(category: .education, fieldID: "studentID", label: "学号", value: "TEST20260042",
            confidence: 1, state: .confirmed)
        let identity = ProfileItem(category: .identity, fieldID: "identityNumber", label: "身份证号", value: privateID,
            confidence: 1, state: .confirmed, sensitivity: .highlySensitive)
        let custom = ProfileItem(category: .other, fieldID: "preferredSchedule", label: "可参加时段", value: "周六上午",
            confidence: 1, state: .confirmed)
        let items = [name, student, identity, custom]
        let entries = ProfileAISharing.entries(items: items, subjects: [subject], records: [])
        try check(Set(entries.map(\.id)) == Set(items.map(\.id)), "每个建档资料项都能独立管理权限")
        try check(ProfileAISharing.allowedEntries(entries, grants: [:]).isEmpty, "新资料默认不允许 AI 使用")
        let grants = Dictionary(uniqueKeysWithValues: entries.filter { [name.id, student.id].contains($0.id) }
            .map { ($0.id, $0.fingerprint) })
        let allowed = ProfileAISharing.allowedEntries(entries, grants: grants)
        try check(Set(allowed.map(\.id)) == Set([name.id, student.id]), "仅已授权姓名和学号可出站")
        let projected = allowed.map(\.text).joined(separator: "\n")
        try check(projected.contains(name.value) && projected.contains(student.value), "授权资料值保留")
        for secret in [privateID, source.materialName, source.excerpt, subject.displayName, "privateComponent"] {
            try check(!projected.contains(secret), "组件、来源原文、文件名与人物显示名不能附带出站")
        }

        var saved = ProfileLibrarySnapshot.empty()
        saved.profileItems = items
        saved.aiSharingGrants = grants
        let restored = try JSONDecoder().decode(ProfileLibrarySnapshot.self, from: JSONEncoder().encode(saved))
        try check(restored.aiSharingGrants == grants, "资料项授权可以随档案保存恢复")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        oldJSON["schemaVersion"] = 3
        oldJSON.removeValue(forKey: "aiSharingGrants")
        let legacy = try JSONDecoder().decode(ProfileLibrarySnapshot.self,
            from: JSONSerialization.data(withJSONObject: oldJSON))
        try check(ProfileAISharing.allowedEntries(entries, grants: legacy.aiSharingGrants ?? [:]).isEmpty,
            "旧档案缺少权限时默认拒绝")

        var changed = name
        changed.value = "林晓新值"
        let changedEntries = ProfileAISharing.entries(items: [changed, student, identity, custom], subjects: [subject], records: [])
        try check(!ProfileAISharing.allowedEntries(changedEntries, grants: grants).contains { $0.id == name.id },
            "资料值变更后旧授权失效")
        var relabeled = name
        relabeled.label = "曾用名"
        let relabeledEntries = ProfileAISharing.entries(items: [relabeled, student, identity, custom], subjects: [subject], records: [])
        try check(!ProfileAISharing.allowedEntries(relabeledEntries, grants: grants).contains { $0.id == name.id },
            "资料含义变更后旧授权失效")
        let remaining = ProfileAISharing.entries(items: [student, identity, custom], subjects: [subject], records: [])
        try check(!ProfileAISharing.allowedEntries(remaining, grants: grants).contains { $0.id == name.id },
            "资料删除后残留授权不能恢复来源")

        let customEntry = entries.first { $0.id == custom.id }!
        try check(ProfileAISharing.allowedEntries(entries, grants: [custom.id: customEntry.fingerprint]).map(\.id) == [custom.id],
            "自定义资料项可独立授权")
        let duplicate = ProfileItem(category: .other, fieldID: "nameAlias", label: "报名姓名", value: name.value,
            confidence: 1, state: .confirmed)
        let duplicateEntries = ProfileAISharing.entries(items: [name, duplicate], subjects: [subject], records: [])
        try check(ProfileAISharing.allowedEntries(duplicateEntries, grants: grants).map(\.id) == [name.id],
            "同值的未授权重复项不撤销用户对原资料项的显式授权")
        let mixed = ProfileItem(category: .selfIntroduction, fieldID: "introduction", label: "自我介绍",
            value: "我是林晓，身份证号为\(privateID)。", confidence: 1, state: .confirmed)
        let mixedEntries = ProfileAISharing.entries(items: items + [mixed], subjects: [subject], records: [])
        let mixedEntry = mixedEntries.first { $0.id == mixed.id }!
        var mixedGrants = grants
        mixedGrants[mixed.id] = mixedEntry.fingerprint
        try check(ProfileAISharing.isAllowed(mixedEntry, grants: mixedGrants), "混合内容保留用户的授权选择")
        try check(ProfileAISharing.blockedReason(for: mixedEntry, entries: mixedEntries, grants: mixedGrants) != nil,
            "混合内容明确说明夹带阻断原因")
        try check(!ProfileAISharing.allowedEntries(mixedEntries, grants: mixedGrants).contains { $0.id == mixed.id },
            "允许项不能夹带未授权身份证号")
        try check(ProfileAISharing.blockedReason(forText: "请核对身份证号\(privateID)", entries: entries, grants: grants) != nil,
            "字段说明和模型草稿也不能夹带未授权资料值")
        try check(ProfileAISharing.blockedReason(forText: "姓名：林晓", entries: entries, grants: grants) == nil,
            "请求中的已授权资料值不被误拦截")
        var renamedSubject = subject
        renamedSubject.displayName = "变更后的人物显示名"
        let movedEntries = ProfileAISharing.entries(items: items, subjects: [renamedSubject], records: [])
        try check(ProfileAISharing.allowedEntries(movedEntries, grants: grants).isEmpty,
            "资料归属人物变化后需要重新授权")

        let recordComponents = ["fieldID": student.fieldID, "label": student.label, "value": student.value]
        let studentRecord = ProfileRecord(id: UUID(), subjectID: subject.id, kind: .education,
            businessKey: ProfileBusinessKey.make(kind: .education, subjectID: subject.id, components: recordComponents),
            displayValue: student.value, components: recordComponents, sources: [],
            confirmedComponentKeys: ["value"], updatedAt: .now)
        let mapped = ProfileAISharing.entries(items: [student], subjects: [subject], records: [studentRecord])
        try check(mapped.first?.recordID == studentRecord.id && mapped.first?.id == student.id,
            "资料项与记录ID不相同时仍可保留本地来源映射")
        try check(!mapped[0].text.contains(studentRecord.id.uuidString), "记录映射标识不进入发送文字")

        let sources = allowed.enumerated().map { index, entry in
            FormPlanSource(id: "source-\(index + 1)", originID: "profile-\(entry.id)", title: entry.label,
                originalText: entry.text, text: entry.text, recordID: entry.recordID)
        }
        let nameField = DynamicFormField(id: "local-name", label: "姓名", kind: .singleLineText,
            options: [], constraints: .init(), anchors: [], meaning: .init(state: .needsReview))
        let draft = FormPlanDraft(fingerprint: .init(algorithm: "test", value: "sharing", byteCount: 1),
            structureVersion: 1, sources: sources, targets: [FormPlanRules.target(nameField, number: 1)])
        let batches = try FormPlanRules.makeBatches(draft)
        let wire = String(decoding: try JSONEncoder().encode(batches.map(\.request)), as: UTF8.self)
        try check(wire.contains(name.value) && wire.contains(student.value), "实际整表请求包含已授权资料")
        for secret in [privateID, source.materialName, source.excerpt, subject.displayName, name.id.uuidString] {
            try check(!wire.contains(secret), "实际请求不含禁止值、旁路元数据或本地标识")
        }

        var currentDraft = draft
        currentDraft.sharingPolicyVersion = 1
        currentDraft.batches = batches
        try ProfileAIRequestBoundary.validate(currentDraft, allowedSources: sources)
        count += 1
        try rejects({ try ProfileAIRequestBoundary.validate(draft, allowedSources: sources) },
            "没有资料项授权版本的旧草稿拒绝发送")
        try rejects({ try ProfileAIRequestBoundary.validate(currentDraft, allowedSources: []) },
            "准备完成后撤销权限也拒绝发送")
        var rawDraft = currentDraft
        rawDraft.sources[0] = FormPlanSource(id: "source-1", originID: "library-raw", title: source.materialName,
            originalText: source.excerpt, text: source.excerpt)
        try rejects({ try ProfileAIRequestBoundary.validate(rawDraft, allowedSources: sources) },
            "旧原文资料不能伪装为已授权建档项")
        var tamperedDraft = currentDraft
        tamperedDraft.batches[0].request.sources[0].text += "\n\(privateID)"
        try rejects({ try ProfileAIRequestBoundary.validate(tamperedDraft, allowedSources: sources) },
            "已保存批次的文本篡改不能绕过权限")
        tamperedDraft = currentDraft
        tamperedDraft.batches[0].sourceOrigins = ["source-1": "unapproved-origin"]
        try rejects({ try ProfileAIRequestBoundary.validate(tamperedDraft, allowedSources: sources) },
            "已保存批次的来源映射篡改不能绕过权限")
        var previewDraft = currentDraft
        previewDraft.sources[0].text += "\n\(privateID)"
        previewDraft.batches = []
        try rejects({ try ProfileAIRequestBoundary.validate(previewDraft, allowedSources: sources) },
            "改写资料预览不能夹带未授权内容")

        let compositionRequest = AnswerCompositionRequest(requestId: UUID(), fieldLabel: "姓名", instructions: "",
            sources: sources.map { AnswerSourceSnippet(id: $0.id, text: $0.text) })
        var composition = AnswerCompositionDraft(request: compositionRequest, recordIDs: [], originalAnswer: nil)
        try rejects({ try ProfileAIRequestBoundary.validate(composition, allowedSources: sources) },
            "旧单空整理草稿没有资料项授权快照时拒绝发送")
        composition.aiSources = sources
        try ProfileAIRequestBoundary.validate(composition, allowedSources: sources)
        count += 1
        try rejects({ try ProfileAIRequestBoundary.validate(composition, allowedSources: []) },
            "单空整理也受同一套撤权限制")
        composition.request.sources[0].text += "\n\(privateID)"
        try rejects({ try ProfileAIRequestBoundary.validate(composition, allowedSources: sources) },
            "单空整理请求不能绕过已授权快照加入文本")

        // Custom items intentionally have no record ID; their person scope must still apply.
        let otherPerson = ProfileSubject(id: UUID(), kind: .familyMember, relationshipToSelf: "父亲", displayName: "虚构家属")
        func customPersonItem(_ label: String, subjectID: UUID) -> ProfileItem {
            ProfileItem(category: .other, fieldID: label, label: label, value: "\(label)：已完成",
                components: ["subjectID": subjectID.uuidString], confidence: 1, state: .confirmed)
        }
        func personDraft(_ items: [ProfileItem], subjects: [ProfileSubject]) throws -> FormPlanDraft {
            let projected = ProfileAISharing.entries(items: items, subjects: subjects, records: [])
            let localSources = projected.enumerated().map { position, entry in
                FormPlanSource(id: "source-\(position + 1)", originID: "profile-item-\(entry.id)", title: entry.label,
                    originalText: entry.text, text: entry.text, recordID: entry.recordID)
            }
            var result = FormPlanDraft(fingerprint: draft.fingerprint, structureVersion: 1,
                sources: localSources, targets: draft.targets, sharingPolicyVersion: 1)
            result.batches = try FormPlanRules.makeBatches(result)
            for index in result.batches.indices {
                let request = result.batches[index].request
                let evidence = items.compactMap { item -> FormPlanEvidence? in
                    guard let wire = request.sources.first(where: { $0.text.contains(item.value) }) else { return nil }
                    return .init(sourceId: wire.id, quote: item.value)
                }
                result.batches[index].response = .init(schemaVersion: 1, requestId: request.requestId,
                    suggestions: [.init(fieldId: "field-1", status: .suggested, answer: "已完成",
                        selectedOptionIDs: [], evidence: evidence, reason: "", generated: false)])
            }
            return result
        }
        let unknownItem = customPersonItem("归属不明事项", subjectID: UUID())
        let unknownDraft = try personDraft([unknownItem], subjects: [subject])
        try check(unknownDraft.sources.first?.recordID == nil, "自定义资料不需要伪造结构化记录")
        try check(FormPlanRules.finalSuggestion(unknownDraft, target: unknownDraft.targets[0])?.status == .manual,
            "缺少记录ID的建档项仍阻止人物归属不明的自动采用")
        let mine = customPersonItem("本人事项", subjectID: subject.id)
        let theirs = customPersonItem("家属事项", subjectID: otherPerson.id)
        let differentPeople = try personDraft([mine, theirs], subjects: [subject, otherPerson])
        try check(differentPeople.sources.allSatisfy { $0.recordID == nil }, "不同人物的自定义项均无记录ID")
        try check(FormPlanRules.finalSuggestion(differentPeople, target: differentPeople.targets[0])?.status == .manual,
            "不同人物自定义项给出同一答案也必须人工核对")
        let alsoMine = customPersonItem("本人其他事项", subjectID: subject.id)
        let samePerson = try personDraft([mine, alsoMine], subjects: [subject])
        try check(FormPlanRules.finalSuggestion(samePerson, target: samePerson.targets[0])?.status == .suggested,
            "同一人物的不同自定义项不会误判为多人")
        var longCustom = custom
        longCustom.value = String(repeating: "虚构经历🙂", count: 2200)
        let longEntry = ProfileAISharing.entries(items: [longCustom], subjects: [subject], records: [])[0]
        let longSource = FormPlanSource(id: "source-1", originID: "profile-item-\(longCustom.id)", title: longCustom.label,
            originalText: longEntry.text, text: longEntry.text, recordID: nil)
        var longDraft = draft
        longDraft.sources = [longSource]
        let chunks = try FormPlanRules.makeBatches(longDraft).flatMap { $0.request.sources.map(\.text) }
        let header = "人物：\(longEntry.personLabel)\n"
        try check(chunks.count > 1 && chunks.allSatisfy { $0.hasPrefix(header) },
            "没有记录ID的长建档项切片也保留人物首行")
        let reconstructed = chunks.enumerated().map { index, text in
            index == 0 ? text : String(text.dropFirst(header.count))
        }.joined()
        try check(reconstructed == longEntry.text, "长自定义资料切片保留完整正文且只补人物首行")

        let localRecord = ProfileRecord(id: identity.id, subjectID: subject.id, kind: .identity,
            businessKey: "fictional-identity", displayValue: privateID,
            components: ["fieldID": "identityNumber", "label": "身份证号", "value": privateID],
            sources: [source], confirmedComponentKeys: ["value"], updatedAt: .now)
        let localField = DynamicFormField(id: "local-id", label: "身份证号", kind: .singleLineText,
            options: [], constraints: .init(), anchors: [],
            meaning: .init(canonicalKey: "identityNumber", state: .userSpecified))
        let local = try await LocalRuleAnswerMatcher().match(fields: [localField], subjects: [subject], records: [localRecord])
        try check(local[localField.id]?.value == privateID, "禁止 AI 的身份证号仍能由本地匹配器填写")
        try check(local[localField.id]?.sourceRecordIDs == [identity.id], "本地填写仍保留资料来源")
        return count
    }
}
