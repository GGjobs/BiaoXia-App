import Foundation
import PDFKit
import UIKit
import XCTest
@testable import BiaoXia

final class FormWorkflowTests: XCTestCase {
    private var demoFormURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TestAssets/SimulatorFiles/blank_competition_registration_form.pdf")
    }

    func testImportsSupportedBlankForm() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root)
        let taskID = UUID()

        let form = try await store.importForm(from: demoFormURL, taskID: taskID)

        XCTAssertEqual(form.templateID, "general-pdf-v1")
        XCTAssertEqual(form.pageCount, 3)
        let importedURL = try await store.absoluteURL(
            for: form.relativePath,
            taskID: taskID
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))
    }

    func testImportsUnknownTextPDFForGeneralParser() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let unknownURL = root.appending(component: "unknown.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89))
        try renderer.pdfData { context in
            context.beginPage()
            ("其他表格" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: nil)
        }.write(to: unknownURL)

        let store = TaskFileStore(rootURL: root.appending(component: "tasks"))
        let imported = try await store.importForm(from: unknownURL, taskID: UUID())
        XCTAssertEqual(imported.templateID, "general-pdf-v1")
        XCTAssertEqual(imported.pageCount, 1)
    }

    func testExportUsesImportedFormAndPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root)
        let taskID = UUID()
        let form = try await store.importForm(from: demoFormURL, taskID: taskID)
        let importedURL = try await store.absoluteURL(
            for: form.relativePath,
            taskID: taskID
        )
        let originalData = try Data(contentsOf: importedURL)

        let exporter = PDFExportService(fileStore: store)
        let result = try await exporter.export(
            taskID: taskID,
            sourceFormRelativePath: form.relativePath,
            resolvedFields: PersonalProfile.testFixture.resolvedFields
        )

        XCTAssertEqual(try Data(contentsOf: importedURL), originalData)
        XCTAssertNotEqual(try Data(contentsOf: result.url), originalData)
        let document = try XCTUnwrap(PDFDocument(url: result.url))
        XCTAssertEqual(document.pageCount, 3)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue((page.string ?? "").contains(PersonalProfile.testFixture.fullName))
    }
}
