import CoreGraphics
import Foundation
import PDFKit

protocol TaskFileStoring: Sendable {
    func createTaskDirectory(taskID: UUID) async throws
    func saveSnapshot(_ snapshot: FillTaskSnapshot) async throws
    func loadSnapshot(taskID: UUID) async throws -> FillTaskSnapshot
    func importForm(from sourceURL: URL, taskID: UUID) async throws -> FormAsset
    func importMaterial(from sourceURL: URL, taskID: UUID) async throws -> MaterialAsset
    func deleteTask(taskID: UUID) async throws
    func absoluteURL(for relativePath: String, taskID: UUID) async throws -> URL
    func exportURL(fileName: String, taskID: UUID) async throws -> URL
}

protocol MaterialFileResolving: Sendable {
    func absoluteURL(for relativePath: String) async throws -> URL
}

struct TaskMaterialFileResolver: MaterialFileResolving {
    let store: any TaskFileStoring
    let taskID: UUID

    func absoluteURL(for relativePath: String) async throws -> URL {
        try await store.absoluteURL(for: relativePath, taskID: taskID)
    }
}

actor TaskFileStore: TaskFileStoring {
    static let shared = TaskFileStore()
    static let currentSnapshotSchemaVersion = 2

    private let fileManager: FileManager
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.rootURL = applicationSupport.appending(
                component: "BiaoXia/Tasks",
                directoryHint: .isDirectory
            )
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func createTaskDirectory(taskID: UUID) throws {
        let directory = taskDirectory(taskID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: directory.appending(component: "materials", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: directory.appending(component: "forms", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: directory.appending(component: "exports", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        applyFileProtection(to: directory)
    }

    func saveSnapshot(_ snapshot: FillTaskSnapshot) throws {
        try createTaskDirectory(taskID: snapshot.id)
        let data = try encoder.encode(snapshot)
        let destination = taskDirectory(snapshot.id).appending(component: "snapshot.json")
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        applyFileProtection(to: destination)
    }

    func loadSnapshot(taskID: UUID) throws -> FillTaskSnapshot {
        let url = taskDirectory(taskID).appending(component: "snapshot.json")
        let originalData = try Data(contentsOf: url)
        var snapshot = try decoder.decode(FillTaskSnapshot.self, from: originalData)
        if let schemaVersion = snapshot.schemaVersion,
           schemaVersion > Self.currentSnapshotSchemaVersion {
            throw CocoaError(.fileReadCorruptFile)
        }
        if (snapshot.schemaVersion ?? 1) < Self.currentSnapshotSchemaVersion {
            let backupURL = taskDirectory(taskID).appending(component: "snapshot.pre-migration.json")
            if !fileManager.fileExists(atPath: backupURL.path) {
                try originalData.write(to: backupURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                applyFileProtection(to: backupURL)
            }
            snapshot.schemaVersion = Self.currentSnapshotSchemaVersion
            try saveSnapshot(snapshot)
        }
        return snapshot
    }

    /// 枚举可解码的任务正文，供列表索引缺失或部分写入后重建。
    /// 损坏目录不会阻止其他任务恢复，也不会被删除或覆盖。
    func recoverableSnapshots() throws -> [FillTaskSnapshot] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            let snapshotURL = directory.appending(component: "snapshot.json")
            guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
            return try? decoder.decode(FillTaskSnapshot.self, from: data)
        }
    }

    func importForm(from sourceURL: URL, taskID: UUID) throws -> FormAsset {
        try createTaskDirectory(taskID: taskID)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let format = sourceURL.pathExtension.lowercased()
        let pageCount: Int
        switch format {
        case "pdf":
            guard let document = PDFDocument(url: sourceURL), document.pageCount > 0,
                  !document.isEncrypted, !document.isLocked else { throw BiaoXiaError.unsupportedForm }
            pageCount = document.pageCount
        case "docx":
            try DOCXFormEngine.validatePackage(at: sourceURL)
            // OOXML 的缓存页数不可信；0 表示未由排版器计算，不伪报一页。
            pageCount = 0
        default: throw BiaoXiaError.unsupportedForm
        }

        let id = UUID()
        let relativePath = "forms/\(id.uuidString.lowercased()).\(format)"
        let destination = taskDirectory(taskID).appending(path: relativePath)
        try fileManager.copyItem(at: sourceURL, to: destination)
        applyFileProtection(to: destination)

        return FormAsset(
            id: id,
            displayName: sourceURL.lastPathComponent,
            pageCount: pageCount,
            relativePath: relativePath,
            templateID: "general-\(format)-v1"
        )
    }

    func importMaterial(from sourceURL: URL, taskID: UUID) throws -> MaterialAsset {
        try createTaskDirectory(taskID: taskID)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = sourceURL.pathExtension.lowercased()
        let kind: MaterialKind
        switch fileExtension {
        case "docx":
            kind = .docx
            _ = try DOCXMaterialReader().read(from: sourceURL, materialID: UUID())
        case "pdf":
            kind = .pdf
        case "jpg", "jpeg", "png", "heic", "heif":
            kind = .image
        default:
            throw BiaoXiaError.unsupportedMaterial
        }

        let id = UUID()
        let safeName = "\(id.uuidString.lowercased()).\(fileExtension)"
        let relativePath = "materials/\(safeName)"
        let destination = taskDirectory(taskID).appending(path: relativePath)
        try fileManager.copyItem(at: sourceURL, to: destination)
        applyFileProtection(to: destination)

        return MaterialAsset(
            id: id,
            displayName: sourceURL.lastPathComponent,
            kind: kind,
            pageCount: DocumentPageCounter.pageCount(for: destination, kind: kind),
            relativePath: relativePath
        )
    }

    func deleteTask(taskID: UUID) throws {
        let directory = taskDirectory(taskID).standardizedFileURL
        let root = rootURL.standardizedFileURL
        guard directory.deletingLastPathComponent() == root else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func absoluteURL(for relativePath: String, taskID: UUID) throws -> URL {
        let base = taskDirectory(taskID).standardizedFileURL
        let candidate = base.appending(path: relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return candidate
    }

    func exportURL(fileName: String, taskID: UUID) throws -> URL {
        try createTaskDirectory(taskID: taskID)
        return taskDirectory(taskID)
            .appending(component: "exports", directoryHint: .isDirectory)
            .appending(component: fileName)
    }

    private func taskDirectory(_ taskID: UUID) -> URL {
        rootURL.appending(
            component: taskID.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
    }

    private func applyFileProtection(to url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

enum DocumentPageCounter {
    static func pageCount(for url: URL, kind: MaterialKind) -> Int {
        if kind == .docx { return 0 } // 无排版器，页数未知；识别进度按一个文档单元计算。
        guard kind == .pdf else { return 1 }
        return CGPDFDocument(url as CFURL)?.numberOfPages ?? 1
    }
}
