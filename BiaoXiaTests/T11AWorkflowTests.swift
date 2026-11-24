import Foundation
import PDFKit
import SwiftData
import Testing
@testable import BiaoXia

@MainActor
struct T11AWorkflowTests {
    private var demoFormURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TestAssets/SimulatorFiles/blank_competition_registration_form.pdf")
    }

    @Test
    func realPDFEngineAndLocalMatcherCompleteOfflineDebugSample() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        let flow = FlowStore(fileStore: store)
        let subject = ProfileSubject(
            id: UUID(),
            kind: .selfPerson,
            displayName: "林知夏"
        )
        var profile = PersonalProfile.testFixture
        profile.subjects = [subject]
        profile.records = []
        flow.profile = profile

        await flow.createTask(in: context)
        let sampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TestAssets/GeneralForms/debug/normal/F01-pdf.pdf")
        await flow.importForm(from: sampleURL, in: context)

        let fields = try #require(flow.snapshot?.generalForm?.fields)
        #expect(fields.isEmpty == false)
        #expect(flow.snapshot?.checkpoint?.stage == .matched)
        for field in fields {
            switch field.kind {
            case .singleChoice, .multipleChoice:
                if let optionID = field.options.first?.id {
                    flow.updateGeneralFormAnswer(
                        fieldID: field.id,
                        value: "",
                        selectedOptionIDs: [optionID],
                        in: context
                    )
                }
            case .date:
                flow.updateGeneralFormAnswer(
                    fieldID: field.id,
                    value: "2026-09-18",
                    in: context
                )
            case .singleLineText, .multilineText:
                flow.updateGeneralFormAnswer(
                    fieldID: field.id,
                    value: "测试",
                    in: context
                )
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        await flow.export(in: context)

        #expect(flow.snapshot?.status == .completed)
        #expect(await flow.exportFileURL() != nil)
    }

    @Test
    func offlineWorkflowUsesRealTaskStateAndExports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        let flow = FlowStore(
            fileStore: store,
            formParser: T11Parser(),
            answerMatcher: T11Matcher(),
            formWriter: T11Writer()
        )
        flow.profile = .testFixture

        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)

        #expect(flow.snapshot?.status == .reviewing)
        #expect(flow.snapshot?.checkpoint?.stage == .matched)
        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.value == "林知夏")

        flow.updateGeneralFormAnswer(
            fieldID: "name",
            value: "林知夏（确认）",
            in: context
        )
        try await Task.sleep(for: .milliseconds(50))
        await flow.export(in: context)

        #expect(flow.snapshot?.status == .completed)
        #expect(flow.snapshot?.checkpoint?.stage == .exported)
        let exportURL = await flow.exportFileURL()
        #expect(exportURL != nil)
        #expect(FileManager.default.fileExists(atPath: exportURL?.path ?? "") == true)
    }

    @Test
    func interruptedImportedTaskResumesFromSavedCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        var snapshot = FillTaskSnapshot.empty(profile: .testFixture)
        snapshot.form = try await store.importForm(from: demoFormURL, taskID: snapshot.id)
        snapshot.status = .imported
        snapshot.checkpoint = WorkflowCheckpoint(stage: .imported, revision: 1, savedAt: .now)
        try await store.saveSnapshot(snapshot)
        let record = FillTaskRecord(snapshot: snapshot)
        context.insert(record)
        try context.save()

        let flow = FlowStore(
            fileStore: store,
            formParser: T11Parser(),
            answerMatcher: T11Matcher()
        )
        flow.profile = .testFixture
        await flow.open(record, in: context)

        #expect(flow.snapshot?.status == .reviewing)
        #expect(flow.snapshot?.checkpoint?.stage == .matched)
        #expect(flow.snapshot?.generalForm?.fields.count == 1)
    }

    @Test
    func snapshotSaveFailureDoesNotDiscardWorkingTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let underlying = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let store = T11FailingSaveStore(underlying: underlying, failingSaveNumber: 3)
        let context = try makeContext()
        let flow = FlowStore(
            fileStore: store,
            formParser: T11Parser(),
            answerMatcher: T11Matcher()
        )
        flow.profile = .testFixture

        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)

        #expect(flow.snapshot?.status == .reviewing)
        #expect(flow.snapshot?.generalForm?.fields.isEmpty == false)
        // A later successful checkpoint save has persisted the working task.
        #expect(flow.hasUnsavedTaskChanges == false)

        flow.updateGeneralFormAnswer(fieldID: "name", value: "仍可继续", in: context)
        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.value == "仍可继续")
    }

    @Test
    func suggestedRequiredAnswerMustBeConfirmedBeforeExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        let writer = T11RecordingWriter()
        let sourceID = UUID()
        let flow = FlowStore(
            fileStore: store,
            formParser: T11Parser(),
            answerMatcher: T11Matcher(sourceRecordIDs: [sourceID]),
            formWriter: writer,
            formPreflighter: T11ReadyPreflighter()
        )
        flow.profile = .testFixture

        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)
        await flow.export(in: context)
        #expect(await writer.writtenDocument() == nil)
        #expect(flow.snapshot?.status == .failed)

        await flow.confirmSuggestedGeneralFormAnswer(fieldID: "name", in: context)
        let confirmed = try #require(flow.snapshot?.generalForm?.fields.first?.answer)
        #expect(confirmed.confirmationState == .confirmed)
        #expect(confirmed.sourceRecordIDs == [sourceID])
        #expect(confirmed.modifiedByUser == false)

        await flow.export(in: context)
        let written = try #require(await writer.writtenDocument())
        #expect(written.fields.first?.answer?.value == "林知夏")
        #expect(flow.snapshot?.status == .completed)
    }

    @Test
    func invalidSuggestionCannotBeConfirmed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        let flow = FlowStore(
            fileStore: store,
            formParser: T11Parser(),
            answerMatcher: T11Matcher(),
            formPreflighter: T11InvalidPreflighter()
        )
        flow.profile = .testFixture

        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)
        await flow.confirmSuggestedGeneralFormAnswer(fieldID: "name", in: context)

        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.confirmationState == .suggested)
        #expect(flow.transientError?.contains("超过字符上限") == true)
    }

    @Test
    func parsedCheckpointResumesMatchingAndPreservesUserDecision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        var snapshot = FillTaskSnapshot.empty(profile: .testFixture)
        snapshot.form = try await store.importForm(from: demoFormURL, taskID: snapshot.id)
        var document = try await T11Parser().parse(formURL: demoFormURL)
        document.fields[0].answer = PersonalAnswer(
            value: "人工保留值",
            selectedOptionIDs: [],
            sourceRecordIDs: [],
            confirmationState: .confirmed,
            modifiedByUser: true
        )
        snapshot.generalForm = document
        snapshot.status = .imported
        snapshot.checkpoint = WorkflowCheckpoint(stage: .parsed, revision: 2, savedAt: .now)
        try await store.saveSnapshot(snapshot)
        let record = FillTaskRecord(snapshot: snapshot)
        context.insert(record)
        try context.save()

        let flow = FlowStore(fileStore: store, formParser: T11Parser(), answerMatcher: T11Matcher())
        flow.profile = .testFixture
        await flow.open(record, in: context)

        #expect(flow.snapshot?.checkpoint?.stage == .matched)
        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.value == "人工保留值")
        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.modifiedByUser == true)
    }

    @Test
    func matchingFailureRetriesFailedStep() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        let matcher = T11FailOnceMatcher()
        let flow = FlowStore(fileStore: store, formParser: T11Parser(), answerMatcher: matcher)
        flow.profile = .testFixture

        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)
        #expect(flow.snapshot?.status == .failed)
        #expect(flow.snapshot?.checkpoint?.stage == .parsed)

        await flow.retry(in: context)
        #expect(flow.snapshot?.status == .reviewing)
        #expect(flow.snapshot?.checkpoint?.stage == .matched)
        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.value == "重试成功")
    }

    @Test
    func saveFailureCanBeRetriedAndReopenedFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let underlying = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let store = T11FailingSaveStore(underlying: underlying, failingSaveNumber: 5)
        let context = try makeContext()
        let flow = FlowStore(fileStore: store, formParser: T11Parser(), answerMatcher: T11Matcher())
        flow.profile = .testFixture

        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)
        flow.updateGeneralFormAnswer(fieldID: "name", value: "保存后重开", in: context)
        try await Task.sleep(for: .milliseconds(100))
        #expect(flow.transientError?.contains("尚未保存") == true)
        #expect(flow.hasUnsavedTaskChanges)
        flow.transientError = nil // Dismissing the alert must leave the retry action available.
        #expect(flow.hasUnsavedTaskChanges)
        await flow.retrySaving(in: context)
        #expect(!flow.hasUnsavedTaskChanges)

        let saved = try await underlying.loadSnapshot(taskID: try #require(flow.snapshot?.id))
        let reopenedRecord = FillTaskRecord(snapshot: saved)
        let reopened = FlowStore(fileStore: underlying, formParser: T11Parser(), answerMatcher: T11Matcher())
        reopened.profile = .testFixture
        await reopened.open(reopenedRecord, in: try makeContext())
        #expect(reopened.snapshot?.generalForm?.fields.first?.answer?.value == "保存后重开")
        #expect(reopened.snapshot?.checkpoint?.stage == .reviewed)
    }

    @Test
    func realPDFSuggestionConfirmationWritesSuggestedAndAutomaticAnswers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: "T11-PDF-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        let flow = FlowStore(fileStore: store)
        let subject = ProfileSubject(id: UUID(), kind: .selfPerson, displayName: "林知夏")
        let name = profileRecord(subjectID: subject.id, key: "fullName", value: "林知夏", confirmed: false)
        let phone = profileRecord(subjectID: subject.id, kind: .contact, key: "phone", value: "000-0100-0001", confirmed: true)
        flow.profile = .testFixture
        flow.profile.subjects = [subject]
        flow.profile.records = [name, phone]
        let sampleURL = debugPDF("F02")
        let original = try Data(contentsOf: sampleURL)

        await flow.createTask(in: context)
        await flow.importForm(from: sampleURL, in: context)
        let fields = try #require(flow.snapshot?.generalForm?.fields)
        let suggested = try #require(fields.first { $0.label.contains("姓名") })
        let automatic = try #require(fields.first { $0.label.contains("电话") })
        #expect(suggested.answer?.confirmationState == .suggested)
        #expect(suggested.answer?.sourceRecordIDs == [name.id])
        #expect(automatic.answer?.confirmationState == .confirmed)
        #expect(automatic.answer?.sourceRecordIDs == [phone.id])
        // Complete only unrelated fields manually; both target answers come from the real matcher.
        for field in fields where field.id != suggested.id && field.id != automatic.id {
            flow.updateGeneralFormAnswer(fieldID: field.id,
                value: field.kind == .date ? "2026-10-01" : "虚构测试", in: context)
        }
        await flow.retrySaving(in: context)
        await flow.confirmSuggestedGeneralFormAnswer(fieldID: suggested.id, in: context)
        #expect(flow.snapshot?.generalForm?.fields.first { $0.id == suggested.id }?.answer?.sourceRecordIDs == [name.id])
        await flow.export(in: context)
        #expect(flow.snapshot?.status == .completed)

        let outputURL = try #require(await flow.exportFileURL())
        let output = try #require(PDFDocument(url: outputURL))
        let source = try #require(PDFDocument(url: sampleURL))
        #expect(output.pageCount == source.pageCount)
        #expect(try Data(contentsOf: sampleURL) == original)
        for (field, value) in [(suggested, "林知夏"), (automatic, "000-0100-0001")] {
            let anchor = try #require(field.anchors.first)
            let page = try #require(output.page(at: anchor.pageIndex))
            let bounds = page.bounds(for: .mediaBox)
            let region = CGRect(x: anchor.rect.x * bounds.width,
                y: (1 - anchor.rect.y - anchor.rect.height) * bounds.height,
                width: anchor.rect.width * bounds.width, height: anchor.rect.height * bounds.height)
            #expect(page.selection(for: region)?.string?.contains(value) == true)
        }
        for index in 0..<source.pageCount {
            let before = try #require(source.page(at: index))
            let after = try #require(output.page(at: index))
            // Existing labels and instructions must remain in the output.
            for line in (before.string ?? "").split(separator: "\n") {
                #expect(after.string?.contains(String(line)) == true)
            }
            try before.thumbnail(of: CGSize(width: 1190, height: 1684), for: .mediaBox)
                .pngData()?.write(to: root.appending(path: "before-\(index).png"))
            try after.thumbnail(of: CGSize(width: 1190, height: 1684), for: .mediaBox)
                .pngData()?.write(to: root.appending(path: "after-\(index).png"))
        }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "png" {
            Attachment.record(try Data(contentsOf: file), named: file.lastPathComponent)
        }
        Attachment.record(try Data(contentsOf: outputURL), named: "F02-filled.pdf")
        print("T11 PDF render evidence: \(root.path)")
    }

    private func debugPDF(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "TestAssets/GeneralForms/debug/normal/\(name)-pdf.pdf")
    }

    private func profileRecord(subjectID: UUID, kind: ProfileRecordKind = .identity, key: String, value: String, confirmed: Bool) -> ProfileRecord {
        let components = ["fieldID": key, "label": key, "value": value]
        return ProfileRecord(id: UUID(), subjectID: subjectID, kind: kind,
            businessKey: ProfileBusinessKey.make(kind: kind, subjectID: subjectID, components: components),
            displayValue: value, components: components, sources: [],
            confirmedComponentKeys: confirmed ? Set(components.keys) : [], updatedAt: .now)
    }

    @Test
    func parseAndExportFailuresRetryTheirFailedSteps() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let context = try makeContext()
        let parser = T11FailOnceParser()
        let writer = T11FailOnceWriter()
        let flow = FlowStore(
            fileStore: store,
            formParser: parser,
            answerMatcher: T11ConfirmedMatcher(),
            formWriter: writer
        )
        flow.profile = .testFixture

        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)
        #expect(flow.snapshot?.status == .failed)
        #expect(flow.snapshot?.checkpoint?.stage == .imported)
        await flow.retry(in: context)
        #expect(flow.snapshot?.checkpoint?.stage == .matched)

        await flow.export(in: context)
        #expect(flow.snapshot?.status == .failed)
        #expect(flow.snapshot?.checkpoint?.stage == .matched)
        await flow.retry(in: context)
        await flow.export(in: context)
        #expect(flow.snapshot?.status == .completed)
        #expect(await writer.attemptCount() == 2)
    }

    @Test
    func completedOutputSaveFailureRemainsRetryableAfterDismissingAlert() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = TaskFileStore(rootURL: root)
        let store = T11FailingSaveStore(underlying: disk, failingSaveNumber: 6)
        let context = try makeContext()
        let flow = FlowStore(fileStore: store, formParser: T11Parser(),
            answerMatcher: T11ConfirmedMatcher(), formWriter: T11Writer())
        flow.profile = .testFixture
        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)
        await flow.export(in: context)
        #expect(flow.snapshot?.status == .completed)
        #expect(flow.hasUnsavedTaskChanges)
        flow.transientError = nil
        #expect(flow.hasUnsavedTaskChanges)
        let outputURL = try #require(await flow.exportFileURL())
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let id = try #require(flow.snapshot?.id)
        #expect(try await disk.loadSnapshot(taskID: id).status == .exporting)
        await flow.retrySaving(in: context)
        #expect(!flow.hasUnsavedTaskChanges)
        let saved = try await disk.loadSnapshot(taskID: id)
        let reopened = FlowStore(fileStore: disk)
        await reopened.open(FillTaskRecord(snapshot: saved), in: try makeContext())
        #expect(reopened.snapshot?.status == .completed)
        #expect(await reopened.exportFileURL() == outputURL)
        #expect(reopened.snapshot?.generalForm?.fields.first?.answer?.value == "林知夏")
    }

    @Test(arguments: [WorkflowStage.matched, .reviewed])
    func exportInterruptionReopensWithDecisionsAndUsesFreshOutput(stage: WorkflowStage) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = TaskFileStore(rootURL: root)
        var saved = FillTaskSnapshot.empty(profile: .testFixture)
        saved.form = try await disk.importForm(from: demoFormURL, taskID: saved.id)
        var document = try await T11Parser().parse(formURL: demoFormURL)
        let sourceID = UUID()
        document.fields[0].answer = PersonalAnswer(value: "保留人工答案", selectedOptionIDs: [],
            sourceRecordIDs: [sourceID], confirmationState: .confirmed, modifiedByUser: true)
        var blank = document.fields[0]
        blank = DynamicFormField(id: "blank", label: "可选留空", kind: .singleLineText,
            options: [], constraints: FormFieldConstraints(), anchors: [], meaning: blank.meaning,
            answer: PersonalAnswer(value: nil, selectedOptionIDs: [], sourceRecordIDs: [],
                confirmationState: .intentionallyBlank, modifiedByUser: true))
        document.fields.append(blank)
        document.fields.append(DynamicFormField(id: "choice", label: "人工选择", kind: .multipleChoice,
            options: [FormFieldOption(id: "chosen", label: "甲", exportValue: "A")],
            constraints: FormFieldConstraints(), anchors: [], meaning: blank.meaning,
            answer: PersonalAnswer(value: nil, selectedOptionIDs: ["chosen"], sourceRecordIDs: [],
                confirmationState: .confirmed, modifiedByUser: true)))
        saved.generalForm = document
        saved.status = .exporting
        saved.checkpoint = WorkflowCheckpoint(stage: stage, revision: 3, savedAt: .now)
        let partial = try await disk.exportURL(fileName: "interrupted.pdf", taskID: saved.id)
        try Data("partial output".utf8).write(to: partial)
        // An interrupted output must never be treated as a completed result.
        saved.exportRelativePath = "exports/interrupted.pdf"
        try await disk.saveSnapshot(saved)
        let source = try await disk.absoluteURL(for: try #require(saved.form?.relativePath), taskID: saved.id)
        let original = try Data(contentsOf: source)
        let flow = FlowStore(fileStore: disk, formWriter: T11Writer())
        await flow.open(FillTaskRecord(snapshot: saved), in: try makeContext())
        #expect(flow.snapshot?.status == .reviewing)
        #expect(flow.snapshot?.generalForm == document)
        await flow.export(in: try makeContext())
        #expect(flow.snapshot?.status == .completed)
        #expect(await flow.exportFileURL() != partial)
        #expect(try Data(contentsOf: source) == original)
        #expect(flow.snapshot?.generalForm == document)
    }

    @Test(arguments: ["date", "length", "lines", "overflow", "unknownOption", "singleCount", "minimum", "maximum"])
    func realPreflightRejectsInvalidSuggestions(reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = TaskFileStore(rootURL: root)
        var saved = FillTaskSnapshot.empty(profile: .testFixture)
        saved.form = try await disk.importForm(from: debugPDF("F02"), taskID: saved.id)
        var document = try await PDFFormEngine().parse(formURL: debugPDF("F02"))
        var field = try #require(document.fields.first)
        field.answer = PersonalAnswer(value: "测试", selectedOptionIDs: [], sourceRecordIDs: [],
            confirmationState: .suggested, modifiedByUser: false)
        switch reason {
        case "date":
            field.kind = .date
            field.constraints.dateFormat = "yyyy-MM-dd"
            field.answer?.value = "2026-02-30"
        case "length": field.constraints.maximumCharacters = 1
        case "lines":
            field.kind = .multilineText
            field.constraints.maximumLines = 1
            field.answer?.value = "第一行\n第二行"
        case "overflow": field.answer?.value = String(repeating: "溢出", count: 1000)
        default:
            field.kind = reason == "singleCount" ? .singleChoice : .multipleChoice
            field.options = [FormFieldOption(id: "a", label: "甲", exportValue: "A"),
                FormFieldOption(id: "b", label: "乙", exportValue: "B")]
            field.anchors = [field.anchors[0], field.anchors[0]]
            field.answer?.selectedOptionIDs = reason == "unknownOption" ? ["unknown"] : ["a", "b"]
            if reason == "minimum" { field.constraints.minimumSelections = 3 }
            if reason == "maximum" { field.constraints.maximumSelections = 1 }
        }
        document.fields = [field]
        saved.generalForm = document
        saved.status = .reviewing
        saved.checkpoint = WorkflowCheckpoint(stage: .matched, revision: 1, savedAt: .now)
        try await disk.saveSnapshot(saved)
        let flow = FlowStore(fileStore: disk)
        let context = try makeContext()
        await flow.open(FillTaskRecord(snapshot: saved), in: context)
        await flow.confirmSuggestedGeneralFormAnswer(fieldID: field.id, in: context)
        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.confirmationState == .suggested)
        #expect(flow.transientError?.contains("无法确认") == true)
    }

    @Test
    func parsedReopenFailureCanRetryAndThenReopenMatchedAnswers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = TaskFileStore(rootURL: root)
        var saved = FillTaskSnapshot.empty(profile: .testFixture)
        saved.form = try await disk.importForm(from: demoFormURL, taskID: saved.id)
        saved.generalForm = try await T11Parser().parse(formURL: demoFormURL)
        saved.checkpoint = WorkflowCheckpoint(stage: .parsed, revision: 2, savedAt: .now)
        saved.status = .imported
        try await disk.saveSnapshot(saved)
        let flow = FlowStore(fileStore: disk, answerMatcher: T11FailOnceMatcher())
        let context = try makeContext()
        await flow.open(FillTaskRecord(snapshot: saved), in: context)
        #expect(flow.snapshot?.status == .failed)
        #expect(flow.snapshot?.checkpoint?.stage == .parsed)
        await flow.retry(in: context)
        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.value == "重试成功")
        let reopened = FlowStore(fileStore: disk, answerMatcher: T11FailOnceMatcher())
        await reopened.open(FillTaskRecord(snapshot: try await disk.loadSnapshot(taskID: saved.id)), in: try makeContext())
        #expect(reopened.snapshot?.status == .reviewing)
        #expect(reopened.snapshot?.generalForm?.fields.first?.answer?.value == "重试成功")
    }

    @Test
    func optionalSuggestionStaysBlankAndConfirmedCheckboxIsWrittenAtItsAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "T11-Checkbox-\(UUID().uuidString)")
        let disk = TaskFileStore(rootURL: root)
        var saved = FillTaskSnapshot.empty(profile: .testFixture)
        let sourceURL = debugPDF("F01")
        let original = try Data(contentsOf: sourceURL)
        saved.form = try await disk.importForm(from: sourceURL, taskID: saved.id)
        let parsed = try await PDFFormEngine().parse(formURL: sourceURL)
        var choice = try #require(parsed.fields.first { $0.kind == .multipleChoice })
        choice.answer = PersonalAnswer(value: nil, selectedOptionIDs: [try #require(choice.options.first?.id)],
            sourceRecordIDs: [], confirmationState: .suggested, modifiedByUser: false)
        var optional = try #require(parsed.fields.first { $0.kind == .singleLineText })
        optional.constraints.isRequired = false
        optional.answer = PersonalAnswer(value: "不应出现在输出中", selectedOptionIDs: [], sourceRecordIDs: [],
            confirmationState: .suggested, modifiedByUser: false)
        var document = parsed
        document.fields = [choice, optional]
        saved.generalForm = document
        saved.status = .reviewing
        saved.checkpoint = WorkflowCheckpoint(stage: .matched, revision: 1, savedAt: .now)
        try await disk.saveSnapshot(saved)
        let context = try makeContext()
        let flow = FlowStore(fileStore: disk)
        await flow.open(FillTaskRecord(snapshot: saved), in: context)
        await flow.confirmSuggestedGeneralFormAnswer(fieldID: choice.id, in: context)
        await flow.export(in: context, allowPartial: true)
        #expect(flow.snapshot?.status == .completed)
        let outputURL = try #require(await flow.exportFileURL())
        let output = try #require(PDFDocument(url: outputURL))
        let source = try #require(PDFDocument(url: sourceURL))
        let anchor = try #require(choice.anchors.first)
        let page = try #require(output.page(at: anchor.pageIndex))
        let before = try #require(source.page(at: anchor.pageIndex))
        // Output is flattened, so verify visible pixels rather than annotations.
        let beforeImage = try #require(before.thumbnail(of: CGSize(width: 1190, height: 1684), for: .mediaBox).cgImage)
        let afterImage = try #require(page.thumbnail(of: CGSize(width: 1190, height: 1684), for: .mediaBox).cgImage)
        let beforePixels = rgbaPixels(beforeImage)
        let afterPixels = rgbaPixels(afterImage)
        #expect(beforeImage.width == afterImage.width && beforeImage.height == afterImage.height)
        let target = CGRect(x: anchor.rect.x * Double(beforeImage.width),
            y: anchor.rect.y * Double(beforeImage.height),
            width: anchor.rect.width * Double(beforeImage.width),
            height: anchor.rect.height * Double(beforeImage.height)).insetBy(dx: -3, dy: -3)
        var insideChanges = 0
        var outsideChanges = 0
        for y in 0..<beforeImage.height {
            for x in 0..<beforeImage.width {
                let offset = (y * beforeImage.width + x) * 4
                let difference = (0..<3).map { abs(Int(beforePixels[offset + $0]) - Int(afterPixels[offset + $0])) }.max() ?? 0
                guard difference > 60 else { continue }
                if target.contains(CGPoint(x: x, y: y)) { insideChanges += 1 }
                else { outsideChanges += 1 }
            }
        }
        #expect(insideChanges > 10)
        // Permit a small rasterization tolerance, but no shifted mark or altered label.
        #expect(outsideChanges < 20)
        #expect(page.string?.contains("不应出现在输出中") == false)
        for line in (before.string ?? "").split(separator: "\n") {
            #expect(page.string?.contains(String(line)) == true)
        }
        #expect(try Data(contentsOf: sourceURL) == original)
        try before.thumbnail(of: CGSize(width: 1190, height: 1684), for: .mediaBox)
            .pngData()?.write(to: root.appending(path: "before.png"))
        try page.thumbnail(of: CGSize(width: 1190, height: 1684), for: .mediaBox)
            .pngData()?.write(to: root.appending(path: "after.png"))
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "png" {
            Attachment.record(try Data(contentsOf: file), named: "checkbox-" + file.lastPathComponent)
        }
        Attachment.record(try Data(contentsOf: outputURL), named: "F01-checkbox.pdf")
        print("T11 checkbox render evidence: \(root.path)")
    }

    @Test
    func persistentSaveFailureDoesNotClaimSuccessOrLoseWorkingAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = TaskFileStore(rootURL: root)
        let store = T11FailingSaveStore(underlying: disk, failingSaveNumber: 5, failureCount: 2)
        let context = try makeContext()
        let flow = FlowStore(fileStore: store, formParser: T11Parser(), answerMatcher: T11Matcher())
        flow.profile = .testFixture
        await flow.createTask(in: context)
        await flow.importForm(from: demoFormURL, in: context)
        flow.updateGeneralFormAnswer(fieldID: "name", value: "最新未保存答案", in: context)
        try await Task.sleep(for: .milliseconds(100))
        #expect(flow.hasUnsavedTaskChanges)
        flow.transientError = nil
        await flow.retrySaving(in: context)
        #expect(flow.hasUnsavedTaskChanges)
        #expect(flow.snapshot?.generalForm?.fields.first?.answer?.value == "最新未保存答案")
        let id = try #require(flow.snapshot?.id)
        let old = try await disk.loadSnapshot(taskID: id)
        #expect(old.generalForm?.fields.first?.answer?.value != "最新未保存答案")
        await flow.retrySaving(in: context)
        #expect(!flow.hasUnsavedTaskChanges)
        let reopened = FlowStore(fileStore: disk)
        await reopened.open(FillTaskRecord(snapshot: try await disk.loadSnapshot(taskID: id)), in: try makeContext())
        #expect(reopened.snapshot?.generalForm?.fields.first?.answer?.value == "最新未保存答案")
    }

    @Test
    func unsupportedPDFShowsLimitationAndCanBeReplacedWithoutDeletingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = TaskFileStore(rootURL: root)
        let context = try makeContext()
        let flow = FlowStore(fileStore: disk)
        flow.profile = .testFixture
        await flow.createTask(in: context)
        let scanned = debugPDF("F02").deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "boundary/B05.pdf")
        await flow.importForm(from: scanned, in: context)
        #expect(flow.snapshot?.status == .failed)
        #expect(flow.snapshot?.generalForm == nil)
        #expect(flow.snapshot?.lastError?.contains("不支持扫描版") == true)
        let originalURL = try #require(await flow.sourceFormFileURL())
        let original = try Data(contentsOf: originalURL)
        await flow.importForm(from: debugPDF("F02"), in: context)
        #expect(flow.snapshot?.status == .reviewing)
        #expect(flow.snapshot?.generalForm != nil)
        #expect(try Data(contentsOf: originalURL) == original)
        #expect(await flow.sourceFormFileURL() != originalURL)
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FillTaskRecord.self,
            configurations: configuration
        )
        return ModelContext(container)
    }
}

