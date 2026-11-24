import XCTest
@testable import BiaoXia

final class PrivacyRedactorTests: XCTestCase {
    func testRemovesEveryLocalOnlySensitiveField() {
        let resolved: [ResolvedField] = [
            field(.fullName, "林知夏"),
            field(.birthDate, "2004-09-18"),
            field(.studentID, "2023AI0427"),
            field(.phone, "13800004271"),
            field(.email, "lin.zhixia@example.test"),
            field(.address, "云岭市新知区星河路88号7栋302室"),
            field(.school, "云岭未来大学")
        ]
        let input = "林知夏 2004-09-18 2023AI0427 13800004271 lin.zhixia@example.test 云岭市新知区星河路88号7栋302室 学校：云岭未来大学"
        let output = PrivacyRedactor().redact(input, resolvedFields: resolved)

        for secret in [
            "林知夏",
            "2004-09-18",
            "2023AI0427",
            "13800004271",
            "lin.zhixia@example.test",
            "云岭市新知区星河路88号7栋302室"
        ] {
            XCTAssertFalse(output.contains(secret))
        }
        XCTAssertTrue(output.contains("云岭未来大学"))
        XCTAssertLessThanOrEqual(output.count, 120)
    }

    func testRedactsChineseIdentityCardEvenWhenNotPreviouslyExtracted() {
        let output = PrivacyRedactor().redact(
            "证件号码：11010120040918321X，学校：云岭未来大学",
            resolvedFields: []
        )
        XCTAssertFalse(output.contains("11010120040918321X"))
        XCTAssertTrue(output.contains("云岭未来大学"))
    }

    func testTokenizationCanRehydrateLocallyWithoutSendingSensitiveValue() {
        let tokenized = PrivacyRedactor().tokenize(
            "姓名：林知夏，手机：13800004271，技能：Swift",
            resolvedFields: [field(.fullName, "林知夏"), field(.phone, "13800004271")]
        )
        XCTAssertFalse(tokenized.text.contains("林知夏"))
        XCTAssertFalse(tokenized.text.contains("13800004271"))
        XCTAssertTrue(tokenized.text.contains("技能：Swift"))
        let nameToken = try! XCTUnwrap(tokenized.replacements.first(where: { $0.value == "林知夏" })?.key)
        XCTAssertEqual(tokenized.rehydrate(nameToken), "林知夏")
    }

    private func field(_ key: FieldKey, _ value: String) -> ResolvedField {
        return ResolvedField(
            key: key,
            value: value,
            candidateID: nil,
            confidence: 1,
            sourceBlockIDs: [],
            resolvedByAI: false,
            modifiedByUser: false
        )
    }
}
