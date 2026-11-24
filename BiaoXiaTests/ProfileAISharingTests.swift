import Foundation
import SwiftData
import Testing
@testable import BiaoXia

private actor SharingPlanningFixture: FormPlanning {
    var requests: [FormPlanRequest] = []

    func plan(_ request: FormPlanRequest) async throws -> FormPlanResponse {
        requests.append(request)
        return FormPlanResponse(schemaVersion: 1, requestId: request.requestId,
            suggestions: request.fields.map {
                .init(fieldId: $0.id, status: .missing, answer: nil, selectedOptionIDs: [], evidence: [],
                    reason: "虚构测试不生成答案", generated: false)
            })
    }
}

private actor FailableSharingLibraryStore: ProfileLibraryStoring {
    private let base: ProfileLibraryStore
    private var shouldFail = false

    init(root: URL) { base = ProfileLibraryStore(rootURL: root) }
    func setSaveFailure(_ value: Bool) { shouldFail = value }
    func load() async throws -> ProfileLibrarySnapshot { try await base.load() }
    func save(_ snapshot: ProfileLibrarySnapshot) async throws {
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try await base.save(snapshot)
    }
    func importMaterial(from url: URL) async throws -> MaterialAsset { try await base.importMaterial(from: url) }
    func renameMaterial(id: UUID, to displayName: String) async throws { try await base.renameMaterial(id: id, to: displayName) }
    func deleteMaterial(_ material: MaterialAsset) async throws { try await base.deleteMaterial(material) }
    func absoluteURL(for path: String) async throws -> URL { try await base.absoluteURL(for: path) }
}

@MainActor
struct ProfileAISharingTests {
    private let privateID = "110101200001010099"

    private func fixture(libraryStore: (any ProfileLibraryStoring)? = nil) throws -> (FlowStore, ModelContainer, SharingPlanningFixture, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "sharing-\(UUID())")
        let planner = SharingPlanningFixture()
        let flow = FlowStore(
            fileStore: TaskFileStore(rootURL: root.appending(path: "tasks")),
            profileLibraryStore: libraryStore ?? ProfileLibraryStore(rootURL: root.appending(path: "library")),
            formPlanner: planner)
        let container = try ModelContainer(for: FillTaskRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let material = MaterialAsset(displayName: "未授权原始材料.pdf", kind: .pdf, pageCount: 1, relativePath: "fictional.pdf")
        let evidence = FieldSource(materialID: material.id, materialName: material.displayName, pageIndex: 0,
            excerpt: "姓名林晓，身份证号\(privateID)", confidence: 1)
        let items = [
            ProfileItem(category: .identity, fieldID: "fullName", label: "姓名", value: "林晓",
                components: ["private": privateID], confidence: 1, state: .confirmed, sources: [evidence]),
            ProfileItem(category: .education, fieldID: "studentID", label: "学号", value: "TEST20260042",
                confidence: 1, state: .confirmed),
            ProfileItem(category: .identity, fieldID: "identityNumber", label: "身份证号", value: privateID,
                confidence: 1, state: .confirmed, sensitivity: .highlySensitive)
        ]
        flow.profile.items = items
        flow.profileLibrary.profileItems = items
        flow.profileLibrary.materials = [material]
        flow.profileLibrary.ocrBlocks = [.init(text: evidence.excerpt, pageIndex: 0,
            boundingBox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 1, materialID: material.id)]
        let entries = ProfileAISharing.entries(items: items, subjects: [], records: [])
        flow.profileLibrary.aiSharingGrants = Dictionary(uniqueKeysWithValues:
            entries.filter { $0.id != items[2].id }.map { ($0.id, $0.fingerprint) })
        flow.snapshot = .empty(profile: flow.profile)
        flow.snapshot?.status = .reviewing
        flow.snapshot?.generalForm = GeneralFormDocument(structureVersion: 1,
            fingerprint: .init(algorithm: "fixture", value: "sharing", byteCount: 1),
            fields: ["姓名", "学号"].enumerated().map { index, label in
                DynamicFormField(id: "local-\(index)", label: label, kind: .singleLineText, options: [],
                    constraints: .init(), anchors: [], meaning: .init(state: .needsReview))
            })
        return (flow, container, planner, root)
    }

