import Foundation
import PDFKit
import Testing
import UIKit
@testable import BiaoXia

struct PDFFormEngineTests {
    private let engine = PDFFormEngine()

    @Test func parsesSupportedTextLayerPDFWithoutKnownTemplate() async throws {
        let document = try await engine.parse(formURL: fixture("normal/F02-pdf.pdf"))

        #expect(document.fingerprint.algorithm == "sha256")
        #expect(document.fingerprint.byteCount > 0)
        #expect(document.fields.count >= 7)
        #expect(document.fields.allSatisfy { !$0.label.isEmpty && $0.anchors.count == 1 })
    }

    @Test(
        "Discovers every target in the T02 supported subset",
        arguments: [("normal/F01-pdf.pdf", 12), ("normal/F02-pdf.pdf", 7), ("normal/F07-pdf.pdf", 11), ("normal/F11-pdf.pdf", 9)]
    )
    func discoversSupportedSubset(path: String, minimumCount: Int) async throws {
        let document = try await engine.parse(formURL: fixture(path))
        #expect(document.fields.reduce(0) { $0 + $1.anchors.count } >= minimumCount)
    }

    @Test func visibleRequiredMarkersAndChoiceGroupsArePreserved() async throws {
        let document = try await engine.parse(formURL: fixture("normal/F01-pdf.pdf"))
        #expect(document.fields.count == 8)
        #expect(document.fields.allSatisfy { $0.constraints.isRequired })
        #expect(document.fields.first { $0.id == "widget:f01" }?.label.contains("姓名") == true)
        let single = try #require(document.fields.first { $0.label.contains("最高学历") && $0.kind == .singleChoice })
        #expect(single.options.count == 3)
        #expect(single.constraints.minimumSelections == 1)
        #expect(single.constraints.maximumSelections == 1)
        let multiple = try #require(document.fields.first { $0.kind == .multipleChoice })
        #expect(multiple.options.count == 3)
        #expect(multiple.anchors.count == 3)
    }