private struct T11Parser: FormParsing {
    func parse(formURL: URL) async throws -> GeneralFormDocument {
        GeneralFormDocument(
            structureVersion: GeneralFormDocument.currentStructureVersion,
            fingerprint: DocumentFingerprint(algorithm: "test", value: "fixture", byteCount: 1),
            fields: [
                DynamicFormField(
                    id: "name",
                    label: "姓名",
                    kind: .singleLineText,
                    options: [],
                    constraints: FormFieldConstraints(isRequired: true),
                    anchors: [],
                    meaning: FieldMeaning(canonicalKey: "fullName", state: .knownLocally)
                )
            ], pdfLayoutVersion: PDFFormEngine.layoutVersion
        )
    }
}

private struct T11Matcher: AnswerMatching {
    var sourceRecordIDs: [UUID] = []

    func match(
        fields: [DynamicFormField],
        subjects: [ProfileSubject],
        records: [ProfileRecord]
    ) async throws -> [String: PersonalAnswer] {
        [
            "name": PersonalAnswer(
                value: "林知夏",
                selectedOptionIDs: [],
                sourceRecordIDs: sourceRecordIDs,
                confirmationState: .suggested,
                modifiedByUser: false
            )
        ]
    }
}

private struct T11ReadyPreflighter: FormPreflighting {
    func preflight(document: GeneralFormDocument, sourceURL: URL) throws -> [PDFFieldLayoutResult] {
        document.fields.compactMap { field in
            guard field.answer?.confirmationState == .confirmed else { return nil }
            return PDFFieldLayoutResult(fieldID: field.id, state: .ready(fontSize: 12))
        }
    }
}