    @Test func singleFieldAndWholeFormShareTheSamePermittedSources() async throws {
        let (flow, container, planner, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        let whole = try #require(flow.snapshot?.generalForm?.planDraft)
        #expect(whole.sources.count == 2 && whole.targets.count == 2)
        #expect(await planner.requests.isEmpty)
        await flow.submitFormPlan(in: container.mainContext)
        await flow.beginFormPlan(fieldID: "local-0", in: container.mainContext)
        let single = try #require(flow.snapshot?.generalForm?.planDraft)
        #expect(single.scopeFieldID == "local-0")
        #expect(single.sources == whole.sources)
        #expect(single.targets.map(\.original.id) == ["local-0"])
        await flow.submitFormPlan(in: container.mainContext)
        let requests = await planner.requests
        #expect(requests.count == 2)
        #expect(requests[0].sources == requests[1].sources)
        let body = String(decoding: try JSONEncoder().encode(requests), as: UTF8.self)
        #expect(body.contains("林晓") && body.contains("TEST20260042"))
        #expect(!body.contains(privateID) && !body.contains("未授权原始材料") && !body.contains("private"))
    }

    @Test func permissionRevocationInvalidatesAnAlreadyPreparedDraft() async throws {
        let (flow, container, planner, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        let draft = try #require(flow.snapshot?.generalForm?.planDraft)
        flow.snapshot?.generalForm?.planDraft?.batches = try FormPlanRules.makeBatches(draft)
        flow.profileLibrary.aiSharingGrants = [:]
        #expect(!flow.formPlanIsCurrent)
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.requests.isEmpty)
        #expect(flow.transientError != nil)
        #expect(flow.profile.informationItems.contains { $0.value == privateID })
    }

    @Test func changedProfileValueRequiresNewPermissionBeforeSending() async throws {
        let (flow, container, planner, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        flow.profile.items?[0].value = "更新后的姓名"
        flow.profileLibrary.profileItems?[0].value = "更新后的姓名"
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.requests.isEmpty)
        #expect(!flow.formPlanSources.contains { $0.text.contains("更新后的姓名") })
    }

    @Test func restoredLegacyRawMaterialDraftCannotSend() async throws {
        let (flow, container, planner, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        let material = try #require(flow.profileLibrary.materials.first)
        let text = try #require(flow.profileLibrary.ocrBlocks.first?.text)
        flow.snapshot?.generalForm?.planDraft?.sources = [
            .init(id: "source-1", originID: "library-\(material.id)", title: material.displayName,
                originalText: text, text: text)
        ]
        flow.snapshot = try JSONDecoder().decode(FillTaskSnapshot.self, from: JSONEncoder().encode(flow.snapshot!))
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.requests.isEmpty)
        #expect(flow.transientError != nil)
    }

    @Test func alteredSavedBatchCannotBypassCurrentPermissionProjection() async throws {
        let (flow, container, planner, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        let draft = try #require(flow.snapshot?.generalForm?.planDraft)
        flow.snapshot?.generalForm?.planDraft?.batches = try FormPlanRules.makeBatches(draft)
        flow.snapshot?.generalForm?.planDraft?.batches[0].request.sources[0].text += "\n身份证号：\(privateID)"
        flow.snapshot = try JSONDecoder().decode(FillTaskSnapshot.self, from: JSONEncoder().encode(flow.snapshot!))
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.requests.isEmpty)
        #expect(flow.transientError != nil)
    }

    @Test func appendedPreviewTextCannotIntroduceAnUnauthorizedValue() async throws {
        let (flow, container, planner, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await flow.beginFormPlan(in: container.mainContext)
        flow.editFormPlan { $0.sources[0].text += "\n身份证号：\(privateID)" }
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.requests.isEmpty)
        #expect(flow.transientError != nil)
    }

    @Test func originalMaterialsAloneDoNotGrantAIVisibility() async throws {
        let (flow, container, planner, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        flow.profileLibrary.aiSharingGrants = [:]
        await flow.beginFormPlan(in: container.mainContext)
        #expect(flow.formPlanSources.isEmpty)
        #expect(flow.snapshot?.generalForm?.planDraft?.sources.isEmpty == true)
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.requests.isEmpty)
        #expect(!flow.profileLibrary.materials.isEmpty && !flow.profileLibrary.ocrBlocks.isEmpty)
    }

    @Test func libraryMigrationDefaultsToNoPermissionsAndPersistsNewGrants() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sharing-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileLibraryStore(rootURL: root)
        var legacy = ProfileLibrarySnapshot.empty()
        legacy.schemaVersion = 3
        legacy.aiSharingGrants = nil
        try await store.save(legacy)
        var loaded = try await store.load()
        #expect(loaded.schemaVersion == ProfileLibrarySnapshot.currentSchemaVersion)
        #expect(loaded.aiSharingGrants?.isEmpty == true)
        let grants = [UUID(): "fictional-fingerprint"]
        loaded.aiSharingGrants = grants
        try await store.save(loaded)
        #expect(try await store.load().aiSharingGrants == grants)
    }

