import Foundation
import XCTest
@testable import BiaoXia

final class ProfileStoreTests: XCTestCase {
    func testFirstLoadStartsEmptyAndPersistsEdits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PersonalProfileStore(rootURL: root)
        let seeded = try await store.load()
        XCTAssertEqual(seeded, .empty)
        XCTAssertFalse(seeded.isComplete)

        var edited = PersonalProfile.testFixture
        edited.fullName = "测试用户"
        try await store.save(edited)

        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.fullName, "测试用户")
        XCTAssertEqual(reloaded.school, PersonalProfile.testFixture.school)
    }

    func testLegacyProfileMigratesAsManualEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = """
        {"fullName":"林知夏","gender":"女","birthDate":"2004-09-18","school":"云岭未来大学","college":"智能工程学院","major":"数据科学与智能系统","studentID":"2023AI0427","phone":"13800004271","email":"lin.zhixia@example.test","address":"云岭市新知区星河路88号7栋302室"}
        """
        try Data(legacy.utf8).write(to: root.appending(path: "profile.json"))

        let migrated = try await PersonalProfileStore(rootURL: root).load()

        XCTAssertEqual(migrated.schemaVersion, PersonalProfile.currentSchemaVersion)
        XCTAssertTrue(migrated.isComplete)
        XCTAssertEqual(migrated.evidence?.count, FieldKey.allCases.count)
        XCTAssertTrue(migrated.evidence?.allSatisfy(\.modifiedByUser) == true)
        XCTAssertTrue(migrated.evidence?.allSatisfy { $0.sources.isEmpty } == true)
        XCTAssertEqual(migrated.informationItems.count, FieldKey.allCases.count)
        XCTAssertEqual(migrated.subjects?.count, 1)
        XCTAssertEqual(migrated.subjects?.first?.kind, .selfPerson)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "profile.pre-migration.json").path
        ))
    }

    func testSchemaThreeMigrationPreservesEvidenceSourcesAndItems() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalProfileStore(rootURL: root)
        let materialID = UUID()
        let source = FieldSource(
            materialID: materialID,
            materialName: "虚构材料.pdf",
            pageIndex: 1,
            excerpt: "专业：人工确认专业",
            confidence: 1
        )
        let item = ProfileItem(
            category: .education,
            fieldID: FieldKey.major.rawValue,
            label: "专业",
            value: "人工确认专业",
            confidence: 1,
            state: .confirmed,
            modifiedByUser: true,
            sources: [source]
        )
        var profile = PersonalProfile.empty
        profile.schemaVersion = 3
        profile.major = item.value
        profile.evidence = [ProfileFieldEvidence(
            key: .major,
            confidence: 1,
            resolvedByAI: false,
            modifiedByUser: true,
            sources: [source]
        )]
        profile.items = [item]
        try await store.save(profile)

        let migrated = try await store.load()

        XCTAssertEqual(migrated.schemaVersion, PersonalProfile.currentSchemaVersion)
        XCTAssertEqual(migrated.evidence?.first?.sources, [source])
        XCTAssertEqual(migrated.items, [item])
        XCTAssertEqual(migrated.subjects?.first?.kind, .selfPerson)
    }

    func testFixtureProfileProducesEveryTemplateField() {
        let fields = PersonalProfile.testFixture.resolvedFields
        XCTAssertEqual(fields.count, FieldKey.allCases.count)
        XCTAssertTrue(fields.allSatisfy { !$0.value.isEmpty })
        XCTAssertTrue(fields.allSatisfy { $0.confidence == 1 })
    }
}
