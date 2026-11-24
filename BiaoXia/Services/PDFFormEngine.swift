import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import UIKit

/// The pre-publish self check that rejected a write. Reported separately so a failure can be told
/// apart from the others without re-running the write.
enum PDFOutputVerificationStage: String, Equatable, Sendable {
    case burnIn
    case flatten
    case reopen
    case textReadback
}

enum PDFFormEngineError: Error, Equatable, Sendable {
    case limitation(PDFFormLimitation, pageIndex: Int?)
    case invalidAnchor(fieldID: String)
    case invalidAnswer(fieldID: String, reason: String)
    case overflow(fieldID: String)
    case sourceChanged
    case destinationMustBeNew
    case outputVerificationFailed(stage: PDFOutputVerificationStage, fieldID: String?)
}

extension PDFFormEngineError: LocalizedError {
    /// The field a failure points at, so callers can name it for the user.
    var fieldID: String? {
        switch self {
        case .invalidAnchor(let id), .invalidAnswer(let id, _), .overflow(let id):
            return id
        case .outputVerificationFailed(_, let id):
            return id
        case .limitation, .sourceChanged, .destinationMustBeNew:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .limitation(let reason, _):
            let detail: String
            switch reason {
            case .encryptedOrProtected: detail = "不支持加密或受保护的 PDF"
            case .scannedOrMixedContent: detail = "不支持扫描版或包含扫描填写区域的 PDF"
            case .rotatedPage: detail = "暂不支持旋转页面"
            case .unsupportedStructure: detail = "暂不支持此 PDF 的版式结构"
            case .noSupportedFields: detail = "没有找到可可靠填写的字段"
            }
            return detail + "，请更换文字 PDF。原文件已保留。"
        case .invalidAnchor:
            return "填写位置需要修正：该位置与其他内容重叠或超出页面，请在核对页重新框选后再导出。"
        case .invalidAnswer(_, let reason):
            return "答案无法写入：\(reason)。请在核对页修改后再导出。"
        case .overflow:
            return "内容超出填写区域，请精简内容或在核对页放大填写位置后再导出。"
        case .sourceChanged:
            return "原表格文件已发生变化，请重新导入表格后再导出。已导入材料不受影响。"
        case .destinationMustBeNew:
            return "导出文件已存在，为避免覆盖已放弃本次导出，请重试导出。"
        case .outputVerificationFailed(let stage, _):
            let detail: String
            switch stage {
            case .burnIn: detail = "写入后的 PDF 未能生成"
            case .flatten: detail = "表单域展平失败"
            case .reopen: detail = "写入后的 PDF 无法重新打开"
            case .textReadback: detail = "写入的内容未能在输出文件中复核到"
            }
            return detail + "，已放弃发布，原文件未被修改。可在核对页调整填写位置后重试。"
        }
    }
}

/// Conservative PDF form parser/writer for text-layer PDFs. It never uses OCR for a form.
/// Every write is preflighted before a fresh output file is atomically published.
struct PDFFormEngine: FormParsing, FormWriting, FormPreflighting, PDFRegionAdjusting {
    static let layoutVersion = 2
    private static let minimumFontSize: CGFloat = 8
    private static let preferredFontSize: CGFloat = 12

    func parse(formURL: URL) async throws -> GeneralFormDocument {
        try checkCancellation()
        let data = try Data(contentsOf: formURL)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ModuleFailure.blocked("PDF 无法读取或没有页面")
        }
        guard !document.isEncrypted, !document.isLocked,
              document.allowsCommenting || document.allowsFormFieldEntry || document.allowsDocumentChanges else {
            throw PDFFormEngineError.limitation(.encryptedOrProtected, pageIndex: nil)
        }

        var fields: [DynamicFormField] = []
        var diagnostics: [FormDiagnostic] = []
        for pageIndex in 0..<document.pageCount {
            try checkCancellation()
            guard let page = document.page(at: pageIndex) else {
                throw PDFFormEngineError.limitation(.unsupportedStructure, pageIndex: pageIndex)
            }
            guard page.rotation == 0 else {
                throw PDFFormEngineError.limitation(.rotatedPage, pageIndex: pageIndex)
            }
            let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pageText.isEmpty else {
                throw PDFFormEngineError.limitation(.scannedOrMixedContent, pageIndex: pageIndex)
            }
            let vectors = try PDFPageVectorScanner.scan(page)
            guard !vectors.hasExternalObject else {
                throw PDFFormEngineError.limitation(.scannedOrMixedContent, pageIndex: pageIndex)
            }
            guard !vectors.hasUnsupportedTransform else {
                throw PDFFormEngineError.limitation(.unsupportedStructure, pageIndex: pageIndex)
            }
            fields += widgetFields(on: page, pageIndex: pageIndex)
            let printed = printedFields(on: page, pageIndex: pageIndex, vectors: vectors)
            fields += printed
            let pageFields = fields.filter { $0.anchors.first?.pageIndex == pageIndex }
            if pageFields.isEmpty {
                diagnostics.append(FormDiagnostic(id: "page-\(pageIndex)", pageIndex: pageIndex, message: "本页未识别出可填写字段，请对照原表检查。"))
            }
            for (index, box) in vectors.rectangles.enumerated() where box.width >= 60 && box.height >= 24 {
                let hasText = !(page.selection(for: box.insetBy(dx: 3, dy: 3))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let used = pageFields.contains { field in
                    (field.anchors + [field.labelAnchor].compactMap { $0 }).contains {
                        Self.pdfBounds(from: $0.rect, pageBounds: page.bounds(for: .mediaBox)).intersects(box.insetBy(dx: 3, dy: 3))
                    }
                }
                if !hasText && !used {
                    diagnostics.append(FormDiagnostic(id: "region-\(pageIndex)-\(index)", pageIndex: pageIndex, message: "发现未关联字段的空白区域，请检查是否需要补填。"))
                }
            }
        }
        guard !fields.isEmpty else {
            throw PDFFormEngineError.limitation(.noSupportedFields, pageIndex: nil)
        }
        return GeneralFormDocument(
            structureVersion: GeneralFormDocument.currentStructureVersion,
            fingerprint: fingerprint(data),
            fields: uniqued(fields), pdfLayoutVersion: Self.layoutVersion, diagnostics: diagnostics
        )
    }

