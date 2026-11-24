import Foundation
import XCTest
@testable import BiaoXia

final class T10LocalRuleAnswerMatcherTests: XCTestCase {
    func testMatchesKnownAliasesWithTraceableConfirmedSource() async throws {
        let subject = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let record = makeRecord(
            subjectID: subject.id,
            kind: .education,
            fieldID: "educationLevel",
            label: "学历",
            value: "本科",
            confirmed: true
        )
        let field = makeField(id: "degree", label: "最高学历", canonicalKey: nil)

        let answer = try await LocalRuleAnswerMatcher().match(
            fields: [field],
            subjects: [subject],
            records: [record]
        )[field.id]

        XCTAssertEqual(answer?.value, "本科")
        XCTAssertEqual(answer?.sourceRecordIDs, [record.id])
        XCTAssertEqual(answer?.confirmationState, .confirmed)
        XCTAssertTrue(answer?.reasonsRequiringReview.isEmpty == true)
    }

    func testQualifiedVariantConflictStopsAutomaticMatching() async throws {
        let subject = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let records = [
            makeRecord(subjectID: subject.id, kind: .education, fieldID: "major", label: "专业", value: "数据科学与智能系统", confirmed: true),
            makeRecord(subjectID: subject.id, kind: .education, fieldID: "major", label: "专业", value: "数据科学与智能系统（实验班）", confirmed: true)
        ]
        let field = makeField(id: "major", label: "专业", canonicalKey: "major")

        let answer = try await LocalRuleAnswerMatcher().match(
            fields: [field],
            subjects: [subject],
            records: records
        )[field.id]

        XCTAssertNil(answer?.value)
        XCTAssertEqual(answer?.confirmationState, .unresolved)
        XCTAssertEqual(Set(answer?.sourceRecordIDs ?? []), Set(records.map(\.id)))
        XCTAssertTrue(answer?.reasonsRequiringReview.contains { $0.contains("限定词") } == true)
    }

    func testRelationshipContextSelectsFamilyMemberInsteadOfSelf() async throws {
        let selfSubject = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let father = ProfileSubject(id: UUID(), kind: .familyMember, relationshipToSelf: "父亲", displayName: "林海川")
        let selfPhone = makeRecord(subjectID: selfSubject.id, kind: .contact, fieldID: "phone", label: "电话", value: "13800000001", confirmed: true)
        let fatherPhone = makeRecord(subjectID: father.id, kind: .contact, fieldID: "phone", label: "电话", value: "13800000002", confirmed: true)
        var field = makeField(id: "father-phone", label: "联系电话", canonicalKey: "phone")
        field.section = "父亲信息"

        let answer = try await LocalRuleAnswerMatcher().match(
            fields: [field],
            subjects: [selfSubject, father],
            records: [selfPhone, fatherPhone]
        )[field.id]

        XCTAssertEqual(answer?.value, "13800000002")
        XCTAssertEqual(answer?.sourceRecordIDs, [fatherPhone.id])
    }

    func testInvalidDateAndAmbiguousChoiceRequireReviewWithoutInventingNo() async throws {
        let subject = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let record = makeRecord(subjectID: subject.id, kind: .identity, fieldID: "birthDate", label: "出生日期", value: "2023-02-30", confirmed: true)
        var field = makeField(id: "birth", label: "出生日期", canonicalKey: "birthDate")
        field.kind = .date
        field.constraints.dateFormat = "yyyy-MM-dd"

        let answer = try await LocalRuleAnswerMatcher().match(
            fields: [field],
            subjects: [subject],
            records: [record]
        )[field.id]

        XCTAssertEqual(answer?.confirmationState, .suggested)
        XCTAssertTrue(answer?.reasonsRequiringReview.contains { $0.contains("日期") } == true)

        var choice = makeField(id: "party", label: "是否参加", canonicalKey: "participation")
        choice.kind = .singleChoice
        choice.options = [
            FormFieldOption(id: "yes", label: "是", exportValue: "Y"),
            FormFieldOption(id: "no", label: "否", exportValue: "N")
        ]
        let missing = try await LocalRuleAnswerMatcher().match(
            fields: [choice],
            subjects: [subject],
            records: []
        )[choice.id]
        XCTAssertNil(missing?.value)
        XCTAssertTrue(missing?.selectedOptionIDs.isEmpty == true)
        XCTAssertEqual(missing?.confirmationState, .unresolved)
    }

