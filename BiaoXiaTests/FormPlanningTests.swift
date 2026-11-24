import Foundation
import SwiftData
import Testing
@testable import BiaoXia

private actor PlanningFixture: FormPlanning {
    var calls = 0
    let failAt: Int?
    let delayed: Bool
    init(failAt: Int? = nil, delayed: Bool = false) { self.failAt = failAt; self.delayed = delayed }
    func plan(_ request: FormPlanRequest) async throws -> FormPlanResponse {
        calls += 1
        if delayed { try await Task.sleep(for: .milliseconds(200)) }
        if calls == failAt { throw ModuleFailure.retryable("虚构故障") }
        return FormPlanResponse(schemaVersion: 1, requestId: request.requestId, suggestions: request.fields.map {
            FormPlanSuggestion(fieldId: $0.id, status: .suggested, answer: "林晓", selectedOptionIDs: [],
                evidence: [.init(sourceId: request.sources[0].id, quote: "林晓")], reason: "", generated: $0.mode == .generated)
        })
    }
}

private actor MultiSourcePlanningFixture: FormPlanning {
    var calls = 0
    let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func plan(_ request: FormPlanRequest) async throws -> FormPlanResponse {
        calls += 1
        if calls == failAt { throw ModuleFailure.retryable("虚构合成故障") }
        let isMerge = request.sources.allSatisfy { $0.text.hasPrefix("我参与") }
        let answer = isMerge ? "我参与界面设计和数据整理。"
            : request.sources[0].text.contains("界面设计") ? "我参与界面设计。" : "我参与数据整理。"
        let evidence = isMerge ? request.sources.map { FormPlanEvidence(sourceId: $0.id, quote: $0.text) }
            : [FormPlanEvidence(sourceId: request.sources[0].id,
                quote: request.sources[0].text.contains("界面设计") ? "参与界面设计" : "参与数据整理")]
        return FormPlanResponse(schemaVersion: 1, requestId: request.requestId,
            suggestions: request.fields.map { .init(fieldId: $0.id, status: .suggested, answer: answer,
                selectedOptionIDs: [], evidence: evidence, reason: "", generated: true) })
    }
}

private actor ScriptedPlanningFixture: FormPlanning {
    var calls = 0
    let failures: [Int: FieldExplanationRequestError]
    var observe: (@MainActor @Sendable () -> Void)?
    init(_ failures: [Int: FieldExplanationRequestError]) { self.failures = failures }
    func setObserver(_ observe: @escaping @MainActor @Sendable () -> Void) { self.observe = observe }
    func plan(_ request: FormPlanRequest) async throws -> FormPlanResponse {
        calls += 1
        await observe?()
        if let failure = failures[calls] { throw failure }
        return .init(schemaVersion: 1, requestId: request.requestId, suggestions: request.fields.map {
            .init(fieldId: $0.id, status: .suggested, answer: "林晓", selectedOptionIDs: [],
                  evidence: [.init(sourceId: request.sources[0].id, quote: "林晓")], reason: "", generated: $0.mode == .generated)
        })
    }
}

@MainActor
private final class PlanningTimeline {
    var waits: [TimeInterval] = []
    var phases: [FormPlanProgress.Phase] = []
    var flow: FlowStore?
}

