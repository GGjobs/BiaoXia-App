import Foundation
import PDFKit

protocol ProfileLibraryStoring: MaterialFileResolving, Sendable {
    func load() async throws -> ProfileLibrarySnapshot
    func save(_ snapshot: ProfileLibrarySnapshot) async throws
    func importMaterial(from sourceURL: URL) async throws -> MaterialAsset
    func renameMaterial(id: UUID, to displayName: String) async throws
    func deleteMaterial(_ material: MaterialAsset) async throws
    func absoluteURL(for relativePath: String) async throws -> URL
}

actor ProfileLibraryStore: ProfileLibraryStoring {
    static let shared = ProfileLibraryStore()

    private let fileManager: FileManager
    private let rootURL: URL
    private let snapshotURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        let base = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "BiaoXia/Profile")
        self.rootURL = base.standardizedFileURL
        snapshotURL = base.appending(path: "library.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> ProfileLibrarySnapshot {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return .empty()
        }
        var snapshot = try decoder.decode(
            ProfileLibrarySnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
        if snapshot.schemaVersion < ProfileLibrarySnapshot.currentSchemaVersion {
            let originalData = try Data(contentsOf: snapshotURL)
            try preserveMigrationSource(originalData)
            snapshot.schemaVersion = ProfileLibrarySnapshot.currentSchemaVersion
            snapshot.profileItems = snapshot.profileItems ?? []
            snapshot.pendingItems = snapshot.pendingItems ?? []
            snapshot.changeHistory = snapshot.changeHistory ?? []
            snapshot.subjects = snapshot.subjects ?? []
            snapshot.records = snapshot.records ?? []
            snapshot.formMappings = snapshot.formMappings ?? []
            // Legacy consent covered individual requests, never ongoing access to profile items.
            snapshot.aiSharingGrants = [:]
            try save(snapshot)
        } else if snapshot.schemaVersion != ProfileLibrarySnapshot.currentSchemaVersion {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot
    }

    func save(_ snapshot: ProfileLibrarySnapshot) throws {
        try ensureDirectories()
        try encoder.encode(snapshot).write(
            to: snapshotURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        applyProtection(to: snapshotURL)
    }

    func importMaterial(from sourceURL: URL) throws -> MaterialAsset {
        try ensureDirectories()
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let fileExtension = sourceURL.pathExtension.lowercased()
        let kind: MaterialKind
        switch fileExtension {
        case "pdf": kind = .pdf
        case "docx":
            kind = .docx
            _ = try DOCXMaterialReader().read(from: sourceURL, materialID: UUID())
        case "jpg", "jpeg", "png", "heic", "heif": kind = .image
        default: throw BiaoXiaError.unsupportedMaterial
        }

        let id = UUID()
        let relativePath = "materials/\(id.uuidString.lowercased()).\(fileExtension)"
        let destination = try safeURL(for: relativePath)
        try fileManager.copyItem(at: sourceURL, to: destination)
        applyProtection(to: destination)
        return MaterialAsset(
            id: id,
            displayName: sourceURL.lastPathComponent,
            kind: kind,
            pageCount: DocumentPageCounter.pageCount(for: destination, kind: kind),
            relativePath: relativePath
        )
    }

    func renameMaterial(id: UUID, to displayName: String) throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), trimmed.count <= 80 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    func deleteMaterial(_ material: MaterialAsset) throws {
        let url = try safeURL(for: material.relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func absoluteURL(for relativePath: String) throws -> URL {
        try safeURL(for: relativePath)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: rootURL.appending(path: "materials"),
            withIntermediateDirectories: true
        )
        applyProtection(to: rootURL)
    }

    private func safeURL(for relativePath: String) throws -> URL {
        let candidate = rootURL.appending(path: relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.path + "/") else {
            throw BiaoXiaError.unsafeFilePath
        }
        return candidate
    }

    private func applyProtection(to url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func preserveMigrationSource(_ data: Data) throws {
        let backupURL = rootURL.appending(path: "library.pre-migration.json")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try data.write(to: backupURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        applyProtection(to: backupURL)
    }
}
