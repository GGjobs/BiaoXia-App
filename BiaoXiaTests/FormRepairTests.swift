import Foundation
import PDFKit
import SwiftData
import Testing
@testable import BiaoXia

@MainActor
@Suite(.serialized)
struct FormRepairTests {
    private var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private var demoURL: URL { repository.appending(path: "TestAssets/SimulatorFiles/blank_competition_registration_form.pdf") }

    @Test func demoFindsAllTwentyTwoAnswerCellsOutsideLabels() async throws {
        let engine = PDFFormEngine()
        let document = try await engine.parse(formURL: demoURL)
        let expected = ["姓名", "性别", "出生日期", "学校", "学院", "专业", "学号", "报名赛道", "参赛角色", "项目名称", "项目简介",
                        "手机", "邮箱", "通讯地址", "来源说明", "申请人签名", "日期", "技能", "证书", "获奖", "核心课程", "经历摘要"]
        let textFields = document.fields.filter { $0.options.isEmpty }
        #expect(textFields.count == expected.count)
        #expect(Set(textFields.map(\.label)) == Set(expected))
        #expect(document.fields.filter { !$0.options.isEmpty }.count == 3)
        #expect(document.pdfLayoutVersion == PDFFormEngine.layoutVersion)
        for field in textFields {
            let label = try #require(field.labelAnchor)
            let answer = try #require(field.anchors.first)
            #expect(answer.rect.x >= label.rect.x + label.rect.width)
            #expect(answer.rect.width > 0.15)
        }
    }