    func testHighestEducationSchoolUsesAssociatedConfirmedRecord() async throws {
        let subject = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let undergraduate = makeRecord(
            subjectID: subject.id,
            kind: .education,
            components: ["educationLevel": "本科", "school": "云岭未来大学"]
        )
        let master = makeRecord(
            subjectID: subject.id,
            kind: .education,
            components: ["educationLevel": "硕士", "school": "北辰研究院"]
        )
        var field = makeField(id: "highest-school", label: "最高学历毕业院校", canonicalKey: "school")
        field.section = "教育信息"

        let answer = try await LocalRuleAnswerMatcher().match(
            fields: [field],
            subjects: [subject],
            records: [undergraduate, master]
        )[field.id]

        XCTAssertEqual(answer?.value, "北辰研究院")
        XCTAssertEqual(answer?.sourceRecordIDs, [master.id])
        XCTAssertEqual(answer?.confirmationState, .confirmed)
    }

    func testRecoveryPreservesConfirmedManualAnswer() async throws {
        let subject = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let record = makeRecord(subjectID: subject.id, kind: .education, fieldID: "school", label: "学校", value: "新候选大学", confirmed: true)
        var field = makeField(id: "school", label: "学校", canonicalKey: "school")
        field.answer = PersonalAnswer(
            value: "人工确认大学",
            selectedOptionIDs: [],
            sourceRecordIDs: [],
            confirmationState: .confirmed,
            modifiedByUser: true,
            reviewReasons: []
        )

        let answer = try await LocalRuleAnswerMatcher().match(
            fields: [field],
            subjects: [subject],
            records: [record]
        )[field.id]

        XCTAssertEqual(answer?.value, "人工确认大学")
        XCTAssertTrue(answer?.modifiedByUser == true)
    }