    func preflight(document: GeneralFormDocument, sourceURL: URL) throws -> [PDFFieldLayoutResult] {
        let sourceData = try Data(contentsOf: sourceURL)
        guard fingerprint(sourceData) == document.fingerprint else {
            throw PDFFormEngineError.sourceChanged
        }
        guard let pdf = PDFDocument(data: sourceData) else {
            throw ModuleFailure.blocked("PDF 无法重新打开")
        }
        return document.fields.compactMap { field in
            guard let answer = field.answer,
                  answer.confirmationState == .confirmed else { return nil }
            do {
                try validatePlacement(field: field, document: document, pdf: pdf)
                let size = try preparedValues(for: field, answer: answer, pdf: pdf).first?.fontSize ?? 0
                return PDFFieldLayoutResult(fieldID: field.id, state: .ready(fontSize: Double(size)))
            } catch PDFFormEngineError.invalidAnchor {
                return PDFFieldLayoutResult(fieldID: field.id, state: .needsAnchorReview)
            } catch PDFFormEngineError.overflow {
                return PDFFieldLayoutResult(fieldID: field.id, state: .overflow)
            } catch PDFFormEngineError.invalidAnswer(_, let reason) {
                return PDFFieldLayoutResult(fieldID: field.id, state: .invalidAnswer(reason))
            } catch {
                return PDFFieldLayoutResult(fieldID: field.id, state: .invalidAnswer("无法预检"))
            }
        }
    }

