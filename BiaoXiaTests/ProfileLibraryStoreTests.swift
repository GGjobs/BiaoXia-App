import Foundation
import XCTest
@testable import BiaoXia

final class ProfileLibraryStoreTests: XCTestCase {
    private var resumeURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TestAssets/SimulatorFiles/fictional_resume.pdf")
    }

    func testMaterialCRUDAndSnapshotPersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileLibraryStore(rootURL: root)

        let material = try await store.importMaterial(from: resumeURL)
        let importedURL = try await store.absoluteURL(for: material.relativePath)
        XCTAssertEqual(material.kind, .pdf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))

        var snapshot = ProfileLibrarySnapshot.empty()
        snapshot.materials = [material]
        snapshot.status = .imported
        try await store.save(snapshot)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.materials, [material])

        try await store.renameMaterial(id: material.id, to: "虚构简历.pdf")
        try await store.deleteMaterial(material)
        let deletedURL = try await store.absoluteURL(for: material.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedURL.path))
    }

    func testRejectsTraversalAndUnsafeRename() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileLibraryStore(rootURL: root)

        do {
            _ = try await store.absoluteURL(for: "../outside.pdf")
            XCTFail("Expected unsafe path rejection")
        } catch let error as BiaoXiaError {
            guard case .unsafeFilePath = error else { return XCTFail("Unexpected: \(error)") }
        }

        do {
            try await store.renameMaterial(id: UUID(), to: "../bad.pdf")
            XCTFail("Expected unsafe rename rejection")
        } catch {
            XCTAssertNotNil(error as? CocoaError)
        }
    }

    func testSchemaOneMigratesAndUnknownSchemaIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileLibraryStore(rootURL: root)

        var legacy = ProfileLibrarySnapshot.empty()
        legacy.schemaVersion = 1
        legacy.profileItems = nil
        legacy.pendingItems = nil
        legacy.changeHistory = nil
        try await store.save(legacy)
        let migrated = try await store.load()
        XCTAssertEqual(migrated.schemaVersion, ProfileLibrarySnapshot.currentSchemaVersion)
        XCTAssertEqual(migrated.profileItems, [])
        XCTAssertEqual(migrated.pendingItems, [])
        XCTAssertEqual(migrated.changeHistory, [])

        var future = migrated
        future.schemaVersion = 99
        try await store.save(future)
        let libraryURL = root.appending(path: "library.json")
        let preservedData = try Data(contentsOf: libraryURL)
        do {
            _ = try await store.load()
            XCTFail("Expected an unsupported schema error")
        } catch {
            XCTAssertEqual(try Data(contentsOf: libraryURL), preservedData)
        }
    }

    @MainActor
    func testClearingProfileInformationDeletesProfileAndMaterialsButKeepsWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let profileRoot = root.appending(component: "ProfileData", directoryHint: .isDirectory)
        let libraryRoot = root.appending(component: "LibraryData", directoryHint: .isDirectory)
        let profileStore = PersonalProfileStore(rootURL: profileRoot)
        let libraryStore = ProfileLibraryStore(rootURL: libraryRoot)
        let material = try await libraryStore.importMaterial(from: resumeURL)
        let materialURL = try await libraryStore.absoluteURL(for: material.relativePath)
        let workspaceID = UUID()

        try await profileStore.save(.testFixture)
        var snapshot = ProfileLibrarySnapshot.empty(workspaceID: workspaceID)
        snapshot.materials = [material]
        snapshot.status = .confirmed
        try await libraryStore.save(snapshot)

        let flow = FlowStore(
            profileStore: profileStore,
            profileLibraryStore: libraryStore
        )
        await flow.loadProfile()
        await flow.clearProfileInformation()

        XCTAssertEqual(flow.profile, .empty)
        XCTAssertTrue(flow.profileLibrary.materials.isEmpty)
        XCTAssertEqual(flow.profileLibrary.workspaceID, workspaceID)
        XCTAssertNil(flow.transientError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: materialURL.path))

        let reloadedProfile = try await profileStore.load()
        XCTAssertEqual(reloadedProfile, .empty)
        let reloadedLibrary = try await libraryStore.load()
        XCTAssertTrue(reloadedLibrary.materials.isEmpty)
        XCTAssertEqual(reloadedLibrary.status, .draft)
        XCTAssertEqual(reloadedLibrary.workspaceID, workspaceID)
    }
}
