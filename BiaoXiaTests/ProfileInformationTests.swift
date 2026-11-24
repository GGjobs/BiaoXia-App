import Foundation
import XCTest
@testable import BiaoXia

final class ProfileInformationTests: XCTestCase {
    func testRuleExtractorKeepsOpenStudentInformationAndCourses() {
        let materialID = UUID()
        let material = MaterialAsset(
            id: materialID,
            displayName: "简历.pdf",
            kind: .pdf,
            pageCount: 1,
            relativePath: "materials/resume.pdf"
        )
        let texts = [
            "技能：Swift、Python",
            "获奖：2025 年校级创新创业竞赛二等奖",
            "项目经历：校园数据可视化平台｜角色：项目负责人｜描述：负责需求梳理与移动端原型。",
            "课程：数据结构｜学分：4.0｜成绩：92",
        ]
        let blocks = texts.enumerated().map { index, text in
            OCRBlock(
                text: text,
                pageIndex: 0,
                boundingBox: NormalizedRect(x: 0.1, y: Double(index) * 0.1, width: 0.8, height: 0.05),
                confidence: 0.96,
                materialID: materialID
            )
        }

        let items = RuleBasedProfileItemExtractor().extractItems(from: blocks, materials: [material])

        XCTAssertTrue(items.contains { $0.category == .skill && $0.value.contains("Swift") })
        XCTAssertTrue(items.contains { $0.category == .award })
        XCTAssertTrue(items.contains { $0.category == .project && $0.components["角色"] == "项目负责人" })
        XCTAssertTrue(items.contains { $0.category == .course && $0.components["score"] == "92" })
        XCTAssertTrue(items.allSatisfy { $0.sources.first?.materialName == "简历.pdf" })
    }

    func testSensitiveItemMasksAllButLastFourCharacters() {
        let item = ProfileItem(
            category: .identity,
            fieldID: "identityNumber",
            label: "身份证号",
            value: "11010120040918321X",
            confidence: 1,
            state: .confirmed,
            sensitivity: .highlySensitive
        )
        XCTAssertFalse(item.maskedValue.contains("11010120040918"))
        XCTAssertTrue(item.maskedValue.hasSuffix("321X"))
    }

    func testProfileCanBeSavedWithOneInformationItem() {
        var profile = PersonalProfile.empty
        profile.items = [ProfileItem(
            category: .skill,
            fieldID: "skill.swift",
            label: "技能",
            value: "Swift",
            confidence: 1,
            state: .confirmed,
            modifiedByUser: true
        )]
        XCTAssertTrue(profile.hasInformation)
        XCTAssertFalse(profile.isComplete)
    }

    @MainActor
    func testAcceptAllPendingProfileItemsConfirmsEveryItemInOneBatch() {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let flow = FlowStore(
            profileStore: PersonalProfileStore(rootURL: root.appending(path: "profile")),
            profileLibraryStore: ProfileLibraryStore(rootURL: root.appending(path: "library"))
        )
        let pendingItems = [
            ProfileItem(
                category: .skill,
                fieldID: "skill.swift",
                label: "技能",
                value: "Swift",
                confidence: 0.88,
                state: .pending
            ),
            ProfileItem(
                category: .award,
                fieldID: "award.innovation",
                label: "获奖",
                value: "创新竞赛二等奖",
                confidence: 0.86,
                state: .pending
            ),
        ]
        flow.profileLibrary.pendingItems = pendingItems

        flow.acceptAllPendingProfileItems()

        XCTAssertTrue(flow.profileLibrary.pendingItems?.isEmpty == true)
        XCTAssertEqual(Set(flow.profileLibrary.profileItems?.map(\.id) ?? []), Set(pendingItems.map(\.id)))
        XCTAssertTrue(flow.profileLibrary.profileItems?.allSatisfy { $0.state == .confirmed } == true)
        XCTAssertEqual(flow.profileLibrary.changeHistory?.first?.changes.count, pendingItems.count)
    }

    @MainActor
    func testOCRSearchResultCanBeAddedWithItsSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let materialID = UUID()
        let material = MaterialAsset(
            id: materialID,
            displayName: "志愿证明.pdf",
            kind: .pdf,
            pageCount: 1,
            relativePath: "materials/source.pdf"
        )
        let block = OCRBlock(
            text: "志愿服务：社区数字助老活动 36 小时",
            pageIndex: 0,
            boundingBox: NormalizedRect(x: 0, y: 0, width: 1, height: 0.1),
            confidence: 0.93,
            materialID: materialID
        )
        let flow = FlowStore(
            profileStore: PersonalProfileStore(rootURL: root.appending(path: "profile")),
            profileLibraryStore: ProfileLibraryStore(rootURL: root.appending(path: "library"))
        )
        flow.profileLibrary.materials = [material]
        flow.profileLibrary.ocrBlocks = [block]

        flow.addOCRBlockToProfile(block, label: "志愿经历", value: "社区数字助老活动 36 小时")

        let item = try XCTUnwrap(flow.profileLibrary.profileItems?.first)
        XCTAssertEqual(item.value, "社区数字助老活动 36 小时")
        XCTAssertEqual(item.sources.first?.materialName, "志愿证明.pdf")
        XCTAssertEqual(item.sources.first?.id, block.id)
        XCTAssertTrue(item.modifiedByUser)
    }

    @MainActor
    func testSingleAndBatchChangesCanBeUndone() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let flow = FlowStore(
            profileStore: PersonalProfileStore(rootURL: root.appending(path: "profile")),
            profileLibraryStore: ProfileLibraryStore(rootURL: root.appending(path: "library"))
        )
        let previous = ProfileItem(
            category: .education,
            fieldID: "major",
            label: "专业",
            value: "数据科学",
            confidence: 1,
            state: .confirmed,
            modifiedByUser: true
        )
        let current = ProfileItem(
            id: previous.id,
            category: .education,
            fieldID: "major",
            label: "专业",
            value: "数据科学与智能系统",
            confidence: 0.96,
            state: .autoExtracted
        )
        let added = ProfileItem(
            category: .skill,
            fieldID: "skill.swift",
            label: "技能",
            value: "Swift",
            confidence: 0.98,
            state: .autoExtracted
        )
        let replacementChange = ProfileItemChange(
            itemID: previous.id,
            label: "专业",
            previous: previous,
            current: current
        )
        let additionChange = ProfileItemChange(
            itemID: added.id,
            label: "技能",
            previous: nil,
            current: added
        )
        let batch = ProfileChangeBatch(changes: [replacementChange, additionChange])
        flow.profileLibrary.profileItems = [current, added]
        flow.profileLibrary.changeHistory = [batch]

        flow.undoProfileChange(replacementChange, in: batch)
        XCTAssertEqual(flow.profileLibrary.profileItems?.first(where: { $0.id == previous.id })?.value, previous.value)
        XCTAssertEqual(flow.profileLibrary.changeHistory?.first?.changes, [additionChange])

        let remainingBatch = try XCTUnwrap(flow.profileLibrary.changeHistory?.first)
        flow.undoProfileChangeBatch(remainingBatch)
        XCTAssertFalse(flow.profileLibrary.profileItems?.contains(where: { $0.id == added.id }) == true)
        XCTAssertTrue(flow.profileLibrary.changeHistory?.isEmpty == true)
    }
}