    func write(document: GeneralFormDocument, sourceURL: URL, destinationURL: URL) async throws {
        try checkCancellation()
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source != destination, !FileManager.default.fileExists(atPath: destination.path) else {
            throw PDFFormEngineError.destinationMustBeNew
        }
        let sourceData = try Data(contentsOf: sourceURL)
        guard fingerprint(sourceData) == document.fingerprint else {
            throw PDFFormEngineError.sourceChanged
        }
        guard let pdf = PDFDocument(data: sourceData) else {
            throw ModuleFailure.blocked("PDF 无法重新打开")
        }

        let prepared = try document.fields.flatMap { field -> [PreparedWrite] in
            guard let answer = field.answer,
                  answer.confirmationState == .confirmed else { return [] }
            try validatePlacement(field: field, document: document, pdf: pdf)
            return try preparedValues(for: field, answer: answer, pdf: pdf)
        }
        // Captured before any annotation is added so post-write verification can tell our own text
        // apart from text the blank form already contained.
        let sourcePageText = (0..<pdf.pageCount).map { Self.normalizedText(pdf.page(at: $0)?.string ?? "") }
        for item in prepared {
            try checkCancellation()
            guard let page = pdf.page(at: item.anchor.pageIndex) else {
                throw PDFFormEngineError.invalidAnchor(fieldID: item.field.id)
            }
            let bounds = Self.pdfBounds(from: item.anchor.rect, pageBounds: page.bounds(for: .mediaBox))
            switch item.field.kind {
            case .singleChoice, .multipleChoice:
                addCross(to: page, bounds: bounds)
            case .singleLineText, .multilineText, .date:
                let annotation = PDFAnnotation(
                    bounds: bounds.insetBy(dx: 3, dy: 2),
                    forType: .freeText,
                    withProperties: nil
                )
                annotation.contents = item.text
                annotation.font = UIFont.systemFont(ofSize: item.fontSize)
                annotation.fontColor = .black
                annotation.color = .clear
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
                page.addAnnotation(annotation)
            }
        }

        let directory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appending(component: ".\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard pdf.write(to: temporaryURL, withOptions: [.burnInAnnotationsOption: true]),
              let output = PDFDocument(url: temporaryURL),
              output.pageCount == pdf.pageCount else {
            throw PDFFormEngineError.outputVerificationFailed(stage: .burnIn, fieldID: nil)
        }
        // PDFKit's burn-in removes page widgets but can retain their stale root
        // AcroForm tree. Publish a clean document of the burned pages so readers
        // cannot retrieve obsolete values that disagree with the visible output.
        if (0..<pdf.pageCount).contains(where: { index in
            pdf.page(at: index)?.annotations.contains(where: { $0.type == "Widget" }) == true
        }) {
            let flattened = PDFDocument()
            flattened.documentAttributes = output.documentAttributes
            flattened.outlineRoot = output.outlineRoot
            for index in 0..<output.pageCount {
                guard let page = output.page(at: index)?.copy() as? PDFPage else {
                    throw PDFFormEngineError.outputVerificationFailed(stage: .flatten, fieldID: nil)
                }
                flattened.insert(page, at: index)
            }
            guard flattened.write(to: temporaryURL),
                  PDFDocument(url: temporaryURL)?.pageCount == output.pageCount else {
                throw PDFFormEngineError.outputVerificationFailed(stage: .flatten, fieldID: nil)
            }
        }
        guard let verified = PDFDocument(url: temporaryURL) else {
            throw PDFFormEngineError.outputVerificationFailed(stage: .reopen, fieldID: nil)
        }
        try verifyWrittenText(prepared, in: verified, sourcePageText: sourcePageText)
        try checkCancellation()
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    /// Confirms every written value survived into the published file. The anchor region is the
    /// primary evidence because it also proves placement, but burn-in can shift glyph boxes just
    /// outside the anchor or drop the region mapping altogether, so a value that is missing there
    /// is re-checked against the page text: it must now occur more often than it did in the source.
    private func verifyWrittenText(
        _ prepared: [PreparedWrite],
        in verified: PDFDocument,
        sourcePageText: [String]
    ) throws {
        let textWrites = prepared.filter { !$0.text.isEmpty }
        var unverified: [PreparedWrite] = []
        for item in textWrites {
            guard let page = verified.page(at: item.anchor.pageIndex) else {
                throw PDFFormEngineError.outputVerificationFailed(stage: .textReadback, fieldID: item.field.id)
            }
            let pageBounds = page.bounds(for: .mediaBox)
            let region = Self.pdfBounds(from: item.anchor.rect, pageBounds: pageBounds)
            let tolerance = max(item.fontSize, Self.minimumFontSize)
            let widened = region.insetBy(dx: -tolerance, dy: -tolerance).intersection(pageBounds)
            let matched = [region, widened].contains { rect in
                Self.normalizedText(page.selection(for: rect)?.string ?? "").contains(Self.normalizedText(item.text))
            }
            if !matched { unverified.append(item) }
        }
        guard !unverified.isEmpty else { return }

        let writeCounts = Dictionary(
            grouping: textWrites,
            by: { PageValue(pageIndex: $0.anchor.pageIndex, text: Self.normalizedText($0.text)) }
        ).mapValues(\.count)
        for item in unverified {
            let key = PageValue(pageIndex: item.anchor.pageIndex, text: Self.normalizedText(item.text))
            guard let page = verified.page(at: key.pageIndex), key.pageIndex < sourcePageText.count else {
                throw PDFFormEngineError.outputVerificationFailed(stage: .textReadback, fieldID: item.field.id)
            }
            let before = Self.occurrences(of: key.text, in: sourcePageText[key.pageIndex])
            let after = Self.occurrences(of: key.text, in: Self.normalizedText(page.string ?? ""))
            guard after >= before + (writeCounts[key] ?? 1) else {
                throw PDFFormEngineError.outputVerificationFailed(stage: .textReadback, fieldID: item.field.id)
            }
        }
    }

    static func normalizedText(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    func adjustingRegion(
        fieldID: String,
        to rect: NormalizedRect,
        pageIndex: Int,
        in document: GeneralFormDocument
    ) throws -> GeneralFormDocument {
        guard pageIndex >= 0, Self.isValid(rect) else {
            throw PDFFormEngineError.invalidAnchor(fieldID: fieldID)
        }
        var adjusted = document
        guard let index = adjusted.fields.firstIndex(where: { $0.id == fieldID }) else {
            throw PDFFormEngineError.invalidAnchor(fieldID: fieldID)
        }
        adjusted.fields[index].anchors = [PDFFieldAnchor(
            pageIndex: pageIndex,
            rect: rect,
            kind: .manuallyAdjustedRegion,
            widgetName: nil,
            confidence: 1
        )]
        return adjusted
    }

    static func pdfBounds(from rect: NormalizedRect, pageBounds: CGRect) -> CGRect {
        CGRect(
            x: pageBounds.minX + rect.x * pageBounds.width,
            y: pageBounds.minY + (1 - rect.y - rect.height) * pageBounds.height,
            width: rect.width * pageBounds.width,
            height: rect.height * pageBounds.height
        )
    }

    private func validatePlacement(field: DynamicFormField, document: GeneralFormDocument, pdf: PDFDocument) throws {
        for anchor in field.anchors {
            let bounds = try validatedBounds(for: anchor, fieldID: field.id, pdf: pdf)
            let page = pdf.page(at: anchor.pageIndex)!
            for other in document.fields {
                if let label = other.labelAnchor, label.pageIndex == anchor.pageIndex,
                   bounds.intersects(Self.pdfBounds(from: label.rect, pageBounds: page.bounds(for: .mediaBox))) {
                    throw PDFFormEngineError.invalidAnchor(fieldID: field.id)
                }
                if other.id != field.id, other.anchors.contains(where: {
                    $0.pageIndex == anchor.pageIndex && bounds.insetBy(dx: 1, dy: 1).intersects(Self.pdfBounds(from: $0.rect, pageBounds: page.bounds(for: .mediaBox)).insetBy(dx: 1, dy: 1))
                }) { throw PDFFormEngineError.invalidAnchor(fieldID: field.id) }
            }
            if anchor.kind != .acroFormWidget && field.options.isEmpty,
               !(page.selection(for: bounds.insetBy(dx: 2, dy: 2))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PDFFormEngineError.invalidAnchor(fieldID: field.id)
            }
        }
    }

    private func preparedValues(
        for field: DynamicFormField,
        answer: PersonalAnswer,
        pdf: PDFDocument
    ) throws -> [PreparedWrite] {
        guard !field.anchors.isEmpty else {
            throw PDFFormEngineError.invalidAnchor(fieldID: field.id)
        }

        switch field.kind {
        case .singleChoice, .multipleChoice:
            let known = Set(field.options.map(\.id))
            let selected = Set(answer.selectedOptionIDs)
            guard !selected.isEmpty, selected.isSubset(of: known) else {
                throw PDFFormEngineError.invalidAnswer(fieldID: field.id, reason: "选项无效")
            }
            if field.kind == .singleChoice, selected.count != 1 {
                throw PDFFormEngineError.invalidAnswer(fieldID: field.id, reason: "单选字段只能选择一项")
            }
            if let minimum = field.constraints.minimumSelections, selected.count < minimum {
                throw PDFFormEngineError.invalidAnswer(fieldID: field.id, reason: "选择数量低于下限")
            }
            if let maximum = field.constraints.maximumSelections, selected.count > maximum {
                throw PDFFormEngineError.invalidAnswer(fieldID: field.id, reason: "选择数量超过上限")
            }
            guard field.options.count == field.anchors.count else {
                throw PDFFormEngineError.invalidAnchor(fieldID: field.id)
            }
            return try field.options.enumerated().compactMap { index, option in
                guard selected.contains(option.id) else { return nil }
                let anchor = field.anchors[index]
                _ = try validatedBounds(for: anchor, fieldID: field.id, pdf: pdf)
                return PreparedWrite(field: field, anchor: anchor, text: "", fontSize: 0)
            }
        case .singleLineText, .multilineText, .date:
            guard field.anchors.count == 1, let anchor = field.anchors.first else {
                throw PDFFormEngineError.invalidAnchor(fieldID: field.id)
            }
            let bounds = try validatedBounds(for: anchor, fieldID: field.id, pdf: pdf)
            let text = answer.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw PDFFormEngineError.invalidAnswer(fieldID: field.id, reason: "答案为空")
            }
            if let maximum = field.constraints.maximumCharacters, text.count > maximum {
                throw PDFFormEngineError.invalidAnswer(fieldID: field.id, reason: "超过字符上限")
            }
            if field.kind == .date, let format = field.constraints.dateFormat {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                formatter.isLenient = false
                guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
                    throw PDFFormEngineError.invalidAnswer(fieldID: field.id, reason: "日期格式或日期值无效")
                }
            }
            let maximumLines = field.kind == .multilineText ? max(1, field.constraints.maximumLines ?? 20) : 1
            guard let size = fittedFontSize(text: text, bounds: bounds.insetBy(dx: 3, dy: 2), maximumLines: maximumLines) else {
                throw PDFFormEngineError.overflow(fieldID: field.id)
            }
            return [PreparedWrite(field: field, anchor: anchor, text: text, fontSize: size)]
        }
    }

    private func validatedBounds(
        for anchor: PDFFieldAnchor,
        fieldID: String,
        pdf: PDFDocument
    ) throws -> CGRect {
        guard anchor.confidence >= 0.8, Self.isValid(anchor.rect),
              let page = pdf.page(at: anchor.pageIndex), page.rotation == 0 else {
            throw PDFFormEngineError.invalidAnchor(fieldID: fieldID)
        }
        let pageBounds = page.bounds(for: .mediaBox)
        let bounds = Self.pdfBounds(from: anchor.rect, pageBounds: pageBounds)
        guard pageBounds.contains(bounds) else {
            throw PDFFormEngineError.invalidAnchor(fieldID: fieldID)
        }
        return bounds
    }

    private func widgetFields(on page: PDFPage, pageIndex: Int) -> [DynamicFormField] {
        let widgets = page.annotations.filter { $0.type == "Widget" }
        let grouped = Dictionary(grouping: widgets) { $0.fieldName ?? "" }
        return grouped.keys.sorted().compactMap { name in
            guard !name.isEmpty, let group = grouped[name], let first = group.first else { return nil }
            if first.widgetFieldType == .text, group.count == 1 {
                let printedLabel = labelToLeft(of: first.bounds, on: page)
                let label = printedLabel.isEmpty ? name : printedLabel
                return makeField(
                    id: "widget:\(name)", label: label,
                    kind: first.isMultiline ? .multilineText : inferredTextKind(label: label),
                    page: page, pageIndex: pageIndex, bounds: first.bounds,
                    anchorKind: .acroFormWidget, widgetName: name,
                    constraints: FormFieldConstraints(isRequired: widgetIsRequired(first), maximumCharacters: first.maximumLength > 0 ? first.maximumLength : nil)
                )
            }
            guard first.widgetFieldType == .button,
                  first.widgetControlType == .radioButtonControl || first.widgetControlType == .checkBoxControl else { return nil }
            let isRadio = first.widgetControlType == .radioButtonControl
            let options = group.enumerated().map { index, widget in
                FormFieldOption(
                    id: widget.buttonWidgetStateString.isEmpty ? "option-\(index)" : widget.buttonWidgetStateString,
                    label: nearbyLabel(for: widget.bounds, on: page),
                    exportValue: widget.buttonWidgetStateString
                )
            }
            let anchors = group.map { widget in
                PDFFieldAnchor(
                    pageIndex: pageIndex,
                    rect: normalized(widget.bounds, in: page.bounds(for: .mediaBox)),
                    kind: .acroFormWidget,
                    widgetName: name,
                    confidence: 1
                )
            }
            return DynamicFormField(
                id: "widget:\(name)", label: name, section: nil, instructions: nil,
                kind: isRadio ? .singleChoice : .multipleChoice, options: options,
                constraints: FormFieldConstraints(isRequired: widgetIsRequired(first) || hasRequiredMarker(name), minimumSelections: widgetIsRequired(first) || hasRequiredMarker(name) ? 1 : 0, maximumSelections: isRadio ? 1 : options.count),
                anchors: anchors,
                meaning: FieldMeaning(canonicalKey: nil, summary: nil, state: .needsReview), answer: nil
            )
        }
    }

    private func printedFields(
        on page: PDFPage,
        pageIndex: Int,
        vectors: PDFPageVectorScanResult
    ) -> [DynamicFormField] {
        let media = page.bounds(for: .mediaBox)
        var results: [DynamicFormField] = []
        for line in vectors.lines {
            let labelArea = CGRect(x: media.minX, y: line.minY + 2, width: max(0, line.minX - media.minX - 2), height: 46)
            let left = page.selection(for: labelArea)
            let selection: PDFSelection?
            let bounds: CGRect
            if let left, !(left.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selection = left
                bounds = CGRect(x: line.minX, y: line.minY, width: line.width, height: left.bounds(for: page).maxY - line.minY + 1)
            } else {
                let above = CGRect(x: line.minX, y: line.minY + 3, width: line.width, height: 65)
                selection = page.selection(for: above)?.selectionsByLine().min { $0.bounds(for: page).minY < $1.bounds(for: page).minY }
                guard let selection else { continue }
                bounds = CGRect(x: line.minX, y: line.minY, width: line.width, height: selection.bounds(for: page).minY - line.minY - 4)
            }
            guard let selection, bounds.height >= 18, bounds.height <= 60, media.contains(bounds),
                  (page.selection(for: bounds.insetBy(dx: 2, dy: 2))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let label = selection.string?.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) ?? ""
            results.append(makeField(id: printedID(pageIndex: pageIndex, bounds: bounds), label: label,
                kind: inferredTextKind(label: label), page: page, pageIndex: pageIndex,
                bounds: bounds, anchorKind: .textRegion, widgetName: nil))
        }
        // Bordered fields can place the label above the answer or in its left
        // column. Only use a blank region; never interpret prefilled text as a label.
        let widgetBounds = page.annotations.filter { $0.type == "Widget" }.map(\.bounds)
        let containers = vectors.rectangles.filter { box in
            box.width >= 30 && box.height >= 24 && media.contains(box)
                && !widgetBounds.contains(where: { $0.intersects(box) })
        }
        let boxes = vectors.rectangles.filter { $0.width >= 7 && $0.width <= 16 && abs($0.width - $0.height) < 1 }
        var consumedBoxes = Set<Int>()
        var pairedCells: [CGRect] = []
        for labelBox in containers {
            let label = (page.selection(for: labelBox.insetBy(dx: 3, dy: 3))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 80 else { continue }
            let neighbours = containers.filter {
                abs($0.minX - labelBox.maxX) <= 3 && abs($0.minY - labelBox.minY) <= 3 && abs($0.maxY - labelBox.maxY) <= 3
            }
            // Even a prefilled/ambiguous adjacent answer cell must not turn its label into a field.
            guard !neighbours.isEmpty else { continue }
            pairedCells.append(labelBox)
            pairedCells += neighbours
            guard neighbours.count == 1, let answerBox = neighbours.first else { continue }
            let textLines = page.selection(for: answerBox.insetBy(dx: 3, dy: 3))?.selectionsByLine() ?? []
            let hints = textLines.filter { ($0.string ?? "").hasPrefix("可根据") || ($0.string ?? "").hasPrefix("请填写") }
            guard textLines.count == hints.count else { continue }
            var region = answerBox.insetBy(dx: 4, dy: 4)
            // Keep bottom-aligned printed instructions outside the writable area.
            if let hintTop = hints.map({ $0.bounds(for: page).maxY }).max() {
                guard hintTop < answerBox.midY else { continue }
                region.origin.y = hintTop + 4
                region.size.height = answerBox.maxY - 4 - region.minY
            }
            guard region.width >= 20, region.height >= 16 else { continue }
            var field = makeField(id: printedID(pageIndex: pageIndex, bounds: region), label: label,
                kind: answerBox.height > 55 ? .multilineText : inferredTextKind(label: label),
                page: page, pageIndex: pageIndex, bounds: region, anchorKind: .textRegion, widgetName: nil)
            field.labelAnchor = PDFFieldAnchor(pageIndex: pageIndex, rect: normalized(labelBox, in: media), kind: .textRegion, confidence: 1)
            field.instructions = hints.compactMap(\.string).joined(separator: " ")
            field.section = relationshipHeading(above: labelBox, on: page, containers: containers)
            results.append(field)
        }
        for container in containers where container.width >= 80 && !pairedCells.contains(container) {
            guard !containers.contains(where: { $0 != container && container.contains($0) }) else { continue }
            let lines = page.selection(for: container.insetBy(dx: 3, dy: 3))?.selectionsByLine() ?? []
            guard let heading = lines.sorted(by: { $0.bounds(for: page).maxY > $1.bounds(for: page).maxY }).first,
                  let label = heading.string?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { continue }
            let headingBounds = heading.bounds(for: page)
            let contained = boxes.indices.filter { container.contains(boxes[$0]) }.sorted { boxes[$0].minX < boxes[$1].minX }
            let section = relationshipHeading(above: container, on: page, containers: containers)
            if !contained.isEmpty {
                let ordered = contained.map { boxes[$0] }
                let labels = ordered.enumerated().map { index, box in
                    optionLabel(for: box, rightEdge: index + 1 < ordered.count ? ordered[index + 1].minX : container.maxX, on: page)
                }
                guard labels.allSatisfy({ !$0.isEmpty }) else { continue }
                results.append(choiceField(boxes: ordered, labels: labels, label: label, section: section, on: page, pageIndex: pageIndex))
                consumedBoxes.formUnion(contained)
                continue
            }
            let region: CGRect
            if container.height <= 60 {
                region = CGRect(x: headingBounds.maxX + 10, y: container.minY + 4,
                                width: container.maxX - headingBounds.maxX - 14, height: container.height - 8)
            } else {
                region = CGRect(x: container.minX + 5, y: container.minY + 5,
                                width: container.width - 10, height: headingBounds.minY - container.minY - 12)
            }
            guard region.width >= 60, region.height >= 16,
                  (page.selection(for: region.insetBy(dx: 1, dy: 1))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var field = makeField(id: printedID(pageIndex: pageIndex, bounds: region), label: label,
                                 kind: inferredTextKind(label: label), page: page, pageIndex: pageIndex,
                                 bounds: region, anchorKind: .textRegion, widgetName: nil)
            field.section = section
            results.append(field)
        }
        // Unbordered choices are grouped on their baseline. Limit option text to
        // the next box so adjacent alternatives cannot merge into one label.
        let remaining = boxes.indices.filter { !consumedBoxes.contains($0) }
        let rows = Dictionary(grouping: remaining) { Int(boxes[$0].midY.rounded()) }
        for row in rows.values {
            let ordered = row.map { boxes[$0] }.sorted { $0.minX < $1.minX }
            guard let first = ordered.first else { continue }
            let label = labelToLeft(of: first, on: page)
            let groups = label.isEmpty ? ordered.map { [$0] } : [ordered]
            for group in groups {
                let labels = group.enumerated().map { index, box in
                    optionLabel(for: box, rightEdge: index + 1 < group.count ? group[index + 1].minX : media.maxX, on: page)
                }
                guard labels.allSatisfy({ !$0.isEmpty }) else { continue }
                results.append(choiceField(boxes: group, labels: labels, label: label.isEmpty ? labels[0] : label,
                                           section: nil, on: page, pageIndex: pageIndex, unlabelled: label.isEmpty))
            }
        }
        if let text = page.string {
            let ns = text as NSString
            for offset in 0..<ns.length where ns.substring(with: NSRange(location: offset, length: 1)) == "□" {
                guard let selection = page.selection(for: NSRange(location: offset, length: 1)) else { continue }
                let box = selection.bounds(for: page)
                guard box.width > 0, box.height > 0,
                      !results.contains(where: { $0.anchors.contains { Self.pdfBounds(from: $0.rect, pageBounds: media).intersects(box) } }) else { continue }
                let label = optionLabel(for: box, rightEdge: media.maxX, on: page)
                guard !label.isEmpty else { continue }
                var field = choiceField(boxes: [box], labels: [label], label: label, section: nil, on: page, pageIndex: pageIndex, unlabelled: true)
                field.meaning = FieldMeaning(canonicalKey: nil, summary: "请自行核对后勾选", state: .userSpecified)
                results.append(field)
            }
        }
        return results
    }

    private func makeField(
        id: String, label: String, kind: FormFieldKind, page: PDFPage, pageIndex: Int,
        bounds: CGRect, anchorKind: PDFFieldAnchorKind, widgetName: String?,
        constraints: FormFieldConstraints = FormFieldConstraints()
    ) -> DynamicFormField {
        var constraints = constraints
        constraints.isRequired = constraints.isRequired || hasRequiredMarker(label)
        if kind == .date, label.contains("YYYY-MM-DD") || label.contains("yyyy-MM-dd") {
            constraints.dateFormat = "yyyy-MM-dd"
        }
        return DynamicFormField(
            id: id, label: label.isEmpty ? id : label, section: nil, instructions: nil,
            kind: kind, options: [], constraints: constraints,
            anchors: [PDFFieldAnchor(
                pageIndex: pageIndex,
                rect: normalized(bounds, in: page.bounds(for: .mediaBox)),
                kind: anchorKind, widgetName: widgetName, confidence: anchorKind == .acroFormWidget ? 1 : 0.9
            )],
            meaning: FieldMeaning(canonicalKey: nil, summary: nil, state: .needsReview), answer: nil
        )
    }

    private func inferredTextKind(label: String) -> FormFieldKind {
        let lowercased = label.lowercased()
        if lowercased.contains("日期") || lowercased.contains("date") { return .date }
        if ["地址", "住址", "说明", "经历", "多行"].contains(where: label.contains) { return .multilineText }
        return .singleLineText
    }

    private func optionLabel(for bounds: CGRect, rightEdge: CGFloat, on page: PDFPage) -> String {
        let area = CGRect(x: bounds.maxX + 1, y: bounds.minY - 2,
                          width: max(0, min(100, rightEdge - bounds.maxX - 3)), height: bounds.height + 8)
        return (page.selection(for: area)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func choiceField(boxes: [CGRect], labels: [String], label: String, section: String?,
                             on page: PDFPage, pageIndex: Int, unlabelled: Bool = false) -> DynamicFormField {
        let multiple = unlabelled || label.contains("多选")
        let required = hasRequiredMarker(label)
        let ids = boxes.map { printedID(pageIndex: pageIndex, bounds: $0) }
        return DynamicFormField(id: ids[0], label: label, section: section, instructions: nil,
            kind: multiple ? .multipleChoice : .singleChoice,
            options: zip(ids, labels).map { FormFieldOption(id: $0.0, label: $0.1, exportValue: $0.1) },
            constraints: FormFieldConstraints(isRequired: required, minimumSelections: required ? 1 : 0, maximumSelections: multiple ? boxes.count : 1),
            anchors: boxes.map { PDFFieldAnchor(pageIndex: pageIndex, rect: normalized($0, in: page.bounds(for: .mediaBox)), kind: .checkboxRegion, widgetName: nil, confidence: 0.9) },
            meaning: FieldMeaning(canonicalKey: nil, summary: nil, state: .needsReview), answer: nil)
    }

    private func relationshipHeading(above bounds: CGRect, on page: PDFPage, containers: [CGRect]) -> String? {
        // Only recognized relationship headings are retained. Arbitrary page text,
        // personal values, metadata and annotations never become section context.
        let allowed: Set<String> = ["本人", "申请人", "员工", "紧急联系人", "紧急联络人", "联系人", "家属", "配偶", "父亲", "母亲"]
        let media = page.bounds(for: .mediaBox)
        let lines = page.selection(for: media)?.selectionsByLine() ?? []
        return lines.filter { line in
            let r = line.bounds(for: page)
            return r.minY >= bounds.maxY && !containers.contains(where: { $0.intersects(r) })
                && allowed.contains((line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }.min { $0.bounds(for: page).minY < $1.bounds(for: page).minY }?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func widgetIsRequired(_ annotation: PDFAnnotation) -> Bool {
        // PDF /Ff bit 2 is Required; a widget need not also have a printed asterisk.
        let flags = (annotation.value(forAnnotationKey: .widgetFieldFlags) as? NSNumber)?.intValue ?? 0
        return flags & 2 != 0
    }

    private func hasRequiredMarker(_ label: String) -> Bool {
        label.contains("*") || label.contains("＊") || label.contains("必填")
    }

    private func labelToLeft(of bounds: CGRect, on page: PDFPage) -> String {
        let media = page.bounds(for: .mediaBox)
        let area = CGRect(x: media.minX, y: bounds.minY - 2,
                          width: max(0, bounds.minX - media.minX - 2), height: max(bounds.height + 4, 46))
        return (page.selection(for: area)?.string ?? "")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nearbyLabel(for bounds: CGRect, on page: PDFPage) -> String {
        let area = CGRect(x: bounds.maxX + 1, y: bounds.minY - 2, width: 100, height: bounds.height + 8)
        return (page.selection(for: area)?.string ?? "")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func printedID(pageIndex: Int, bounds: CGRect) -> String {
        "p\(pageIndex):\(Int(bounds.minX.rounded())):\(Int(bounds.minY.rounded())):\(Int(bounds.width.rounded())):\(Int(bounds.height.rounded()))"
    }

    private func normalized(_ rect: CGRect, in bounds: CGRect) -> NormalizedRect {
        NormalizedRect(
            x: (rect.minX - bounds.minX) / bounds.width,
            y: (bounds.maxY - rect.maxY) / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        )
    }

    private func fingerprint(_ data: Data) -> DocumentFingerprint {
        DocumentFingerprint(
            algorithm: "sha256",
            value: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(data.count)
        )
    }

    private func fittedFontSize(text: String, bounds: CGRect, maximumLines: Int) -> CGFloat? {
        for step in stride(from: Int(Self.preferredFontSize * 2), through: Int(Self.minimumFontSize * 2), by: -1) {
            let size = CGFloat(step) / 2
            let font = UIFont.systemFont(ofSize: size)
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: bounds.width, height: 100_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil
            )
            let lineHeight = font.lineHeight
            guard ceil(measured.height / lineHeight) <= CGFloat(maximumLines) else { continue }
            if ceil(measured.height) <= bounds.height, ceil(measured.width) <= bounds.width || maximumLines > 1 {
                return size
            }
        }
        return nil
    }

    private func addCross(to page: PDFPage, bounds: CGRect) {
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let pairs = [
            (CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.maxY)),
            (CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.minY))
        ]
        for pair in pairs {
            let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: pair.0.x - bounds.minX, y: pair.0.y - bounds.minY)
            annotation.endPoint = CGPoint(x: pair.1.x - bounds.minX, y: pair.1.y - bounds.minY)
            annotation.color = .black
            annotation.startLineStyle = .none
            annotation.endLineStyle = .none
            let border = PDFBorder()
            border.lineWidth = 1
            annotation.border = border
            page.addAnnotation(annotation)
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled {
            throw ModuleFailure.cancelled
        }
    }

    private func uniqued(_ fields: [DynamicFormField]) -> [DynamicFormField] {
        var seen = Set<String>()
        return fields.filter { seen.insert($0.id).inserted }
    }

    private static func isValid(_ rect: NormalizedRect) -> Bool {
        rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0
            && rect.x + rect.width <= 1 && rect.y + rect.height <= 1
    }
}

private struct PreparedWrite {
    var field: DynamicFormField
    var anchor: PDFFieldAnchor
    var text: String
    var fontSize: CGFloat
}

private struct PageValue: Hashable {
    var pageIndex: Int
    var text: String
}

private final class PDFPageVectorScanResult {
    var transform = CGAffineTransform.identity
    var transformStack: [CGAffineTransform] = []
    var pendingRectangles: [CGRect] = []
    var rectangles: [CGRect] = []
    var pendingLines: [CGRect] = []
    var lines: [CGRect] = []
    var currentPoint: CGPoint?
    var hasExternalObject = false
    var hasUnsupportedTransform = false
}

private func pdfScannerState(_ info: UnsafeMutableRawPointer?) -> PDFPageVectorScanResult {
    Unmanaged<PDFPageVectorScanResult>.fromOpaque(info!).takeUnretainedValue()
}

private func pdfScannerNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var result: [CGFloat] = []
    for _ in 0..<count {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
        result.insert(value, at: 0)
    }
    return result
}

private enum PDFPageVectorScanner {
    static func scan(_ page: PDFPage) throws -> PDFPageVectorScanResult {
        guard let pageRef = page.pageRef, let table = CGPDFOperatorTableCreate() else {
            throw PDFFormEngineError.limitation(.unsupportedStructure, pageIndex: nil)
        }
        let result = PDFPageVectorScanResult()
        CGPDFOperatorTableSetCallback(table, "q") { _, info in pdfScannerState(info).transformStack.append(pdfScannerState(info).transform) }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let value = pdfScannerState(info)
            if let previous = value.transformStack.popLast() { value.transform = previous } else { value.hasUnsupportedTransform = true }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let values = pdfScannerNumbers(scanner, 6) else { return }
            let value = pdfScannerState(info)
            let transform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            value.transform = transform.concatenating(value.transform)
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let values = pdfScannerNumbers(scanner, 4) else { return }
            let value = pdfScannerState(info)
            if abs(value.transform.b) > 0.001 || abs(value.transform.c) > 0.001 { value.hasUnsupportedTransform = true }
            value.pendingRectangles.append(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]).applying(value.transform).standardized)
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let values = pdfScannerNumbers(scanner, 2) else { return }
            pdfScannerState(info).currentPoint = CGPoint(x: values[0], y: values[1]).applying(pdfScannerState(info).transform)
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let values = pdfScannerNumbers(scanner, 2) else { return }
            let value = pdfScannerState(info)
            guard let start = value.currentPoint else { return }
            let end = CGPoint(x: values[0], y: values[1]).applying(value.transform)
            if abs(start.y - end.y) < 0.01, abs(start.x - end.x) >= 60 {
                value.pendingLines.append(CGRect(x: min(start.x, end.x), y: start.y, width: abs(end.x - start.x), height: 0))
            }
            value.currentPoint = end
        }
        for operation in ["S", "s", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, operation) { _, info in
                let value = pdfScannerState(info)
                value.rectangles += value.pendingRectangles
                value.lines += value.pendingLines
                value.pendingRectangles.removeAll()
                value.pendingLines.removeAll()
                value.currentPoint = nil
            }
        }
        for operation in ["n", "f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(table, operation) { _, info in
                let value = pdfScannerState(info)
                value.pendingRectangles.removeAll()
                value.pendingLines.removeAll()
                value.currentPoint = nil
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { _, info in pdfScannerState(info).hasExternalObject = true }
        CGPDFOperatorTableSetCallback(table, "BI") { _, info in pdfScannerState(info).hasExternalObject = true }
        let stream = CGPDFContentStreamCreateWithPage(pageRef)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(result).toOpaque())
        guard CGPDFScannerScan(scanner) else {
            throw PDFFormEngineError.limitation(.unsupportedStructure, pageIndex: nil)
        }
        return result
    }

}
