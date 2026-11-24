import Foundation
import XCTest
@testable import BiaoXia

final class GeneralModelMigrationTests: XCTestCase {
    func testDynamicFieldKeepsMeaningAnswerAndLocationSeparate() throws {
        let field = DynamicFormField(
            id: "field-1",
            label: "最高学历毕业院校",
            section: "教育经历",
            instructions: nil,
            kind: .singleLineText,
            options: [],
            constraints: FormFieldConstraints(isRequired: true, maximumCharacters: 40),
            anchors: [PDFFieldAnchor(
                pageIndex: 0,
                rect: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.05),
                kind: .textRegion,
                widgetName: nil,
                confidence: 0.92
            )],
            meaning: FieldMeaning(
                canonicalKey: "education.highest.school",
                summary: "最高学历记录对应的学校",
                state: .knownLocally
            ),
            answer: PersonalAnswer(
                value: "虚构大学",
                selectedOptionIDs: [],
                sourceRecordIDs: [UUID()],
                confirmationState: .confirmed,
                modifiedByUser: true
            )
        )

        let decoded = try JSONDecoder().decode(
            DynamicFormField.self,
            from: JSONEncoder().encode(field)
        )
        XCTAssertEqual(decoded, field)
        XCTAssertEqual(decoded.meaning.canonicalKey, "education.highest.school")
        XCTAssertEqual(decoded.answer?.value, "虚构大学")
        XCTAssertEqual(decoded.anchors.first?.pageIndex, 0)
    }

    func testMultipleEducationRecordsHaveStableBusinessKeysAndDistinctInstanceIDs() {
        let subjectID = UUID()
        let undergraduate = ["school": "虚构大学", "degree": "本科", "start": "2018"]
        let graduate = ["school": "示例学院", "degree": "硕士", "start": "2022"]

        let firstKey = ProfileBusinessKey.make(
            kind: .education,
            subjectID: subjectID,
            components: undergraduate
        )
        let reorderedKey = ProfileBusinessKey.make(
            kind: .education,
            subjectID: subjectID,
            components: ["start": "2018", "degree": "本科", "school": "虚构大学"]
        )
        let secondKey = ProfileBusinessKey.make(
            kind: .education,
            subjectID: subjectID,
            components: graduate
        )

        XCTAssertEqual(firstKey, reorderedKey)
        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertNotEqual(UUID(), UUID())

        var displayValue = "虚构大学 · 本科"
        let keyBeforeEdit = firstKey
        displayValue = "虚构大学（本科）"
        XCTAssertEqual(keyBeforeEdit, firstKey)
        XCTAssertEqual(displayValue, "虚构大学（本科）")
    }

    func testLegacyTaskMigrationIsRepeatableAndPreservesBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root)
        var legacy = FillTaskSnapshot.empty()
        legacy.schemaVersion = nil
        legacy.title = "迁移保留标题"
        try await store.saveSnapshot(legacy)

        let first = try await store.loadSnapshot(taskID: legacy.id)
        let second = try await store.loadSnapshot(taskID: legacy.id)
        let taskDirectory = root.appending(component: legacy.id.uuidString.lowercased())

        XCTAssertEqual(first.schemaVersion, TaskFileStore.currentSnapshotSchemaVersion)
        XCTAssertEqual(second.schemaVersion, TaskFileStore.currentSnapshotSchemaVersion)
        XCTAssertEqual(second.title, "迁移保留标题")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: taskDirectory.appending(component: "snapshot.pre-migration.json").path
        ))
    }

    func testRecoverableSnapshotsRebuildsIndexAndIgnoresPartialSave() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root)
        var saved = FillTaskSnapshot.empty()
        saved.title = "可恢复任务"
        try await store.saveSnapshot(saved)

        let interruptedID = UUID()
        let interruptedDirectory = root.appending(component: interruptedID.uuidString.lowercased())
        try FileManager.default.createDirectory(at: interruptedDirectory, withIntermediateDirectories: true)
        try Data("{\"partial\":".utf8).write(
            to: interruptedDirectory.appending(component: "snapshot.json")
        )

        let recovered = try await store.recoverableSnapshots()
        XCTAssertEqual(recovered.map(\.id), [saved.id])
        XCTAssertEqual(recovered.first?.title, "可恢复任务")
        XCTAssertTrue(FileManager.default.fileExists(atPath: interruptedDirectory.path))
    }

    func testFutureTaskSchemaIsRejectedWithoutChangingSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root)
        var future = FillTaskSnapshot.empty()
        future.schemaVersion = 99
        try await store.saveSnapshot(future)
        let snapshotURL = root
            .appending(component: future.id.uuidString.lowercased())
            .appending(component: "snapshot.json")
        let source = try Data(contentsOf: snapshotURL)

        do {
            _ = try await store.loadSnapshot(taskID: future.id)
            XCTFail("Expected future schema rejection")
        } catch {
            XCTAssertEqual(try Data(contentsOf: snapshotURL), source)
        }
    }
}

private struct StubFormParser: FormParsing {
    let document: GeneralFormDocument

    func parse(formURL: URL) async throws -> GeneralFormDocument { document }
}

private struct StubFieldExplainer: FieldExplaining {
    let meanings: [String: FieldMeaning]

    func explain(fields: [DynamicFormField]) async throws -> [String: FieldMeaning] { meanings }
}

private struct StubAnswerMatcher: AnswerMatching {
    let answers: [String: PersonalAnswer]

    func match(
        fields: [DynamicFormField],
        subjects: [ProfileSubject],
        records: [ProfileRecord]
    ) async throws -> [String: PersonalAnswer] { answers }
}

private struct StubFormWriter: FormWriting {
    func write(
        document: GeneralFormDocument,
        sourceURL: URL,
        destinationURL: URL
    ) async throws {}
}