    func testSpecificLabelsWinAndAmbiguousAffiliationRequiresReview() async throws {
        let person = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "本名")
        let records = [
            makeRecord(subjectID: person.id, kind: .identity, components: ["fullName": "本名", "englishName": "English Name"]),
            makeRecord(subjectID: person.id, kind: .education, components: ["educationLevel": "硕士", "school": "最高学历学校"]),
            makeRecord(subjectID: person.id, kind: .employment, components: ["employer": "工作单位"])
        ]
        let fields = [makeField(id: "english", label: "英文姓名", canonicalKey: nil),
                      makeField(id: "school", label: "最高学历毕业院校", canonicalKey: nil),
                      makeField(id: "affiliation", label: "所属单位", canonicalKey: nil),
                      makeField(id: "cloudAffiliation", label: "单位 *", canonicalKey: "employer")]
        let result = try await LocalRuleAnswerMatcher().match(fields: fields, subjects: [person], records: records)
        XCTAssertEqual(result["english"]?.value, "English Name")
        XCTAssertEqual(result["school"]?.value, "最高学历学校")
        XCTAssertEqual(result["affiliation"]?.confirmationState, .unresolved)
        XCTAssertEqual(result["cloudAffiliation"]?.confirmationState, .unresolved)
    }

    func testNameIgnoresOtherRecordTypesAndDeduplicatesSameName() async throws {
        let person = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let names = [
            makeRecord(subjectID: person.id, kind: .identity, components: ["name": "林知夏"]),
            makeRecord(subjectID: person.id, kind: .identity, components: ["fullName": "林知夏"])
        ]
        let noise = [ProfileRecordKind.course, .project, .certificate].map {
            makeRecord(subjectID: person.id, kind: $0, components: ["name": "无关名称"])
        }
        let field = makeField(id: "name", label: "姓名", canonicalKey: "fullName")
        let answer = try await LocalRuleAnswerMatcher().match(fields: [field], subjects: [person], records: names + noise)[field.id]
        XCTAssertEqual(answer?.value, "林知夏")
        XCTAssertEqual(answer?.confirmationState, .confirmed)
        XCTAssertEqual(Set(answer?.sourceRecordIDs ?? []), Set(names.map(\.id)))
        XCTAssertEqual(Set(FormRecordMatcher.candidates(field: field, records: names + noise, subjects: [person]).map(\.id)), Set(names.map(\.id)))

        let conflict = makeRecord(subjectID: person.id, kind: .identity, components: ["name": "林海川"])
        let unresolved = try await LocalRuleAnswerMatcher().match(fields: [field], subjects: [person], records: names + [conflict] + noise)[field.id]
        XCTAssertNil(unresolved?.value)
        XCTAssertEqual(unresolved?.confirmationState, .unresolved)
    }

    func testIdentityAndContactFieldsIgnoreComponentsFromOtherCategories() async throws {
        let person = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let cases: [(String, String, ProfileRecordKind, String)] = [
            ("gender", "性别", .identity, "女"),
            ("birthDate", "出生日期", .identity, "2004-09-18"),
            ("phone", "电话", .contact, "13800000001")
        ]
        for (key, label, kind, value) in cases {
            let valid = makeRecord(subjectID: person.id, kind: kind, fieldID: key, label: label, value: value, confirmed: true)
            let unrelated = makeRecord(subjectID: person.id, kind: .project, components: [key: "无关内容"])
            let field = makeField(id: key, label: label, canonicalKey: key)
            let answer = try await LocalRuleAnswerMatcher().match(fields: [field], subjects: [person], records: [valid, unrelated])[field.id]
            XCTAssertEqual(answer?.value, value)
            XCTAssertEqual(answer?.confirmationState, .confirmed)
            XCTAssertEqual(answer?.sourceRecordIDs, [valid.id])
        }
    }

    func testCourseSubfieldsDoNotBecomeCourseNames() async throws {
        let person = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let course = makeRecord(subjectID: person.id, kind: .course, components: ["name": "数据库", "score": "91"])
        for label in ["课程成绩", "课程学分", "证书编号", "项目名称审核意见"] {
            let field = makeField(id: label, label: label, canonicalKey: nil)
            XCTAssertNil(FormRecordMatcher.key(for: field))
            let answer = try await LocalRuleAnswerMatcher().match(fields: [field], subjects: [person], records: [course])[field.id]
            XCTAssertNil(answer?.value)
        }
        let explicit = makeField(id: "score", label: "课程", canonicalKey: "courseScore")
        XCTAssertNil(FormRecordMatcher.key(for: explicit))
    }

    func testExtendedRecordsRespectRelationshipAndKeepMultipleProjectsUnresolved() async throws {
        let person = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "林知夏")
        let father = ProfileSubject(id: UUID(), kind: .familyMember, relationshipToSelf: "父亲", displayName: "林海川")
        let own = makeRecord(subjectID: person.id, kind: .project, components: ["title": "本人项目"])
        let related = makeRecord(subjectID: father.id, kind: .project, components: ["title": "父亲项目"])
        var field = makeField(id: "project", label: "项目名称", canonicalKey: "projectName")
        field.section = "父亲信息"
        let answer = try await LocalRuleAnswerMatcher().match(fields: [field], subjects: [person, father], records: [own, related])[field.id]
        XCTAssertEqual(answer?.value, "父亲项目")
        XCTAssertEqual(FormRecordMatcher.candidates(field: field, records: [own, related], subjects: [person, father]).map(\.id), [related.id])
        let missing = try await LocalRuleAnswerMatcher().match(fields: [field], subjects: [person], records: [own])[field.id]
        XCTAssertNil(missing?.value)
        field.section = nil
        let another = makeRecord(subjectID: person.id, kind: .project, components: ["title": "另一项目"])
        let multiple = try await LocalRuleAnswerMatcher().match(fields: [field], subjects: [person], records: [own, another])[field.id]
        XCTAssertEqual(multiple?.confirmationState, .unresolved)

        let courses = ["数据库", "统计学"].map {
            makeRecord(subjectID: person.id, kind: .course, components: ["name": $0])
        }
        let courseField = makeField(id: "courses", label: "核心课程", canonicalKey: "coreCourses")
        let courseAnswer = try await LocalRuleAnswerMatcher().match(fields: [courseField], subjects: [person], records: courses + [own])[courseField.id]
        XCTAssertEqual(courseAnswer?.confirmationState, .unresolved)
        XCTAssertEqual(Set(courseAnswer?.sourceRecordIDs ?? []), Set(courses.map(\.id)))
    }

    private func makeField(id: String, label: String, canonicalKey: String?) -> DynamicFormField {
        DynamicFormField(
            id: id,
            label: label,
            section: nil,
            instructions: nil,
            kind: .singleLineText,
            options: [],
            constraints: FormFieldConstraints(),
            anchors: [],
            meaning: FieldMeaning(
                canonicalKey: canonicalKey,
                summary: nil,
                state: canonicalKey == nil ? .knownLocally : .explained
            ),
            answer: nil
        )
    }

    private func makeRecord(
        subjectID: UUID,
        kind: ProfileRecordKind,
        components: [String: String]
    ) -> ProfileRecord {
        ProfileRecord(
            id: UUID(),
            subjectID: subjectID,
            kind: kind,
            businessKey: ProfileBusinessKey.make(kind: kind, subjectID: subjectID, components: components),
            displayValue: components["value"] ?? components["school"] ?? "",
            components: components,
            sources: [],
            confirmedComponentKeys: Set(components.keys),
            updatedAt: .now
        )
    }

    private func makeRecord(
        subjectID: UUID,
        kind: ProfileRecordKind,
        fieldID: String,
        label: String,
        value: String,
        confirmed: Bool
    ) -> ProfileRecord {
        let components = ["fieldID": fieldID, "label": label, "value": value]
        return ProfileRecord(
            id: UUID(),
            subjectID: subjectID,
            kind: kind,
            businessKey: ProfileBusinessKey.make(kind: kind, subjectID: subjectID, components: components),
            displayValue: value,
            components: components,
            sources: [],
            confirmedComponentKeys: confirmed ? Set(components.keys) : [],
            updatedAt: .now
        )
    }
}