private struct T11InvalidPreflighter: FormPreflighting {
    func preflight(document: GeneralFormDocument, sourceURL: URL) throws -> [PDFFieldLayoutResult] {
        [PDFFieldLayoutResult(fieldID: "name", state: .invalidAnswer("超过字符上限"))]
    }
}

private actor T11RecordingWriter: FormWriting {
    private var document: GeneralFormDocument?

    func write(document: GeneralFormDocument, sourceURL: URL, destinationURL: URL) async throws {
        self.document = document
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func writtenDocument() -> GeneralFormDocument? { document }
}

private actor T11FailOnceMatcher: AnswerMatching {
    private var hasFailed = false

    func match(
        fields: [DynamicFormField],
        subjects: [ProfileSubject],
        records: [ProfileRecord]
    ) async throws -> [String: PersonalAnswer] {
        if !hasFailed {
            hasFailed = true
            throw ModuleFailure.retryable("匹配暂时失败")
        }
        return [
            "name": PersonalAnswer(
                value: "重试成功",
                selectedOptionIDs: [],
                sourceRecordIDs: [],
                confirmationState: .suggested,
                modifiedByUser: false
            )
        ]
    }
}

private actor T11FailOnceParser: FormParsing {
    private var hasFailed = false

    func parse(formURL: URL) async throws -> GeneralFormDocument {
        if !hasFailed {
            hasFailed = true
            throw ModuleFailure.retryable("解析暂时失败")
        }
        return try await T11Parser().parse(formURL: formURL)
    }
}

private struct T11ConfirmedMatcher: AnswerMatching {
    func match(
        fields: [DynamicFormField],
        subjects: [ProfileSubject],
        records: [ProfileRecord]
    ) async throws -> [String: PersonalAnswer] {
        [
            "name": PersonalAnswer(
                value: "林知夏", selectedOptionIDs: [], sourceRecordIDs: [],
                confirmationState: .confirmed, modifiedByUser: false
            )
        ]
    }
}

private actor T11FailOnceWriter: FormWriting {
    private var attempts = 0

    func write(document: GeneralFormDocument, sourceURL: URL, destinationURL: URL) async throws {
        attempts += 1
        if attempts == 1 {
            throw ModuleFailure.retryable("导出暂时失败")
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func attemptCount() -> Int { attempts }
}

private struct T11Writer: FormWriting {
    func write(
        document: GeneralFormDocument,
        sourceURL: URL,
        destinationURL: URL
    ) async throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

private actor T11FailingSaveStore: TaskFileStoring {
    let underlying: TaskFileStore
    let failingSaveNumber: Int
    private var saveCount = 0
    private let failureCount: Int

    init(underlying: TaskFileStore, failingSaveNumber: Int, failureCount: Int = 1) {
        self.underlying = underlying
        self.failingSaveNumber = failingSaveNumber
        self.failureCount = failureCount
    }

    func createTaskDirectory(taskID: UUID) async throws {
        try await underlying.createTaskDirectory(taskID: taskID)
    }

    func saveSnapshot(_ snapshot: FillTaskSnapshot) async throws {
        saveCount += 1
        if (failingSaveNumber..<(failingSaveNumber + failureCount)).contains(saveCount) {
            throw CocoaError(.fileWriteUnknown)
        }
        try await underlying.saveSnapshot(snapshot)
    }

    func loadSnapshot(taskID: UUID) async throws -> FillTaskSnapshot {
        try await underlying.loadSnapshot(taskID: taskID)
    }

    func importForm(from sourceURL: URL, taskID: UUID) async throws -> FormAsset {
        try await underlying.importForm(from: sourceURL, taskID: taskID)
    }

    func importMaterial(from sourceURL: URL, taskID: UUID) async throws -> MaterialAsset {
        try await underlying.importMaterial(from: sourceURL, taskID: taskID)
    }

    func deleteTask(taskID: UUID) async throws {
        try await underlying.deleteTask(taskID: taskID)
    }

    func absoluteURL(for relativePath: String, taskID: UUID) async throws -> URL {
        try await underlying.absoluteURL(for: relativePath, taskID: taskID)
    }

    func exportURL(fileName: String, taskID: UUID) async throws -> URL {
        try await underlying.exportURL(fileName: fileName, taskID: taskID)
    }
}