    @Test func firstGrantInLegacyLibrarySurvivesSubjectNormalization() async throws {
        let (flow, _, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        flow.profileLibrary.aiSharingGrants = [:]
        flow.profileLibrary.subjects = []
        flow.profileLibrary.records = []
        let before = try #require(flow.aiSharingEntries.first { $0.label == "姓名" })
        await flow.setAISharingAllowed(before, allowed: true)
        let after = try #require(flow.aiSharingEntries.first { $0.id == before.id })
        #expect(after.text == before.text)
        #expect(after.fingerprint != before.fingerprint)
        #expect(flow.isAISharingAllowed(after))
        #expect(flow.formPlanSources.count == 1)
        #expect(!flow.aiSharingSaveFailed && !flow.isUpdatingAISharing)
        let saved = try await ProfileLibraryStore(rootURL: root.appending(path: "library")).load()
        #expect(saved.aiSharingGrants?[after.id] == after.fingerprint)
    }

    @Test func failedRevocationPausesSendingAndRetryKeepsTheRevocation() async throws {
        let libraryRoot = FileManager.default.temporaryDirectory.appending(path: "sharing-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        let library = FailableSharingLibraryStore(root: libraryRoot)
        let (flow, container, planner, root) = try fixture(libraryStore: library)
        defer { try? FileManager.default.removeItem(at: root) }
        flow.profileLibrary.aiSharingGrants = [:]
        let oldName = try #require(flow.aiSharingEntries.first { $0.label == "姓名" })
        await flow.setAISharingAllowed(oldName, allowed: true)
        let student = try #require(flow.aiSharingEntries.first { $0.label == "学号" })
        await flow.setAISharingAllowed(student, allowed: true)
        await flow.beginFormPlan(in: container.mainContext)

        await library.setSaveFailure(true)
        let name = try #require(flow.aiSharingEntries.first { $0.label == "姓名" })
        await flow.setAISharingAllowed(name, allowed: false)
        #expect(flow.aiSharingSaveFailed)
        #expect(!flow.isAISharingAllowed(name))
        #expect(flow.isAISharingAllowed(student))
        await flow.submitFormPlan(in: container.mainContext)
        #expect(await planner.requests.isEmpty)

        await library.setSaveFailure(false)
        await flow.retryAISharingSave()
        #expect(!flow.aiSharingSaveFailed && flow.transientError == nil)
        #expect(!flow.isAISharingAllowed(name) && flow.isAISharingAllowed(student))
        let persisted = try await library.load()
        #expect(persisted.aiSharingGrants?[name.id] == nil)
        #expect(persisted.aiSharingGrants?[student.id] == student.fingerprint)
        await flow.beginFormPlan(in: container.mainContext)
        await flow.submitFormPlan(in: container.mainContext)
        let requests = await planner.requests
        #expect(requests.count == 1)
        #expect(requests[0].sources.allSatisfy { !$0.text.contains(name.value) })
    }

    @Test func failedGrantDoesNotBecomeAllowedWhenSavingIsRetried() async throws {
        let libraryRoot = FileManager.default.temporaryDirectory.appending(path: "sharing-grant-\(UUID())")
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        let library = FailableSharingLibraryStore(root: libraryRoot)
        let (flow, _, _, root) = try fixture(libraryStore: library)
        defer { try? FileManager.default.removeItem(at: root) }
        flow.profileLibrary.aiSharingGrants = [:]
        await library.setSaveFailure(true)
        let entry = try #require(flow.aiSharingEntries.first { $0.label == "姓名" })
        await flow.setAISharingAllowed(entry, allowed: true)
        #expect(flow.aiSharingSaveFailed && flow.formPlanSources.isEmpty)
        await library.setSaveFailure(false)
        await flow.retryAISharingSave()
        #expect(!flow.aiSharingSaveFailed && flow.formPlanSources.isEmpty)
        #expect(try await library.load().aiSharingGrants?.isEmpty == true)
    }

    @Test func productionRulesRunWithoutSimulatorDependencies() async throws {
        #expect(try await ProfileAISharingChecks.run() >= 25)
    }
}