    @MainActor
    @Test func nativeRequiredFlagDoesNotNeedAPrintedAsterisk() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Account" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
        let pdf = try #require(PDFDocument(data: data))
        let page = try #require(pdf.page(at: 0))
        let widget = PDFAnnotation(bounds: CGRect(x: 120, y: 220, width: 200, height: 30), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "account"
        widget.setValue(NSNumber(value: 2), forAnnotationKey: .widgetFieldFlags)
        page.addAnnotation(widget)
        let url = FileManager.default.temporaryDirectory.appending(path: "required-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try #require(pdf.write(to: url))
        let parsed = try await engine.parse(formURL: url)
        let field = try #require(parsed.fields.first { $0.id == "widget:account" })
        #expect(!field.label.contains("*"))
        #expect(field.constraints.isRequired)
    }

    @Test func rejectsScannedFormInsteadOfSilentlySkippingIt() async throws {
        do {
            _ = try await engine.parse(formURL: fixture("boundary/B05.pdf"))
            Issue.record("Expected scanned PDF to be rejected")
        } catch let error as PDFFormEngineError {
            #expect(error == .limitation(.scannedOrMixedContent, pageIndex: 0))
        }
    }

    @Test func validatesDatesAndOverflowBeforeWriting() async throws {
        let sourceURL = fixture("normal/F02-pdf.pdf")
        var document = try await engine.parse(formURL: sourceURL)
        var field = try #require(document.fields.first)
        field.kind = .date
        field.constraints.dateFormat = "yyyy-MM-dd"
        field.answer = PersonalAnswer(
            value: "2026-02-30",
            selectedOptionIDs: [],
            sourceRecordIDs: [],
            confirmationState: .confirmed,
            modifiedByUser: true
        )
        document.fields = [field]

        let invalidDate = try engine.preflight(document: document, sourceURL: sourceURL)
        #expect(invalidDate.count == 1)
        guard case .invalidAnswer = invalidDate[0].state else {
            Issue.record("Expected invalid date state")
            return
        }

        document.fields[0].kind = .singleLineText
        document.fields[0].constraints.dateFormat = nil
        document.fields[0].answer?.value = String(repeating: "很长的内容", count: 500)
        let overflow = try engine.preflight(document: document, sourceURL: sourceURL)
        #expect(overflow[0].state == .overflow)
    }

    @Test func writesFreshOutputAndPreservesSource() async throws {
        let sourceURL = fixture("normal/F02-pdf.pdf")
        let original = try Data(contentsOf: sourceURL)
        var document = try await engine.parse(formURL: sourceURL)
        let fieldIndex = try #require(document.fields.indices.first)
        document.fields[fieldIndex].answer = PersonalAnswer(
            value: "虚构测试值",
            selectedOptionIDs: [],
            sourceRecordIDs: [],
            confirmationState: .confirmed,
            modifiedByUser: true
        )
        document.fields = [document.fields[fieldIndex]]
        let outputURL = FileManager.default.temporaryDirectory
            .appending(component: "\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await engine.write(document: document, sourceURL: sourceURL, destinationURL: outputURL)

        #expect(try Data(contentsOf: sourceURL) == original)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let output = try #require(PDFDocument(url: outputURL))
        #expect((output.page(at: 0)?.string ?? "").contains("虚构测试值"))
    }

    @Test func overflowDoesNotPublishPartialOutput() async throws {
        let sourceURL = fixture("normal/F02-pdf.pdf")
        var document = try await engine.parse(formURL: sourceURL)
        let fieldIndex = try #require(document.fields.indices.first)
        document.fields[fieldIndex].answer = PersonalAnswer(
            value: String(repeating: "不允许裁切", count: 500),
            selectedOptionIDs: [], sourceRecordIDs: [],
            confirmationState: .confirmed, modifiedByUser: true
        )
        document.fields = [document.fields[fieldIndex]]
        let outputURL = FileManager.default.temporaryDirectory
            .appending(component: "\(UUID().uuidString).pdf")

        await #expect(throws: PDFFormEngineError.self) {
            try await engine.write(document: document, sourceURL: sourceURL, destinationURL: outputURL)
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test func cancellationIsReportedWithoutPublishingOutput() async throws {
        let sourceURL = fixture("normal/F02-pdf.pdf")
        let document = try await engine.parse(formURL: sourceURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appending(component: "\(UUID().uuidString).pdf")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.write(document: document, sourceURL: sourceURL, destinationURL: outputURL)
        }

        await #expect(throws: ModuleFailure.cancelled) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test func manualRegionAdjustmentIsValidatedAndFingerprintBound() async throws {
        let sourceURL = fixture("normal/F02-pdf.pdf")
        let document = try await engine.parse(formURL: sourceURL)
        let fieldID = try #require(document.fields.first?.id)

        let adjusted = try engine.adjustingRegion(
            fieldID: fieldID,
            to: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.05),
            pageIndex: 0,
            in: document
        )

        #expect(adjusted.fingerprint == document.fingerprint)
        #expect(adjusted.fields.first?.anchors.first?.kind == .manuallyAdjustedRegion)
        #expect(throws: PDFFormEngineError.self) {
            try engine.adjustingRegion(
                fieldID: fieldID,
                to: NormalizedRect(x: 0.9, y: 0.2, width: 0.2, height: 0.05),
                pageIndex: 0,
                in: document
            )
        }
    }

    @Test func everyWriteFailureIsExplainedInChinese() throws {
        let failures: [PDFFormEngineError] = [
            .limitation(.scannedOrMixedContent, pageIndex: 0),
            .invalidAnchor(fieldID: "widget:f01"),
            .invalidAnswer(fieldID: "widget:f01", reason: "日期格式或日期值无效"),
            .overflow(fieldID: "widget:f01"),
            .sourceChanged,
            .destinationMustBeNew,
            .outputVerificationFailed(stage: .burnIn, fieldID: nil),
            .outputVerificationFailed(stage: .flatten, fieldID: nil),
            .outputVerificationFailed(stage: .reopen, fieldID: nil),
            .outputVerificationFailed(stage: .textReadback, fieldID: "widget:f01")
        ]
        for failure in failures {
            let message = failure.localizedDescription
            #expect(!message.isEmpty)
            #expect(!message.contains("PDFFormEngineError"))
            #expect(!message.contains("未能完成操作"))
        }
        #expect(PDFFormEngineError.limitation(.scannedOrMixedContent, pageIndex: 0)
            .localizedDescription.contains("不支持扫描版"))
    }

    @Test(
        "Written text can be verified back out of every supported fixture",
        arguments: [
            "normal/F01-pdf.pdf", "normal/F02-pdf.pdf", "normal/F04-pdf.pdf", "normal/F05-pdf.pdf",
            "normal/F07-pdf.pdf", "normal/F08-pdf.pdf", "normal/F10-pdf.pdf", "normal/F11-pdf.pdf"
        ]
    )
    func writtenTextIsVerifiableInSupportedFixtures(path: String) async throws {
        try await expectVerifiableWrite(sourceURL: fixture(path))
    }

