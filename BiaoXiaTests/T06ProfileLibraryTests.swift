import Foundation
import XCTest
@testable import BiaoXia

final class T06ProfileLibraryTests: XCTestCase {
    func testMultipleRecordExtractionUsesStableSemanticIdentity() {
        let materialID = UUID()
        let material = MaterialAsset(
            displayName: "虚构经历.pdf",
            kind: .pdf,
            pageCount: 1,
            relativePath: "materials/fictional.pdf"
        )
        let blocks = [
            makeBlock("技能：Swift", materialID: materialID),
            makeBlock("技能：Swift", materialID: materialID),
            makeBlock("课程：数据结构｜学分：3｜成绩：95", materialID: materialID)
        ]

        let first = RuleBasedProfileItemExtractor().extractItems(from: blocks, materials: [material])
        let second = RuleBasedProfileItemExtractor().extractItems(from: blocks, materials: [material])

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.map(\.fieldID), second.map(\.fieldID))
        XCTAssertEqual(first.map(\.normalizedIdentity), second.map(\.normalizedIdentity))
        XCTAssertEqual(Set(first.map(\.normalizedIdentity)).count, first.count)
    }

    @MainActor
    func testRecognitionDeduplicatesRecordsAndPersistsT05RecordContract() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryStore = ProfileLibraryStore(rootURL: root.appending(path: "library"))
        let profileStore = PersonalProfileStore(rootURL: root.appending(path: "profile"))
        let material = MaterialAsset(
            displayName: "虚构经历.pdf",
            kind: .pdf,
            pageCount: 1,
            relativePath: "materials/fictional.pdf"
        )
        let blocks = [
            makeBlock("姓名：林知夏", materialID: material.id),
            makeBlock("学历：本科", materialID: material.id),
            makeBlock("项目经历：表格助手｜角色：开发｜时间：2025", materialID: material.id),
            makeBlock("技能：Swift", materialID: material.id)
        ]
        let ocr = T06StubOCR(blocks: blocks)
        let flow = FlowStore(
            profileStore: profileStore,
            profileLibraryStore: libraryStore,
            profileOCRService: ocr
        )
        flow.profileLibrary.materials = [material]

        await flow.startProfileRecognition()
        let firstItems = try XCTUnwrap(flow.profileLibrary.profileItems)
        let firstIDs = Dictionary(uniqueKeysWithValues: firstItems.map { ($0.normalizedIdentity, $0.id) })

        await flow.startProfileRecognition()
        let secondItems = try XCTUnwrap(flow.profileLibrary.profileItems)
        XCTAssertEqual(secondItems.count, firstItems.count)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: secondItems.map { ($0.normalizedIdentity, $0.id) }),
            firstIDs
        )
        XCTAssertEqual(flow.profileLibrary.records?.count, 4)
        XCTAssertEqual(flow.profileLibrary.subjects?.filter { $0.kind == .selfPerson }.count, 1)

        flow.addProfileSubject(
            displayName: "林海川",
            kind: .familyMember,
            relationshipToSelf: "父亲"
        )
        let familyMember = try XCTUnwrap(
            flow.profileLibrary.subjects?.first { $0.kind == .familyMember }
        )
        flow.addCustomProfileItem(
            label: "工作经历",
            value: "虚构工程师经历",
            category: .work,
            subjectID: familyMember.id
        )

        await flow.saveConfirmedProfile()
        let saved = try await profileStore.load()
        XCTAssertEqual(saved.records?.count, 5)
        XCTAssertEqual(saved.subjects?.filter { $0.kind == .selfPerson }.count, 1)
        XCTAssertEqual(saved.records?.first { $0.displayValue == "虚构工程师经历" }?.subjectID, familyMember.id)
    }

    @MainActor
    func testFailedRecognitionResumesFromPersistedPages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = MaterialAsset(
            displayName: "虚构两页材料.pdf",
            kind: .pdf,
            pageCount: 2,
            relativePath: "materials/fictional.pdf"
        )
        let completed = makeBlock("技能：Swift", materialID: material.id)
        let ocr = T06RecordingOCR()
        let flow = FlowStore(
            profileStore: PersonalProfileStore(rootURL: root.appending(path: "profile")),
            profileLibraryStore: ProfileLibraryStore(rootURL: root.appending(path: "library")),
            profileOCRService: ocr
        )
        flow.profileLibrary.status = .failed
        flow.profileLibrary.materials = [material]
        flow.profileLibrary.ocrBlocks = [completed]
        flow.profileLibrary.recognitionCompletedPages = 1
        flow.profileLibrary.recognitionTotalPages = 2

        await flow.startProfileRecognition()

        let received = await ocr.receivedBlocks
        XCTAssertEqual(received, [completed])
        XCTAssertEqual(flow.profileLibrary.recognitionCompletedPages, 1)
    }

    private func makeBlock(_ text: String, materialID: UUID) -> OCRBlock {
        OCRBlock(
            text: text,
            pageIndex: 0,
            boundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.05),
            confidence: 0.99,
            materialID: materialID
        )
    }
}

private struct T06StubOCR: OCRServing {
    let blocks: [OCRBlock]

    func recognize(
        materials: [MaterialAsset],
        existingBlocks: [OCRBlock],
        progress: @escaping @Sendable (Int, Int, [OCRBlock]) async -> Void
    ) async throws -> [OCRBlock] {
        await progress(1, 1, blocks)
        return blocks
    }
}

private actor T06RecordingOCR: OCRServing {
    private(set) var receivedBlocks: [OCRBlock] = []

    func recognize(
        materials: [MaterialAsset],
        existingBlocks: [OCRBlock],
        progress: @escaping @Sendable (Int, Int, [OCRBlock]) async -> Void
    ) async throws -> [OCRBlock] {
        receivedBlocks = existingBlocks
        await progress(1, 2, existingBlocks)
        return existingBlocks
    }
}
