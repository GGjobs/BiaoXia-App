import XCTest
@testable import BiaoXia

final class FieldExtractionTests: XCTestCase {
    func testFixtureLikeBlocksExtractAllTenFields() {
        let materialID = UUID()
        let values: [(FieldKey, String)] = [
            (.fullName, "林知夏"),
            (.gender, "女"),
            (.birthDate, "2004年9月18日"),
            (.school, "云岭未来大学"),
            (.college, "智能工程学院"),
            (.major, "数据科学与智能系统"),
            (.studentID, "2023AI0427"),
            (.phone, "13800004271"),
            (.email, "lin.zhixia@example.test"),
            (.address, "云岭市新知区星河路88号7栋302室")
        ]
        let blocks = values.enumerated().map { index, pair in
            OCRBlock(
                text: "\(pair.0.label)：\(pair.1)",
                pageIndex: 0,
                boundingBox: NormalizedRect(
                    x: 0.1,
                    y: Double(index) * 0.08,
                    width: 0.8,
                    height: 0.04
                ),
                confidence: 0.99,
                materialID: materialID
            )
        }

        let result = RuleBasedFieldExtractor().extract(from: blocks)
        let extracted = Dictionary(
            uniqueKeysWithValues: result.resolved.map { ($0.key, $0.value) }
        )

        XCTAssertEqual(extracted[.fullName], "林知夏")
        XCTAssertEqual(extracted[.birthDate], "2004-09-18")
        XCTAssertEqual(extracted[.email], "lin.zhixia@example.test")
        XCTAssertEqual(extracted.filter { !$0.value.isEmpty }.count, 10)
        XCTAssertTrue(result.resolved.allSatisfy { $0.confidence >= 0.85 })
    }

    func testCandidatesNeverContainValuesAbsentFromOCR() {
        let block = OCRBlock(
            text: "学校：云岭未来大学",
            pageIndex: 0,
            boundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.7, height: 0.05),
            confidence: 0.95,
            materialID: UUID()
        )
        let result = RuleBasedFieldExtractor().extract(from: [block])
        XCTAssertTrue(result.candidates.allSatisfy { candidate in
            block.text.contains(candidate.value)
        })
    }

    func testSameLineValueBeatsLaterLabelAndDisclaimerText() {
        let materialID = UUID()
        let blocks = [
            block("学校：", x: 0.09, y: 0.20, materialID: materialID),
            block("云岭未来大学", x: 0.23, y: 0.20, materialID: materialID),
            block("学院：", x: 0.09, y: 0.25, materialID: materialID),
            block("地址：", x: 0.09, y: 0.30, materialID: materialID),
            block(
                "云岭市新知区星河路88号7栋302室",
                x: 0.23,
                y: 0.30,
                materialID: materialID
            ),
            block(
                "说明：本页所有身份、机构、地址和联系方式均为虚构。",
                x: 0.09,
                y: 0.90,
                materialID: materialID
            )
        ]

        let result = RuleBasedFieldExtractor().extract(from: blocks)
        let values = Dictionary(
            uniqueKeysWithValues: result.resolved.map { ($0.key, $0.value) }
        )
        XCTAssertEqual(values[.school], "云岭未来大学")
        XCTAssertEqual(values[.address], "云岭市新知区星河路88号7栋302室")
    }

    func testPreparedMajorConflictFallsWithinAIConsentThreshold() {
        let resume = UUID()
        let card = UUID()
        let transcript = UUID()
        let blocks = [
            block("专业：数据科学与智能系统", x: 0.1, y: 0.1, materialID: resume),
            block("专业：数据科学与智能系统", x: 0.1, y: 0.1, materialID: card),
            block("专业：数据科学与智能系统（实验班）", x: 0.1, y: 0.1, materialID: transcript)
        ]

        let candidates = RuleBasedFieldExtractor().extract(from: blocks).candidates
            .filter { $0.fieldKey == .major }
            .sorted { $0.score > $1.score }

        XCTAssertEqual(candidates.count, 2)
        XCTAssertLessThan(candidates[0].score - candidates[1].score, 0.10)
        XCTAssertEqual(candidates[0].value, "数据科学与智能系统")
    }

    private func block(
        _ text: String,
        x: Double,
        y: Double,
        materialID: UUID
    ) -> OCRBlock {
        OCRBlock(
            text: text,
            pageIndex: 0,
            boundingBox: NormalizedRect(x: x, y: y, width: 0.2, height: 0.02),
            confidence: 1,
            materialID: materialID
        )
    }
}