    @Test func manualAnswersExportInsideActualAnswerCells() async throws {
        let engine = PDFFormEngine()
        var document = try await engine.parse(formURL: demoURL)
        for index in document.fields.indices {
            let field = document.fields[index]
            document.fields[index].answer = PersonalAnswer(value: field.options.isEmpty ? (field.kind == .date ? "2026-09-22" : "虚构测试内容") : nil,
                selectedOptionIDs: field.options.map(\.id), sourceRecordIDs: [], confirmationState: .confirmed, modifiedByUser: true)
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "repair-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let original = try Data(contentsOf: demoURL)
        let preflight = try engine.preflight(document: document, sourceURL: demoURL)
        for result in preflight { if case .ready = result.state {} else { Issue.record("Unexpected preflight: \(result.fieldID) \(result.state)") } }
        try await engine.write(document: document, sourceURL: demoURL, destinationURL: output)
        #expect(try Data(contentsOf: demoURL) == original)
        let pdf = try #require(PDFDocument(url: output))
        for field in document.fields where field.options.isEmpty {
            let anchor = try #require(field.anchors.first)
            let page = try #require(pdf.page(at: anchor.pageIndex))
            let region = PDFFormEngine.pdfBounds(from: anchor.rect, pageBounds: page.bounds(for: .mediaBox))
            let text = (page.selection(for: region)?.string ?? "").precomposedStringWithCompatibilityMapping
            #expect(text.contains(field.answer!.value!))
            let label = try #require(field.labelAnchor)
            let labelText = page.selection(for: PDFFormEngine.pdfBounds(from: label.rect, pageBounds: page.bounds(for: .mediaBox)))?.string ?? ""
            #expect(!labelText.contains("虚构测试内容"))
        }
        // Optional artifact capture uses only generated fictional answers.
        let directory = ProcessInfo.processInfo.environment["BIAOXIA_REPAIR_EVIDENCE_DIR"] ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "RepairEvidence").path
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try Data(contentsOf: output).write(to: URL(fileURLWithPath: directory).appending(path: "repaired-demo.pdf"))
        }
    }

    @Test func rejectsMovingAnAnswerIntoItsLabel() async throws {
        let engine = PDFFormEngine()
        var document = try await engine.parse(formURL: demoURL)
        let index = try #require(document.fields.firstIndex { $0.label == "证书" })
        let label = try #require(document.fields[index].labelAnchor)
        document.fields[index].anchors = [label]
        document.fields[index].answer = PersonalAnswer(value: "虚构内容", selectedOptionIDs: [], sourceRecordIDs: [], confirmationState: .confirmed, modifiedByUser: true)
        #expect(try engine.preflight(document: document, sourceURL: demoURL).first?.state == .needsAnchorReview)
    }

    @Test func multipleAwardsRemainChoicesAndDoNotIncludeOtherExperiences() async throws {
        let me = ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "虚构本人")
        let records = ["award", "award", "campus"].enumerated().map { i, type in
            ProfileRecord(id: UUID(), subjectID: me.id, kind: .experience, businessKey: "\(i)", displayValue: "虚构\(i)", components: ["fieldID": type, "value": "虚构\(i)"], sources: [], confirmedComponentKeys: ["value"], updatedAt: .now)
        }
        let field = DynamicFormField(id: "award", label: "获奖", kind: .multilineText, options: [], constraints: FormFieldConstraints(), anchors: [], meaning: FieldMeaning(state: .needsReview))
        let candidates = FormRecordMatcher.candidates(field: field, records: records, subjects: [me])
        #expect(candidates.count == 2)
        let answers = try await LocalRuleAnswerMatcher().match(fields: [field], subjects: [me], records: records)
        #expect(answers[field.id]?.confirmationState == .unresolved)
    }

    @Test func draftCannotOverwriteManualEditAndCanBeAdoptedAfterReview() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: FillTaskRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let flow = FlowStore(fileStore: TaskFileStore(rootURL: root), answerComposer: RepairComposer())
        flow.profile = .testFixture
        await flow.createTask(in: container.mainContext)
        await flow.importForm(from: demoURL, in: container.mainContext)
        let id = try #require(flow.snapshot?.generalForm?.fields.first { $0.label == "项目简介" }?.id)
        let index = try #require(flow.snapshot?.generalForm?.fields.firstIndex { $0.id == id })
        let initial = flow.snapshot?.generalForm?.fields[index].answer
        let item = ProfileItem(category: .project, fieldID: "projectSummary", label: "项目简介", value: "虚构资料",
            confidence: 1, state: .confirmed)
        flow.profile.items = [item]
        flow.profileLibrary.profileItems = [item]
        let entries = ProfileAISharing.entries(items: [item], subjects: flow.availableSubjects, records: flow.availableRecords)
        flow.profileLibrary.aiSharingGrants = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.fingerprint) })
        await flow.prepareAnswerComposition(fieldID: id, in: container.mainContext)
        await flow.submitAnswerComposition(fieldID: id, in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.fields[index].answer == initial)
        flow.updateGeneralFormAnswer(fieldID: id, value: "新的手填", in: container.mainContext)
        await flow.adoptComposition(fieldID: id, in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.fields[index].answer?.value == "新的手填")
        flow.snapshot?.generalForm?.fields[index].answer = initial
        await flow.adoptComposition(fieldID: id, in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.fields[index].answer?.value == "整理后的虚构资料")
        #expect(flow.snapshot?.generalForm?.fields[index].answer?.confirmationState == .confirmed)
        await flow.reparseCurrentForm(in: container.mainContext)
        #expect(flow.snapshot?.generalForm?.retainedAnswers?.contains { $0.answer.value == "整理后的虚构资料" } == true)
        #expect(flow.snapshot?.generalForm?.fields.first { $0.label == "项目简介" }?.answer == nil)
    }

    @Test func partialExportRequiresExplicitAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: FillTaskRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let flow = FlowStore(fileStore: TaskFileStore(rootURL: root))
        flow.profile = .testFixture
        await flow.createTask(in: container.mainContext)
        await flow.importForm(from: demoURL, in: container.mainContext)
        await flow.export(in: container.mainContext)
        #expect(flow.snapshot?.status != .completed)
        await flow.export(in: container.mainContext, allowPartial: true)
        #expect(flow.snapshot?.status == .completed)
        #expect(flow.snapshot?.exportSummary?.isPartial == true)
    }
}

private struct RepairComposer: AnswerComposing {
    func compose(_ request: AnswerCompositionRequest) async throws -> AnswerCompositionResponse {
        .init(schemaVersion: 1, requestId: request.requestId, answer: "整理后的虚构资料", sourceIDs: ["source-1"], missingInformation: [])
    }
}
