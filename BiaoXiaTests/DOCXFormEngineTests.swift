import Foundation
import SwiftData
import Testing
@testable import BiaoXia

struct DOCXFormEngineTests {
    @Test func nativeWordMaterialRegression() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(try DOCXMaterialChecks.run(repository: repository, output: output) >= 15)
    }

    @Test func wordMaterialImportRecognizeAndResume() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = try WordPackage(Data(contentsOf: repository.appending(path: "TestAssets/GeneralForms/debug/normal/F01-docx.docx")))
        let source = root.appending(path: "fictional.docx")
        let xml = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>姓名：虚构建档</w:t></w:r></w:p></w:body></w:document>"
        try package.replacingDocument(Data(xml.utf8)).write(to: source)
        let store = ProfileLibraryStore(rootURL: root.appending(path: "library"))
        let material = try await store.importMaterial(from: source)
        #expect(material.kind == .docx && material.pageCount == 0)
        let service = VisionOCRService(fileResolver: store)
        let blocks = try await service.recognize(materials: [material], existingBlocks: []) { completed, total, _ in
            #expect(completed == 1 && total == 1)
        }
        #expect(blocks.count == 1 && blocks[0].text == "姓名：虚构建档")
        let resumed = try await service.recognize(materials: [material], existingBlocks: blocks) { _, _, _ in }
        #expect(resumed == blocks)
        var snapshot = ProfileLibrarySnapshot.empty()
        snapshot.materials = [material]
        snapshot.ocrBlocks = blocks
        try await store.save(snapshot)
        #expect(try await store.load().ocrBlocks == blocks)
        try await store.deleteMaterial(material)
        #expect(!FileManager.default.fileExists(atPath: try await store.absoluteURL(for: material.relativePath).path))
    }

    @Test func nativeWordRegression() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(try await DOCXEngineChecks.run(repository: repository, output: output) >= 20)
    }

    @Test @MainActor func wordImportMatchRestoreAndExport() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root)
        let container = try ModelContainer(for: FillTaskRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let flow = FlowStore(fileStore: store)
        flow.profile = .testFixture
        await flow.createTask(in: container.mainContext)
        await flow.importForm(from: repository.appending(path: "TestAssets/GeneralForms/debug/normal/F01-docx.docx"), in: container.mainContext)
        let document = try #require(flow.snapshot?.generalForm)
        #expect(document.effectiveFormat == .docx)
        #expect(flow.snapshot?.form?.isWord == true)
        #expect(flow.snapshot?.status == .reviewing)
        await flow.prepareFieldExplanationReview(in: container.mainContext)
        #expect(flow.snapshot?.fieldExplanationDraft?.canSend == false)
        #expect(flow.snapshot?.fieldExplanationDraft?.texts.allSatisfy { $0.state != .allowed } == true)
        for field in document.fields {
            flow.updateGeneralFormAnswer(fieldID: field.id, value: field.kind == .date ? "2026-09-22" : "虚构测试",
                selectedOptionIDs: field.options.first.map { [$0.id] } ?? [], in: container.mainContext)
        }
        await flow.export(in: container.mainContext)
        #expect(flow.snapshot?.status == .completed)
        let url = try #require(await flow.exportFileURL())
        #expect(url.pathExtension == "docx")
        let restored = try await store.loadSnapshot(taskID: #require(flow.snapshot?.id))
        #expect(restored.generalForm?.effectiveFormat == .docx)
        #expect(restored.exportRelativePath?.hasSuffix(".docx") == true)
    }
}