    @Test func writtenTextIsVerifiableInTheDemoRegistrationForm() async throws {
        try await expectVerifiableWrite(sourceURL: simulatorFile("blank_competition_registration_form.pdf"))
    }

    @MainActor
    @Test func acroFormWidgetsAreFlattenedWithoutLosingWrittenText() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("姓名" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
        let pdf = try #require(PDFDocument(data: data))
        let page = try #require(pdf.page(at: 0))
        let widget = PDFAnnotation(bounds: CGRect(x: 120, y: 220, width: 200, height: 30), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "name"
        page.addAnnotation(widget)
        let sourceURL = FileManager.default.temporaryDirectory.appending(path: "widget-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try #require(pdf.write(to: sourceURL))

        try await expectVerifiableWrite(sourceURL: sourceURL)
    }

    @MainActor
    @Test func writtenTextIsVerifiableOnAPageWhoseBoxDoesNotStartAtTheOrigin() async throws {
        let bounds = CGRect(x: 100, y: 50, width: 400, height: 300)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage()
            ("姓名" as NSString).draw(
                at: CGPoint(x: bounds.minX + 20, y: bounds.minY + 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12)]
            )
        }
        let pdf = try #require(PDFDocument(data: data))
        let page = try #require(pdf.page(at: 0))
        #expect(page.bounds(for: .mediaBox).origin != .zero)
        let widget = PDFAnnotation(
            bounds: CGRect(x: bounds.minX + 120, y: bounds.minY + 220, width: 200, height: 30),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.fieldName = "name"
        page.addAnnotation(widget)
        let sourceURL = FileManager.default.temporaryDirectory.appending(path: "offset-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try #require(pdf.write(to: sourceURL))

        try await expectVerifiableWrite(sourceURL: sourceURL)
    }

    @Test func pageTextFallbackCountsWhitespaceInsensitiveOccurrences() {
        // The fallback only accepts a value whose count grew, so a value the blank form already
        // printed cannot make a missing write look successful.
        let before = PDFFormEngine.normalizedText("姓名： 虚构测试值 出生日期：")
        let after = PDFFormEngine.normalizedText("姓名： 虚构测试值 出生日期： 虚构 测试值")
        #expect(PDFFormEngine.occurrences(of: "虚构测试值", in: before) == 1)
        #expect(PDFFormEngine.occurrences(of: "虚构测试值", in: after) == 2)
        #expect(PDFFormEngine.occurrences(of: "虚构测试值", in: PDFFormEngine.normalizedText("无关内容")) == 0)
        #expect(PDFFormEngine.occurrences(of: "", in: after) == 0)
    }

    /// Fills one plain text field with a fictional value and requires the engine to publish an
    /// output it can verify. Field-level rejections (anchor, answer, overflow) are legitimate and
    /// move on to the next candidate; an output verification failure never is, because the engine
    /// itself accepted the form during parsing.
    private func expectVerifiableWrite(sourceURL: URL) async throws {
        let parsed = try await engine.parse(formURL: sourceURL)
        let candidates = parsed.fields.filter { $0.kind == .singleLineText }
        #expect(!candidates.isEmpty, "\(sourceURL.lastPathComponent) has no plain text field to write")

        for candidate in candidates {
            var document = parsed
            document.fields = [candidate]
            document.fields[0].answer = PersonalAnswer(
                value: "虚构测试值",
                selectedOptionIDs: [],
                sourceRecordIDs: [],
                confirmationState: .confirmed,
                modifiedByUser: true
            )
            let outputURL = FileManager.default.temporaryDirectory
                .appending(component: "\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: outputURL) }

            do {
                try await engine.write(document: document, sourceURL: sourceURL, destinationURL: outputURL)
            } catch let error as PDFFormEngineError {
                if case let .outputVerificationFailed(stage, fieldID) = error {
                    Issue.record("\(sourceURL.lastPathComponent) failed output verification at \(stage) (field \(fieldID ?? "-"))")
                    return
                }
                continue
            }
            let output = try #require(PDFDocument(url: outputURL))
            let pageIndex = candidate.anchors.first?.pageIndex ?? 0
            #expect((output.page(at: pageIndex)?.string ?? "").contains("虚构测试值"))
            return
        }
        Issue.record("\(sourceURL.lastPathComponent) rejected every plain text field before writing")
    }

    private func fixture(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TestAssets/GeneralForms/debug/\(relativePath)")
    }

    private func simulatorFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TestAssets/SimulatorFiles/\(name)")
    }
}
