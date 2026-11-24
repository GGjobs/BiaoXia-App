import Foundation
import SwiftData
import XCTest
@testable import BiaoXia

final class TaskFileStoreDeletionTests: XCTestCase {
    func testDeleteTaskRemovesEntireDirectoryAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TaskFileStore(rootURL: root)
        let taskID = UUID()
        try await store.createTaskDirectory(taskID: taskID)
        let materialURL = try await store.absoluteURL(
            for: "materials/example.pdf",
            taskID: taskID
        )
        try Data("test".utf8).write(to: materialURL)

        try await store.deleteTask(taskID: taskID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: materialURL.path))

        try await store.deleteTask(taskID: taskID)
    }
}

@MainActor
final class FlowStoreDeletionTests: XCTestCase {
    func testUserEditsOverrideAIStatusInProfileAndForm() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FillTaskRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let flow = FlowStore(fileStore: RecordingDeletionFileStore())

        let profileIndex = try XCTUnwrap(
            flow.profileLibrary.resolvedFields.firstIndex { $0.key == .major }
        )
        flow.profileLibrary.resolvedFields[profileIndex].resolvedByAI = true
        flow.profileLibrary.resolvedFields[profileIndex].confidence = 0.72
        flow.updateProfileField(.major, value: "人工修正专业")

        let profileField = try XCTUnwrap(
            flow.profileLibrary.resolvedFields.first { $0.key == .major }
        )
        XCTAssertTrue(profileField.modifiedByUser)
        XCTAssertFalse(profileField.resolvedByAI)
        XCTAssertEqual(profileField.confidence, 1)

        var task = FillTaskSnapshot.empty()
        let taskIndex = try XCTUnwrap(task.resolvedFields.firstIndex { $0.key == .major })
        task.resolvedFields[taskIndex].resolvedByAI = true
        task.resolvedFields[taskIndex].confidence = 0.74
        flow.snapshot = task
        flow.updateField(.major, value: "人工修正专业", in: context)

        let taskField = try XCTUnwrap(
            flow.snapshot?.resolvedFields.first { $0.key == .major }
        )
        XCTAssertTrue(taskField.modifiedByUser)
        XCTAssertFalse(taskField.resolvedByAI)
        XCTAssertEqual(taskField.confidence, 1)
    }

    func testFileDeletionFailureKeepsTaskRecord() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FillTaskRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let record = FillTaskRecord(snapshot: .empty())
        context.insert(record)
        try context.save()

        let flow = FlowStore(fileStore: FailingDeletionFileStore())
        await flow.deleteTask(record, in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<FillTaskRecord>()).count, 1)
        XCTAssertNotNil(flow.transientError)
        XCTAssertFalse(flow.isWorking)
    }

    func testClearTasksDeletesAllFilesAndRecords() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FillTaskRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let records = [
            FillTaskRecord(snapshot: .empty()),
            FillTaskRecord(snapshot: .empty())
        ]
        records.forEach(context.insert)
        try context.save()

        let fileStore = RecordingDeletionFileStore()
        let flow = FlowStore(fileStore: fileStore)
        await flow.clearTasks(records, in: context)

        let deletedTaskIDs = await fileStore.deletedTaskIDs
        XCTAssertEqual(try context.fetch(FetchDescriptor<FillTaskRecord>()).count, 0)
        XCTAssertEqual(Set(deletedTaskIDs), Set(records.map(\.id)))
        XCTAssertNil(flow.transientError)
        XCTAssertFalse(flow.isWorking)
    }

    func testClearTasksKeepsRecordsWhoseFilesCannotBeDeleted() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FillTaskRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let removable = FillTaskRecord(snapshot: .empty())
        let retained = FillTaskRecord(snapshot: .empty())
        retained.title = "保留任务"
        context.insert(removable)
        context.insert(retained)
        try context.save()

        let fileStore = RecordingDeletionFileStore(failingTaskID: retained.id)
        let flow = FlowStore(fileStore: fileStore)
        await flow.clearTasks([removable, retained], in: context)

        let remaining = try context.fetch(FetchDescriptor<FillTaskRecord>())
        let deletedTaskIDs = await fileStore.deletedTaskIDs
        XCTAssertEqual(remaining.map(\.id), [retained.id])
        XCTAssertEqual(Set(deletedTaskIDs), Set([removable.id, retained.id]))
        XCTAssertTrue(flow.transientError?.contains("保留任务") == true)
        XCTAssertFalse(flow.isWorking)
    }
}

private actor RecordingDeletionFileStore: TaskFileStoring {
    private(set) var deletedTaskIDs: [UUID] = []
    private let failingTaskID: UUID?

    init(failingTaskID: UUID? = nil) {
        self.failingTaskID = failingTaskID
    }

    func createTaskDirectory(taskID: UUID) throws {}
    func saveSnapshot(_ snapshot: FillTaskSnapshot) throws {}
    func loadSnapshot(taskID: UUID) throws -> FillTaskSnapshot {
        throw CocoaError(.fileNoSuchFile)
    }
    func importForm(from sourceURL: URL, taskID: UUID) throws -> FormAsset {
        throw CocoaError(.fileReadUnknown)
    }
    func importMaterial(from sourceURL: URL, taskID: UUID) throws -> MaterialAsset {
        throw CocoaError(.fileReadUnknown)
    }
    func deleteTask(taskID: UUID) throws {
        deletedTaskIDs.append(taskID)
        if taskID == failingTaskID {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
    func absoluteURL(for relativePath: String, taskID: UUID) throws -> URL {
        throw CocoaError(.fileNoSuchFile)
    }
    func exportURL(fileName: String, taskID: UUID) throws -> URL {
        throw CocoaError(.fileWriteUnknown)
    }
}

private struct FailingDeletionFileStore: TaskFileStoring {
    func createTaskDirectory(taskID: UUID) async throws {}
    func saveSnapshot(_ snapshot: FillTaskSnapshot) async throws {}
    func loadSnapshot(taskID: UUID) async throws -> FillTaskSnapshot {
        throw CocoaError(.fileNoSuchFile)
    }
    func importForm(from sourceURL: URL, taskID: UUID) async throws -> FormAsset {
        throw CocoaError(.fileReadUnknown)
    }
    func importMaterial(from sourceURL: URL, taskID: UUID) async throws -> MaterialAsset {
        throw CocoaError(.fileReadUnknown)
    }
    func deleteTask(taskID: UUID) async throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func absoluteURL(for relativePath: String, taskID: UUID) async throws -> URL {
        throw CocoaError(.fileNoSuchFile)
    }
    func exportURL(fileName: String, taskID: UUID) async throws -> URL {
        throw CocoaError(.fileWriteUnknown)
    }
}
