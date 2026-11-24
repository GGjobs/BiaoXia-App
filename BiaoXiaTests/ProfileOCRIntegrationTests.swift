import Foundation
import XCTest
@testable import BiaoXia

final class ProfileOCRIntegrationTests: XCTestCase {
    func testPreparedMaterialsProduceProfileAndAIConflict() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetDirectory = repositoryRoot.appending(path: "TestAssets/SimulatorFiles")
        let sourceURLs = [
            assetDirectory.appending(path: "fictional_resume.pdf"),
            assetDirectory.appending(path: "fictional_student_card.png"),
            assetDirectory.appending(path: "fictional_transcript.pdf")
        ]
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileLibraryStore(rootURL: root)
        var materials: [MaterialAsset] = []
        for url in sourceURLs {
            materials.append(try await store.importMaterial(from: url))
        }

        let blocks = try await VisionOCRService(fileResolver: store).recognize(
            materials: materials,
            existingBlocks: []
        ) { _, _, _ in }
        let result = RuleBasedFieldExtractor().extract(from: blocks)
        let values = Dictionary(uniqueKeysWithValues: result.resolved.map { ($0.key, $0.value) })
        let majorCandidates = result.candidates
            .filter { $0.fieldKey == .major }
            .sorted { $0.score > $1.score }
        let leadingMajor = try XCTUnwrap(majorCandidates.first)
        let alternateMajor = try XCTUnwrap(majorCandidates.dropFirst().first)

        XCTAssertEqual(
            values[.fullName],
            "林知夏",
            "姓名候选：\(result.candidates.filter { $0.fieldKey == .fullName }.map { ($0.value, $0.score) })"
        )
        XCTAssertEqual(values[.school], "云岭未来大学")
        XCTAssertEqual(values[.studentID], "2023AI0427")
        XCTAssertEqual(values.filter { !$0.value.isEmpty }.count, FieldKey.allCases.count)
        XCTAssertGreaterThanOrEqual(majorCandidates.count, 2)
        XCTAssertLessThan(
            leadingMajor.score - alternateMajor.score,
            0.10,
            "专业候选：\(majorCandidates.map { ($0.value, $0.score, $0.scoreReasons) })"
        )
    }
}