@MainActor
struct FormPlanningTests {
    private func fixture(_ planner: any FormPlanning, fields count: Int = 1, clock: FormPlanClock = .init()) throws -> (FlowStore, ModelContainer, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "t16-\(UUID())")
        let container = try ModelContainer(for: FillTaskRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let flow = FlowStore(fileStore: TaskFileStore(rootURL: root), formPlanner: planner, formPlanClock: clock)
        flow.snapshot = .empty(profile: .empty)
        flow.snapshot?.status = .reviewing
        let fields = (0..<count).map { DynamicFormField(id: "local-\($0)", label: "姓名", section: "章节\($0)", kind: .singleLineText,
            options: [], constraints: FormFieldConstraints(), anchors: [], meaning: FieldMeaning(state: .needsReview)) }
        flow.snapshot?.generalForm = GeneralFormDocument(structureVersion: 3, fingerprint: .init(algorithm: "test", value: "fixture", byteCount: 1), fields: fields)
        let item = ProfileItem(category: .identity, fieldID: "fullName", label: "姓名", value: "林晓",
            confidence: 1, state: .confirmed)
        useAllowedItems([item], in: flow)
        return (flow, container, root)
    }
    private func useAllowedItems(_ items: [ProfileItem], in flow: FlowStore) {
        flow.profile.items = items
        flow.profileLibrary.profileItems = items
        flow.profileLibrary.subjects = flow.availableSubjects
        flow.profileLibrary.records = flow.availableRecords
        let entries = flow.aiSharingEntries
        flow.profileLibrary.aiSharingGrants = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.fingerprint) })
    }
    private func prepare(_ flow: FlowStore, _ context: ModelContext) async {
        await flow.beginFormPlan(in: context)
    }
    @Test func preparationAndRestorationNeverSend() async throws {
        let planner = PlanningFixture()
        let (flow, container, root) = try fixture(planner); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        await flow.persist(in: container.mainContext)
        let restored = try JSONDecoder().decode(FillTaskSnapshot.self, from: JSONEncoder().encode(flow.snapshot!))
        flow.snapshot = restored
        #expect(await planner.calls == 0)
        #expect(flow.snapshot?.generalForm?.planDraft?.sources.count == 1)
        #expect(flow.snapshot?.generalForm?.planDraft?.batches.isEmpty == true)
    }
    @Test func allowedProfileItemsArePartitionedWithoutLosingText() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        let items = (0..<24).map { number in
            ProfileItem(category: .other, fieldID: "fixture-\(number)", label: "虚构资料\(number)",
                value: "第\(number)份资料", confidence: 1, state: .confirmed)
        }
        useAllowedItems((flow.profile.items ?? []) + items, in: flow)
        await flow.beginFormPlan(in: container.mainContext)
        flow.selectAllFormPlanSources()
        flow.editFormPlan { $0.sources[0].text = "本人姓名：林晓\n" + String(repeating: "汉🙂", count: 5000) }
        let draft = try #require(flow.snapshot?.generalForm?.planDraft)
        let batches = try FormPlanRules.makeBatches(draft)
        #expect(batches.count > 1)
        for batch in batches { try FormPlanRules.validate(batch.request) }
        for source in draft.sources {
            let chunks = batches.flatMap { batch in
                batch.request.sources.filter { batch.sourceMembers?[$0.id]?.contains(source.id) == true }.map(\.text)
            }
            if chunks.count == 1 {
                #expect(chunks[0].contains(source.text))
                continue
            }
            // Split profile items repeat their first line so every chunk keeps its person context.
            let header = String(source.text.prefix(while: { $0 != "\n" })) + "\n"
            #expect(chunks.dropFirst().allSatisfy { $0.hasPrefix(header) })
            let reconstructed = chunks.enumerated().map { index, text in
                index == 0 ? text : String(text.dropFirst(header.count))
            }.joined()
            #expect(reconstructed == source.text)
        }
    }
    @Test func longRecordRepeatsPersonContextWithoutDroppingOriginalText() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        let header = "人物：本人 林晓\n"
        let original = header + String(repeating: "经历🙂", count: 3500)
        flow.editFormPlan { draft in
            draft.sources = [.init(id: "source-1", originID: "record", title: "本人记录", originalText: original,
                text: original, recordID: UUID())]
        }
        let draft = try #require(flow.snapshot?.generalForm?.planDraft)
        let batches = try FormPlanRules.makeBatches(draft)
        let chunks = batches.flatMap { $0.request.sources.map(\.text) }
        #expect(chunks.count > 1)
        #expect(chunks.dropFirst().allSatisfy { $0.hasPrefix(header) })
        let reconstructed = chunks.enumerated().map { index, text in
            index == 0 ? text : String(text.dropFirst(header.count))
        }.joined()
        #expect(reconstructed == original)
    }
    @Test func conflictingSourceBatchesDoNotCreateAdoptableFact() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        flow.editFormPlan { draft in
            draft.sources = [
                .init(id: "source-1", originID: "one", title: "本人材料一", originalText: "", text: "本人姓名：林晓" + String(repeating: "甲", count: 5500)),
                .init(id: "source-2", originID: "two", title: "本人材料二", originalText: "", text: "本人姓名：林山" + String(repeating: "乙", count: 5500))
            ]
        }
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        draft.batches = try FormPlanRules.makeBatches(draft)
        for index in draft.batches.indices {
            let name = index == 0 ? "林晓" : "林山"
            let request = draft.batches[index].request
            let evidence = FormPlanEvidence(sourceId: request.sources[0].id, quote: "本人姓名：\(name)")
            draft.batches[index].response = .init(schemaVersion: 1, requestId: request.requestId,
                suggestions: [.init(fieldId: "field-1", status: .suggested, answer: name,
                    selectedOptionIDs: [], evidence: [evidence], reason: "", generated: false)])
        }
        #expect(FormPlanRules.finalSuggestion(draft, target: draft.targets[0])?.status == .conflict)
    }
    @Test func equalTextFromDifferentPeopleStillNeedsManualReview() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        flow.editFormPlan { draft in
            draft.sources = [
                .init(id: "source-1", originID: "self", title: "本人记录", originalText: "", text: "人物：本人 林晓\n姓名：林晓" + String(repeating: "甲", count: 5500), recordID: UUID()),
                .init(id: "source-2", originID: "father", title: "父亲记录", originalText: "", text: "人物：父亲 林晓\n姓名：林晓" + String(repeating: "乙", count: 5500), recordID: UUID())
            ]
        }
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        draft.batches = try FormPlanRules.makeBatches(draft)
        for index in draft.batches.indices {
            let request = draft.batches[index].request
            draft.batches[index].response = .init(schemaVersion: 1, requestId: request.requestId,
                suggestions: [.init(fieldId: "field-1", status: .suggested, answer: "林晓", selectedOptionIDs: [],
                    evidence: [.init(sourceId: request.sources[0].id, quote: "姓名：林晓")], reason: "", generated: false)])
        }
        #expect(FormPlanRules.finalSuggestion(draft, target: draft.targets[0])?.status == .manual)
    }
    @Test func generatedMergeKeepsOriginalEvidenceAndNeedsItsOwnRound() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        flow.snapshot?.generalForm?.fields[0].label = "自我评价"
        await flow.beginFormPlan(in: container.mainContext)
        flow.editFormPlan { draft in
            draft.sources = [
                .init(id: "source-1", originID: "one", title: "经历一", originalText: "", text: "参与界面设计" + String(repeating: "甲", count: 5500)),
                .init(id: "source-2", originID: "two", title: "经历二", originalText: "", text: "参与数据整理" + String(repeating: "乙", count: 5500))
            ]
        }
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        draft.batches = try FormPlanRules.makeBatches(draft)
        for index in draft.batches.indices {
            let request = draft.batches[index].request
            let quote = index == 0 ? "参与界面设计" : "参与数据整理"
            draft.batches[index].response = .init(schemaVersion: 1, requestId: request.requestId,
                suggestions: [.init(fieldId: "field-1", status: .suggested, answer: "我\(quote)。",
                    selectedOptionIDs: [], evidence: [.init(sourceId: request.sources[0].id, quote: quote)], reason: "", generated: true)])
        }
        #expect(FormPlanRules.finalSuggestion(draft, target: draft.targets[0]) == nil)
        let merge = try FormPlanRules.makeMergeBatches(draft)
        #expect(merge.count == 1)
        var completed = merge[0]
        let response = FormPlanResponse(schemaVersion: 1, requestId: completed.request.requestId,
            suggestions: [.init(fieldId: "field-1", status: .suggested, answer: "我参与界面设计和数据整理。",
                selectedOptionIDs: [], evidence: completed.request.sources.map { .init(sourceId: $0.id, quote: $0.text) }, reason: "", generated: true)])
        try FormPlanRules.validate(response, for: completed.request)
        completed.response = FormPlanRules.remapMergeEvidence(response, batch: completed)
        draft.mergeRounds = [[completed]]
        let final = try #require(FormPlanRules.finalSuggestion(draft, target: draft.targets[0]))
        #expect(final.evidence.count == 2)
        #expect(final.evidence.allSatisfy { FormPlanRules.source(for: $0, targetID: "field-1", draft: draft) != nil })
    }
    @Test func mergeFailureResumesOnlyFailedRoundAfterExplicitRetry() async throws {
        let planner = MultiSourcePlanningFixture(failAt: 3)
        let (flow, container, root) = try fixture(planner); defer { try? FileManager.default.removeItem(at: root) }
        flow.snapshot?.generalForm?.fields[0].label = "自我评价"
        let items = ["参与界面设计", "参与数据整理"].enumerated().map { index, label in
            ProfileItem(category: .project, fieldID: "experience-\(index)", label: "虚构经历\(index)",
                value: label + String(repeating: "汉", count: 5500), confidence: 1, state: .confirmed)
        }
        useAllowedItems(items, in: flow)
        await flow.beginFormPlan(in: container.mainContext)
        flow.selectAllFormPlanSources()
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.calls == 2)
        #expect(FormPlanRules.finalSuggestion(try #require(flow.snapshot?.generalForm?.planDraft),
            target: try #require(flow.snapshot?.generalForm?.planDraft?.targets[0])) == nil)
        flow.snapshot = try JSONDecoder().decode(FillTaskSnapshot.self, from: JSONEncoder().encode(flow.snapshot!))
        #expect(await planner.calls == 2)
        await flow.submitFormPlanMerge(in: container.mainContext)
        #expect(await planner.calls == 3)
        #expect(flow.snapshot?.generalForm?.planDraft?.mergeRounds?.last?.first?.error != nil)
        await flow.submitFormPlanMerge(in: container.mainContext)
        #expect(await planner.calls == 4)
        let draft = try #require(flow.snapshot?.generalForm?.planDraft)
        let final = try #require(FormPlanRules.finalSuggestion(draft, target: draft.targets[0]))
        #expect(final.answer == "我参与界面设计和数据整理。")
        #expect(final.evidence.count == 2)
        #expect(draft.batches.allSatisfy { $0.response != nil })
    }
    @Test func manyDraftsRequireMultipleExplicitMergeRounds() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        flow.snapshot?.generalForm?.fields[0].label = "自我评价"
        await flow.beginFormPlan(in: container.mainContext)
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        draft.sources = [.init(id: "source-1", originID: "fictional", title: "虚构经历", originalText: "", text: (0..<21).map { "参与项目\($0)" }.joined(separator: "\n"))]
        for number in 0..<21 {
            let request = FormPlanRequest(fields: [draft.targets[0].field],
                sources: [.init(id: "source-1", text: "参与项目\(number)")])
            draft.batches.append(FormPlanBatch(request: request,
                response: .init(schemaVersion: 1, requestId: request.requestId,
                    suggestions: [.init(fieldId: "field-1", status: .suggested, answer: "我参与项目\(number)。",
                        selectedOptionIDs: [], evidence: [.init(sourceId: "source-1", quote: "参与项目\(number)")],
                        reason: "", generated: true)]), sourceOrigins: ["source-1": "source-1"]))
        }
        var firstRound = try FormPlanRules.makeMergeBatches(draft)
        #expect(firstRound.count == 2)
        #expect(firstRound.flatMap { $0.request.sources }.count == 21)
        for index in firstRound.indices {
            let request = firstRound[index].request
            try FormPlanRules.validate(request)
            let response = FormPlanResponse(schemaVersion: 1, requestId: request.requestId,
                suggestions: [.init(fieldId: "field-1", status: .suggested, answer: "我参与多项虚构项目。",
                    selectedOptionIDs: [], evidence: request.sources.map { .init(sourceId: $0.id, quote: $0.text) },
                    reason: "", generated: true)])
            firstRound[index].response = FormPlanRules.remapMergeEvidence(response, batch: firstRound[index])
        }
        draft.mergeRounds = [firstRound]
        #expect(FormPlanRules.finalSuggestion(draft, target: draft.targets[0]) == nil)
        let secondRound = try FormPlanRules.makeMergeBatches(draft)
        #expect(secondRound.count == 1)
        #expect(secondRound[0].request.sources.count == 2)
    }
    @Test func preBatchDraftDecodesWithoutNewOptionalState() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        let draft = try #require(flow.snapshot?.generalForm?.planDraft)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        json.removeValue(forKey: "mergeRounds")
        let restored = try JSONDecoder().decode(FormPlanDraft.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.mergeRounds == nil)
        #expect(restored.sources == draft.sources)
        #expect(restored.targets == draft.targets)
    }
    @Test func selectAllSourcesKeepsEditedSelectionsAndDoesNotSend() async throws {
        let planner = PlanningFixture()
        let (flow, container, root) = try fixture(planner); defer { try? FileManager.default.removeItem(at: root) }
        let second = ProfileItem(category: .other, fieldID: "extra", label: "虚构补充资料", value: "虚构补充内容",
            confidence: 1, state: .confirmed)
        useAllowedItems((flow.profile.items ?? []) + [second], in: flow)
        await prepare(flow, container.mainContext)
        flow.editFormPlan { $0.sources[0].text = "已裁剪内容" }
        flow.selectAllFormPlanSources()
        flow.selectAllFormPlanSources()
        let selected = try #require(flow.snapshot?.generalForm?.planDraft?.sources)
        #expect(selected.count == 2)
        #expect(selected[0].text == "已裁剪内容")
        #expect(Set(selected.map(\.originID)).count == 2)
        #expect(await planner.calls == 0)
    }
    @Test func failedBatchResumesWithoutRepeatingSuccess() async throws {
        let planner = PlanningFixture(failAt: 2)
        let (flow, container, root) = try fixture(planner, fields: 9); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.calls == 2)
        #expect(flow.snapshot?.generalForm?.planDraft?.batches[0].response != nil)
        #expect(flow.snapshot?.generalForm?.planDraft?.batches[1].error != nil)
        let saved = try JSONEncoder().encode(flow.snapshot!)
        flow.snapshot = try JSONDecoder().decode(FillTaskSnapshot.self, from: saved)
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.calls == 3)
        #expect(flow.snapshot?.generalForm?.planDraft?.batches.allSatisfy { $0.response != nil } == true)
    }
    @Test func adoptionRetainsEvidenceAndDoesNotOverwriteManualAnswer() async throws {
        let planner = PlanningFixture()
        let (flow, container, root) = try fixture(planner); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext); await flow.submitFormPlan(in: container.mainContext)
        let document = flow.snapshot?.generalForm
        flow.snapshot?.generalForm?.fields[0].answer = PersonalAnswer(value: "手写姓名", selectedOptionIDs: [], sourceRecordIDs: [], confirmationState: .suggested, modifiedByUser: true)
        await flow.adoptFormPlan(["field-1"], in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.fields[0].answer?.value == "手写姓名")
        flow.snapshot?.generalForm = document
        await flow.adoptFormPlan(["field-1"], in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.fields[0].answer?.value == "林晓")
        #expect(flow.snapshot?.generalForm?.fields[0].answer?.planSources?.first?.quote == "林晓")
        await flow.beginFormPlan(in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.planDraft?.targets.isEmpty == true)
        #expect(flow.snapshot?.generalForm?.fields[0].answer?.planSources?.isEmpty == false)
    }
    @Test func deletedSourcePreventsSending() async throws {
        let planner = PlanningFixture()
        let (flow, container, root) = try fixture(planner); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        useAllowedItems([], in: flow)
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.calls == 0)
    }
    @Test func editedSourcePreviewRequiresPermissionProjectionToBePreparedAgain() async throws {
        let planner = PlanningFixture()
        let (flow, container, root) = try fixture(planner); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        flow.editFormPlan { $0.sources[0].text = "林晓" }
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.calls == 0)
        #expect(flow.transientError != nil)
    }
    @Test func generatedAnswerNeedsIndividualAdoption() async throws {
        let planner = PlanningFixture()
        let (flow, container, root) = try fixture(planner); defer { try? FileManager.default.removeItem(at: root) }
        flow.snapshot?.generalForm?.fields[0].label = "自我评价"
        await prepare(flow, container.mainContext); await flow.submitFormPlan(in: container.mainContext)
        await flow.adoptFormPlan(["field-1"], in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.fields[0].answer == nil)
        await flow.adoptFormPlan(["field-1"], editedAnswer: "我是林晓。", individually: true, in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.fields[0].answer?.value == "我是林晓。")
    }
    @Test func cancellationStopsFollowingBatches() async throws {
        let planner = PlanningFixture(delayed: true)
        let (flow, container, root) = try fixture(planner, fields: 9); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        let task = Task { await flow.submitFormPlan(in: container.mainContext) }
        while await planner.calls == 0 { await Task.yield() }
        task.cancel(); await task.value
        #expect(await planner.calls == 1)
        #expect(!flow.isWorking)
        #expect(flow.snapshot?.generalForm?.planDraft?.batches.allSatisfy { $0.response == nil } == true)
    }
    @Test func sourceChangedDuringRequestRejectsResponse() async throws {
        let planner = PlanningFixture(delayed: true)
        let (flow, container, root) = try fixture(planner); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        let task = Task { await flow.submitFormPlan(in: container.mainContext) }
        while await planner.calls == 0 { await Task.yield() }
        useAllowedItems([], in: flow)
        await task.value
        #expect(flow.snapshot?.generalForm?.planDraft?.batches[0].response == nil)
    }
    @Test func packedRecordsResolveUniqueEvidenceAndPreservePrivacy() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        draft.sources = (0..<35).map { index in
            let text = "人物：本人 虚构林晓\n第\(index)项经历：项目编号\(1000 + index)。" + String(repeating: "虚构项目经验。", count: 18)
            return .init(id: "local-\(index)", originID: "origin-\(index)", title: "不得出站的文件名\(index)",
                         originalText: text, text: text, recordID: UUID())
        }
        draft.batches = try FormPlanRules.makeBatches(draft)
        #expect(draft.batches.count == 1)
        #expect(draft.batches[0].request.sources.allSatisfy { $0.text.utf16.count <= 6000 })
        let wire = try #require(draft.batches[0].request.sources.first { $0.text.contains("项目编号1017") })
        let evidence = FormPlanEvidence(sourceId: wire.id, quote: "项目编号1017")
        #expect(FormPlanRules.source(for: evidence, targetID: "field-1", draft: draft)?.recordID == draft.sources[17].recordID)
        let body = String(decoding: try JSONEncoder().encode(draft.batches[0].request), as: UTF8.self)
        #expect(!body.contains("不得出站") && !body.contains("origin-") && !body.contains("recordID"))
        #expect(wire.text.contains("[资料 2]"))
        // Twenty-four short records fit one request and retain every selected text.
        draft.sources = Array(draft.sources.prefix(24)).map { source in
            var copy = source; copy.text = String(copy.text.prefix(38)); return copy
        }
        let small = try FormPlanRules.makeBatches(draft)
        #expect(small.count == 1 && small[0].request.sources.count == 1)
        #expect(draft.sources.allSatisfy { small[0].request.sources[0].text.contains($0.text) })
    }

    @Test func crossSourceQuoteOnlyDowngradesItsField() async throws {
        let (flow, container, root) = try fixture(PlanningFixture(), fields: 2); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        draft.sources = ["甲资料林晓", "乙资料林山"].enumerated().map {
            .init(id: "local-\($0.offset)", originID: "origin-\($0.offset)", title: "虚构", originalText: $0.element, text: $0.element)
        }
        draft.batches = try FormPlanRules.makeBatches(draft)
        let batch = draft.batches[0]
        let response = FormPlanResponse(schemaVersion: 1, requestId: batch.request.requestId, suggestions: [
            .init(fieldId: "field-1", status: .suggested, answer: "林晓", selectedOptionIDs: [],
                  evidence: [.init(sourceId: "source-1", quote: batch.request.sources[0].text)], reason: "", generated: false),
            .init(fieldId: "field-2", status: .suggested, answer: "林山", selectedOptionIDs: [],
                  evidence: [.init(sourceId: "source-1", quote: "乙资料林山")], reason: "", generated: false)
        ])
        let checked = FormPlanRules.validateOriginalEvidence(response, batch: batch, draft: draft)
        try FormPlanRules.validate(checked, for: batch.request)
        #expect(checked.suggestions.map(\.status) == [.missing, .suggested])
        var nonexistent = response
        nonexistent.suggestions[0].evidence[0].quote = "未选资料中的内容"
        #expect(FormPlanRules.validateOriginalEvidence(nonexistent, batch: batch, draft: draft).suggestions[0].status == .missing)
    }

    @Test func fifteenFieldsAndThirtyFiveRecordsUseAtMostThreeBatches() async throws {
        let (flow, container, root) = try fixture(PlanningFixture(), fields: 15); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        for index in draft.targets.indices {
            if index < 7 {
                draft.targets[index].field.mode = .generated
                draft.targets[index].field.kind = .multilineText
            } else if index >= 11 && index < 14 {
                draft.targets[index].field.kind = .multipleChoice
                draft.targets[index].field.options = [.init(id: "a", label: "虚构选项甲"), .init(id: "b", label: "虚构选项乙")]
            } else if index == 14 { draft.targets[index].field.kind = .date }
        }
        draft.sources = (0..<35).map { index in
            let text = "人物：本人 虚构林晓\n资料\(index)" + String(repeating: "虚构", count: 78)
            return .init(id: "record-\(index)", originID: "local-\(index)", title: "虚构", originalText: text, text: text, recordID: UUID())
        }
        let batches = try FormPlanRules.makeBatches(draft)
        #expect(batches.count <= 3)
        #expect(Set(batches.flatMap { $0.request.fields.map(\.id) }).count == 15)
        for batch in batches {
            try FormPlanRules.validate(batch.request)
            #expect(batch.request.fields.count <= 8)
            #expect(batch.request.fields.filter { $0.mode == .generated }.count <= 3)
            #expect(FormPlanRules.estimatedOutputTokens(batch.request.fields) <= 4096)
        }
    }

    @Test func rateLimitWaitsUntilNextMinuteAndProgressChanges() async throws {
        let limit = DemoAccessService.responseError(status: 429, data: Data(#"{"error":"DEMO_RATE_LIMIT"}"#.utf8))
        let busy = DemoAccessService.responseError(status: 429, data: Data(#"{"error":"DEMO_BUSY"}"#.utf8))
        let planner = ScriptedPlanningFixture([1: limit, 2: busy])
        let timeline = PlanningTimeline()
        let clock = FormPlanClock(now: { Date(timeIntervalSince1970: 125) }, sleep: { seconds in
            await MainActor.run {
                timeline.waits.append(seconds)
                if let phase = timeline.flow?.formPlanProgress?.phase { timeline.phases.append(phase) }
            }
        })
        let (flow, container, root) = try fixture(planner, clock: clock); defer { try? FileManager.default.removeItem(at: root) }
        timeline.flow = flow
        await prepare(flow, container.mainContext)
        #expect(flow.formPlanProgress?.phase == .reviewing)
        await planner.setObserver { if let phase = flow.formPlanProgress?.phase { timeline.phases.append(phase) } }
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.calls == 3)
        #expect(timeline.waits == [57, 57])
        #expect(timeline.phases == [.generating, .queued, .generating, .queued, .generating])
        #expect(flow.formPlanProgress?.phase == .results)
        #expect(flow.formPlanProgress?.queueDeadline == nil)
        #expect(flow.snapshot?.generalForm?.planDraft?.batches[0].response != nil)
    }

    @Test func failuresContinueUntilTwoConsecutiveFailures() async throws {
        let planner = ScriptedPlanningFixture([1: .retryable("模型失败"), 3: .retryable("模型失败"), 4: .retryable("模型失败")])
        let (flow, container, root) = try fixture(planner, fields: 40); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        await flow.submitFormPlan(in: container.mainContext)
        let batches = try #require(flow.snapshot?.generalForm?.planDraft?.batches)
        #expect(await planner.calls == 4)
        #expect(batches[1].response != nil)
        #expect(batches[0].error != nil && batches[2].error != nil && batches[3].error != nil)
        #expect(batches[4].error == nil && batches[4].response == nil)
    }

    @Test func blockedStopsImmediatelyAndQuotaWaitHasThreeAttemptLimit() async throws {
        let planner = ScriptedPlanningFixture([1: .blocked("演示已到期")])
        let (flow, container, root) = try fixture(planner, fields: 17); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.calls == 1)
        let timeline = PlanningTimeline()
        let limit = DemoAccessService.responseError(status: 429, data: Data(#"{"error":"DEMO_BUSY"}"#.utf8))
        let queued = ScriptedPlanningFixture([1: limit, 2: limit, 3: limit, 4: limit])
        let clock = FormPlanClock(now: { Date(timeIntervalSince1970: 180) }, sleep: { seconds in
            await MainActor.run { timeline.waits.append(seconds) }
        })
        let (limited, storage, otherRoot) = try fixture(queued, clock: clock); defer { try? FileManager.default.removeItem(at: otherRoot) }
        await prepare(limited, storage.mainContext)
        await limited.submitFormPlan(in: storage.mainContext)
        #expect(await queued.calls == 4)
        #expect(timeline.waits == [62, 62, 62])
        #expect(limited.snapshot?.generalForm?.planDraft?.batches[0].error != nil)
    }

    @Test func cancellationDuringQuotaQueueStopsFollowingBatches() async throws {
        let limit = DemoAccessService.responseError(status: 429, data: Data(#"{"error":"DEMO_BUSY"}"#.utf8))
        let planner = ScriptedPlanningFixture([1: limit])
        let (flow, container, root) = try fixture(planner, fields: 17); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        let task = Task { await flow.submitFormPlan(in: container.mainContext) }
        while flow.formPlanProgress?.phase != .queued { await Task.yield() }
        task.cancel(); await task.value
        #expect(await planner.calls == 1)
        #expect(!flow.isWorking && flow.formPlanProgress?.phase == .results)
    }

    @Test func adoptionOfPackedRecordRetainsRecordIDAndLocalSource() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        let person = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "虚构本人")
        let items = (0..<35).map { index in
            ProfileItem(category: .campus, fieldID: "fixture-\(index)", label: "虚构校园经历\(index)",
                value: index == 17 ? "林晓" : "虚构记录\(index)", confidence: 1, state: .confirmed)
        }
        let records = items.map { item in
            let components = ["fieldID": item.fieldID, "label": item.label, "value": item.value]
            return ProfileRecord(id: UUID(), subjectID: person.id, kind: .experience,
                businessKey: ProfileBusinessKey.make(kind: .experience, subjectID: person.id, components: components),
                displayValue: item.value, components: components, sources: [],
                confirmedComponentKeys: ["value"], updatedAt: .now)
        }
        flow.profile.subjects = [person]
        flow.profile.records = records
        flow.profileLibrary.materials = []
        flow.profileLibrary.ocrBlocks = []
        useAllowedItems(items, in: flow)
        await flow.beginFormPlan(in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.planDraft?.sources.count == 35)
        flow.selectAllFormPlanSources()
        await flow.submitFormPlan(in: container.mainContext)
        await flow.adoptFormPlan(["field-1"], in: container.mainContext)
        let answer = try #require(flow.snapshot?.generalForm?.fields[0].answer)
        #expect(answer.sourceRecordIDs == [records[17].id])
        #expect(answer.planSources?.first?.originID == flow.formPlanSources.first { $0.recordID == records[17].id }?.originID)
        #expect(answer.planSources?.first?.quote == "林晓")
    }

    @Test func legacyBatchWithoutMembersStillDecodesAndResolvesEvidence() async throws {
        let (flow, container, root) = try fixture(PlanningFixture()); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        draft.batches = try FormPlanRules.makeBatches(draft)
        draft.batches[0].sourceMembers = nil
        draft.batches[0].sourceOrigins = ["source-1": draft.sources[0].id]
        let decoded = try JSONDecoder().decode(FormPlanDraft.self, from: JSONEncoder().encode(draft))
        #expect(decoded.batches[0].sourceMembers == nil)
        #expect(FormPlanRules.source(for: .init(sourceId: "source-1", quote: "林晓"), targetID: "field-1", draft: decoded)?.originID == draft.sources[0].originID)
    }

    @Test func oversizedGeneratedFieldStaysAloneWithoutBlockingOtherFields() async throws {
        let (flow, container, root) = try fixture(PlanningFixture(), fields: 10)
        defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        let original = try #require(flow.snapshot?.generalForm?.planDraft)
        // Check both appending ordinary fields after the oversized field and fitting it after a full group.
        for index in [0, 4, 9] {
            var draft = original
            draft.targets[index].field.mode = .generated
            draft.targets[index].field.kind = .multilineText
            draft.targets[index].field.maximumCharacters = 3000
            let oversized = draft.targets[index].field
            #expect(FormPlanRules.estimatedOutputTokens([oversized]) > 4096)
            let batches = try FormPlanRules.makeBatches(draft)
            let isolated = batches.filter { $0.request.fields.contains { $0.id == oversized.id } }
            #expect(isolated.count == 1)
            #expect(isolated.first?.request.fields == [oversized])
            let ordinary = batches.filter { !$0.request.fields.contains { $0.id == oversized.id } }
            #expect(ordinary.map { $0.request.fields.count } == [8, 1])
            #expect(ordinary.flatMap { $0.request.fields.map(\.id) }
                == draft.targets.filter { $0.id != oversized.id }.map(\.id))
            for batch in ordinary {
                #expect(batch.request.fields.filter { $0.mode == .generated }.count <= 3)
                #expect(FormPlanRules.estimatedOutputTokens(batch.request.fields) <= 4096)
            }
            for batch in batches { try FormPlanRules.validate(batch.request) }
        }
    }

    @Test func outputEstimateHonorsExplicitMaximumAndAmbiguousQuotesAreMissing() async throws {
        let (flow, container, root) = try fixture(PlanningFixture(), fields: 4); defer { try? FileManager.default.removeItem(at: root) }
        await prepare(flow, container.mainContext)
        var draft = try #require(flow.snapshot?.generalForm?.planDraft)
        for index in draft.targets.indices {
            draft.targets[index].field.mode = .generated
            draft.targets[index].field.maximumCharacters = 1600
        }
        draft.batches = try FormPlanRules.makeBatches(draft)
        #expect(draft.batches.count == 4)
        #expect(draft.batches.allSatisfy { FormPlanRules.estimatedOutputTokens($0.request.fields) <= 4096 })
        draft.sources.append(.init(id: "second", originID: "second", title: "虚构同名", originalText: "父亲林晓", text: "父亲林晓"))
        draft.batches = try FormPlanRules.makeBatches(draft)
        let batch = draft.batches[0]
        let response = FormPlanResponse(schemaVersion: 1, requestId: batch.request.requestId, suggestions: [
            .init(fieldId: "field-1", status: .suggested, answer: "林晓", selectedOptionIDs: [],
                  evidence: [.init(sourceId: "source-1", quote: "林晓")], reason: "", generated: true)
        ])
        #expect(FormPlanRules.validateOriginalEvidence(response, batch: batch, draft: draft).suggestions[0].status == .missing)
    }

    @Test func standaloneRulesAndRealWordWriter() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory.appending(path: "t16-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(try await FormPlanningChecks.run(repository: repository, output: output) >= 20)
    }
}
