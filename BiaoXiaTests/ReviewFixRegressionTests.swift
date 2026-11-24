import Foundation
import SwiftData
import Testing
@testable import BiaoXia

@MainActor
struct ReviewFixRegressionTests {
    @Test(arguments: [false, true])
    func deletingMaterialRebuildsBothRecordStores(keepOtherItems: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profileStore = PersonalProfileStore(rootURL: root.appending(path: "profile"))
        let libraryStore = ProfileLibraryStore(rootURL: root.appending(path: "library"))
        let flow = FlowStore(profileStore: profileStore, profileLibraryStore: libraryStore)
        let material = MaterialAsset(displayName: "虚构材料.pdf", kind: .pdf, pageCount: 1, relativePath: "materials/fictional.pdf")
        let otherID = UUID()
        let source = FieldSource(materialID: material.id, materialName: material.displayName, pageIndex: 0, excerpt: "虚构技能", confidence: 1)
        let otherSource = FieldSource(materialID: otherID, materialName: "另一份虚构材料.pdf", pageIndex: 0, excerpt: "保留技能", confidence: 1)
        let removed = ProfileItem(category: .skill, fieldID: "skill.removed", label: "技能", value: "应删除技能", confidence: 1, state: .confirmed, sources: [source])
        let shared = ProfileItem(category: .skill, fieldID: "skill.shared", label: "技能", value: "多来源技能", confidence: 1, state: .confirmed, sources: [source, otherSource])
        let manual = ProfileItem(category: .skill, fieldID: "skill.manual", label: "技能", value: "人工保留技能", confidence: 1, state: .confirmed, modifiedByUser: true, sources: [source])
        flow.profileLibrary.materials = [material]
        flow.profileLibrary.profileItems = keepOtherItems ? [removed, shared, manual] : [removed]
        await flow.saveConfirmedProfile()
        let retainedIDs = Set(flow.availableRecords.filter { $0.id != removed.id }.map(\.id))

        await flow.deleteProfileMaterial(material)

        #expect(flow.transientError == nil)
        #expect(flow.availableRecords.count == (keepOtherItems ? 2 : 0))
        #expect(!flow.formPlanSources.contains { $0.recordID == removed.id })
        let savedProfile = try await profileStore.load()
        let savedLibrary = try await libraryStore.load()
        #expect(savedProfile.records == flow.profile.records)
        // The library file stores ISO 8601 dates in whole seconds; compare at that precision.
        #expect(savedLibrary.records == (try libraryPrecision(flow.profileLibrary.records)))
        for records in [savedProfile.records ?? [], savedLibrary.records ?? []] {
            #expect(Set(records.map(\.id)) == retainedIDs)
            #expect(records.allSatisfy { $0.sources.allSatisfy { $0.materialID != material.id } })
            if keepOtherItems {
                #expect(records.first { $0.id == shared.id }?.sources.map(\.materialID) == [otherID])
                #expect(records.first { $0.id == manual.id }?.sources.isEmpty == true)
            }
        }
        let reopened = FlowStore(profileStore: profileStore, profileLibraryStore: libraryStore)
        await reopened.loadProfile()
        #expect(Set(reopened.availableRecords.map(\.id)) == retainedIDs)
    }

    @Test(arguments: [false, true])
    func exportLocksTaskSwitchingAndReleasesLockOnCompletion(fail: Bool) async throws {
        let fixture = try makeExportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let work = Task { await fixture.flow.export(in: fixture.context) }
        await fixture.writer.waitUntilStarted()
        #expect(fixture.flow.isWorking)
        fixture.flow.closeTask()
        await fixture.flow.open(fixture.otherRecord, in: fixture.context)
        fixture.flow.profile = .testFixture
        await fixture.flow.createTask(in: fixture.context)
        #expect(fixture.flow.snapshot?.id == fixture.task.id)
        #expect(fixture.flow.activeRecord?.id == fixture.task.id)
        await fixture.writer.finish(fail: fail)
        await work.value
        #expect(!fixture.flow.isWorking)
        #expect(fixture.flow.snapshot?.status == (fail ? .failed : .completed))
        #expect(fixture.otherRecord.title == "任务 B")
        #expect(fixture.otherRecord.exportRelativePath == nil)
        fixture.flow.closeTask()
        #expect(fixture.flow.snapshot == nil)
    }

    @Test(arguments: [false, true])
    func lateExportResultCannotChangeReplacementTask(fail: Bool) async throws {
        let fixture = try makeExportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let work = Task { await fixture.flow.export(in: fixture.context) }
        await fixture.writer.waitUntilStarted()
        // Simulate state replacement independently of the guarded navigation entry points.
        var replacement = FillTaskSnapshot.empty()
        replacement.title = "任务 B"
        fixture.flow.snapshot = replacement
        fixture.flow.activeRecord = fixture.otherRecord
        await fixture.writer.finish(fail: fail)
        await work.value
        #expect(fixture.flow.snapshot?.id == replacement.id)
        #expect(fixture.flow.snapshot?.title == replacement.title)
        #expect(fixture.flow.snapshot?.status == replacement.status)
        #expect(fixture.flow.snapshot?.exportRelativePath == nil)
        #expect(fixture.flow.snapshot?.lastError == nil)
        #expect(fixture.otherRecord.title == "任务 B")
        #expect(fixture.otherRecord.exportRelativePath == nil)
        #expect(fixture.flow.transientError == nil)
        #expect(!fixture.flow.isWorking)
    }

    private func makeExportFixture() throws -> (root: URL, flow: FlowStore, context: ModelContext, task: FillTaskSnapshot, otherRecord: FillTaskRecord, writer: PausedReviewWriter) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let container = try ModelContainer(for: FillTaskRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let writer = PausedReviewWriter()
        let flow = FlowStore(fileStore: TaskFileStore(rootURL: root), formWriter: writer)
        var task = FillTaskSnapshot.empty()
        task.title = "任务 A"
        task.status = .reviewing
        task.form = FormAsset(displayName: "虚构表.docx", pageCount: 0, relativePath: "forms/fixture.docx", templateID: "general-docx-v1")
        task.generalForm = GeneralFormDocument(structureVersion: GeneralFormDocument.currentStructureVersion,
            fingerprint: DocumentFingerprint(algorithm: "fixture", value: "a", byteCount: 1), fields: [], format: .docx)
        let record = FillTaskRecord(snapshot: task)
        var other = FillTaskSnapshot.empty()
        other.title = "任务 B"
        let otherRecord = FillTaskRecord(snapshot: other)
        context.insert(record)
        context.insert(otherRecord)
        try context.save()
        flow.snapshot = task
        flow.activeRecord = record
        return (root, flow, context, task, otherRecord, writer)
    }

    /// Round-trips records with the library store's date strategy.
    private func libraryPrecision(_ records: [ProfileRecord]?) throws -> [ProfileRecord]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ProfileRecord]?.self, from: encoder.encode(records))
    }
}

private actor PausedReviewWriter: FormWriting {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, any Error>?

    func write(document: GeneralFormDocument, sourceURL: URL, destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finish(fail: Bool) {
        if fail { completion?.resume(throwing: ModuleFailure.retryable("虚构导出失败")) }
        else { completion?.resume() }
        completion = nil
    }
}
