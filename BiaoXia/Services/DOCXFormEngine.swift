import CryptoKit
import Foundation
@preconcurrency import libxml2

/// 原生 DOCX 内容填写：结构地址负责定位，本地资料库负责答案。
/// 此引擎不排版；通过内容预检的文件仍须在 Word/WPS 中核对分页和裁切。
struct DOCXFormEngine: FormParsing, FormWriting, FormPreflighting {
    static let reviewNotice = "Word 内容核对与版式核对分开进行。这里只列出已识别字段；导出后请用 Word/WPS 检查漏填、换行、分页和裁切。"
    private static let subjects: Set<String> = ["本人", "申请人", "员工", "学员", "紧急联系人", "紧急联络人", "联系人", "家属", "配偶", "父亲", "母亲"]

    func parse(formURL: URL) async throws -> GeneralFormDocument {
        try Task.checkCancellation()
        let source = try Data(contentsOf: formURL)
        let xml = try Self.inspect(WordPackage(source))
        return try Self.document(source: source, xml: xml)
    }

    static func validatePackage(at url: URL) throws {
        _ = try inspect(WordPackage(Data(contentsOf: url)))
    }

    /// 对整个包检查影响填写含义的结构。批注、媒体和元数据保留，但不参与字段发现。
    private static func inspect(_ archive: WordPackage) throws -> WordXMLDocument {
        try wordRequire(!archive.entries.contains { $0.name.contains("vbaProject") || $0.name.hasPrefix("_xmlsignatures/") }, "macro/signed package")
        _ = try archive.part("[Content_Types].xml")
        for entry in archive.entries where entry.name.hasSuffix(".xml") || entry.name.hasSuffix(".rels") {
            let xml = try WordXMLDocument(entry.data)
            let unsupported = "//*[local-name()='txbxContent' or local-name()='anchor' or local-name()='AlternateContent' or local-name()='object' or local-name()='altChunk' or local-name()='ins' or local-name()='del' or local-name()='moveFrom' or local-name()='moveTo' or local-name()='documentProtection' or local-name()='fldSimple' or local-name()='fldChar']"
            try wordRequire(xml.nodes(unsupported).isEmpty, "unsupported layout/revision/protection/field")
            try wordRequire(xml.nodes("//w:tbl//w:tbl | //w:vMerge").isEmpty, "nested table/vertical merge")
            try wordRequire(xml.nodes("//w:sdtPr[not(w:text) or w:lock or w:dataBinding]").isEmpty, "unsupported content control")
            try wordRequire(xml.nodes("//*[@TargetMode='External']").isEmpty, "external relationship")
        }
        let xml = try WordXMLDocument(archive.part("word/document.xml"))
        try wordRequire(xml.nodes("/w:document/w:body").count == 1, "Word namespace/body")
        return xml
    }

    private static func document(source: Data, xml: WordXMLDocument) throws -> GeneralFormDocument {
        var fields: [DynamicFormField] = []
        var section: String?
        let paragraphs = try xml.nodes("/w:document/w:body//w:p")
        for (index, paragraph) in paragraphs.enumerated() {
            try Task.checkCancellation()
            let path = nodePath(paragraph)
            let text = try visibleText(xml, path: path)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if subjects.contains(trimmed) { section = trimmed }
            // 不将隐藏 run、图形、超链接或其他非纯文字内容变成可覆盖目标。
            guard try xml.nodes(path + "/w:r/*[not(self::w:t or self::w:rPr)] | " + path + "/w:r/w:rPr/w:vanish | " + path + "/w:r/w:rPr/w:webHidden").isEmpty,
                  try xml.nodes(path + "/*[not(self::w:r or self::w:pPr)]").isEmpty else { continue }
            let cell = try xml.nodes(path + "/ancestor::w:tc").last
            var leftLabel: String?
            if let cell {
                let cellPath = nodePath(cell)
                let cellParagraphs = try xml.nodes(cellPath + "//w:p")
                // 一个空格只绑定一次；多段落单元格暂不推断其填写边界。
                if cellParagraphs.count == 1,
                   let previous = try xml.nodes(cellPath + "/preceding-sibling::w:tc[1]").first {
                    let previousPath = nodePath(previous)
                    let label = try visibleText(xml, path: previousPath)
                    if plausibleLabel(label) { leftLabel = label }
                }
            }
            let location = "正文第 \(index + 1) 段" + (cell == nil ? "" : "（表格内）")
            var label: String?
            var placeholder: String?
            var options: [FormFieldOption] = []
            var kind: FormFieldKind = .singleLineText
            if text.contains("□") {
                let pieces = text.components(separatedBy: "□")
                let prefix = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                label = leftLabel ?? (plausibleLabel(prefix) ? prefix : nil)
                // 仅支持同一段落内“□ 选项”的明确组；不把说明文字猜成选项。
                let optionLabels = pieces.dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard optionLabels.count >= 2, optionLabels.count <= 30,
                      optionLabels.allSatisfy({ !$0.isEmpty && $0.count <= 40 && !$0.contains("请") && !$0.contains("☑") }) else { continue }
                options = optionLabels.enumerated().map { FormFieldOption(id: "option-\($0.offset + 1)", label: $0.element, exportValue: $0.element) }
                kind = label?.contains("多选") == true ? .multipleChoice : .singleChoice
            } else {
                let expression = try NSRegularExpression(pattern: #"\{\{[^{}\r\n]{1,80}\}\}|_{2,}|＿{2,}"#)
                let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                if matches.count == 1, let match = matches.first, let range = Range(match.range, in: text) {
                    placeholder = String(text[range])
                    let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let leftLabel { label = leftLabel }
                    else if plausibleLabel(prefix), prefix.hasSuffix(":") || prefix.hasSuffix("：") { label = prefix }
                    else if prefix.isEmpty, let placeholder, placeholder.hasPrefix("{{") {
                        let inner = String(placeholder.dropFirst(2).dropLast(2))
                        // 匿名占位符编号不具备字段语义；需要左侧或同段标签才能发现。
                        if plausibleLabel(inner), inner.range(of: #"^[A-Za-z]*[0-9]+$"#, options: .regularExpression) == nil { label = inner }
                    }
                } else if trimmed.isEmpty, let leftLabel {
                    label = leftLabel
                }
                if let label {
                    if label.contains("日期") || label.contains("年月") || label.lowercased().contains("date") { kind = .date }
                    else if ["地址", "住址", "经历", "说明", "评价", "事迹", "简介"].contains(where: label.contains) { kind = .multilineText }
                }
            }
            guard let rawLabel = label, plausibleLabel(rawLabel) else { continue }
            let cleanLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：")))
            let required = cleanLabel.contains("*") || cleanLabel.contains("必填")
            let dateFormat = cleanLabel.lowercased().contains("yyyy-mm-dd") ? "yyyy-MM-dd" : nil
            let constraints = FormFieldConstraints(isRequired: required, dateFormat: dateFormat,
                minimumSelections: options.isEmpty ? nil : (required ? 1 : 0),
                maximumSelections: options.isEmpty ? nil : (kind == .singleChoice ? 1 : options.count))
            fields.append(DynamicFormField(id: "word:\(path)", label: cleanLabel, section: section, instructions: nil,
                kind: kind, options: options, constraints: constraints, anchors: [],
                meaning: FieldMeaning(canonicalKey: nil, summary: nil, state: .needsReview), answer: nil,
                wordAnchor: WordFieldAnchor(path: path, originalText: text, placeholder: placeholder, location: location)))
            try wordRequire(fields.count <= 500, "field count limit")
        }
        guard !fields.isEmpty else {
            throw ModuleFailure.blocked("没有找到可填写的 Word 字段。当前支持标签右侧的单段空格、明确占位符和同段勾选组；请保留原件并用 Word/WPS 填写。")
        }
        return GeneralFormDocument(structureVersion: GeneralFormDocument.currentStructureVersion,
            fingerprint: DocumentFingerprint(algorithm: "SHA-256", value: wordFingerprint(source), byteCount: Int64(source.count)),
            fields: fields, format: .docx)
    }

    func preflight(document: GeneralFormDocument, sourceURL: URL) throws -> [PDFFieldLayoutResult] {
        let source = try Data(contentsOf: sourceURL)
        let xml = try Self.checkedXML(source, document: document)
        let original = try Self.document(source: source, xml: xml)
        return document.fields.compactMap { field in
            guard let answer = field.answer, answer.confirmationState == .confirmed else { return nil }
            do {
                try Self.validate(field: field, original: original)
                _ = try Self.replacements(field: field, answer: answer)
                return PDFFieldLayoutResult(fieldID: field.id, state: .contentReadyNeedsExternalReview)
            } catch {
                return PDFFieldLayoutResult(fieldID: field.id, state: .invalidAnswer(error.localizedDescription))
            }
        }
    }

    func write(document: GeneralFormDocument, sourceURL: URL, destinationURL: URL) async throws {
        try Task.checkCancellation()
        guard sourceURL.standardizedFileURL.resolvingSymlinksInPath() != destinationURL.standardizedFileURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw ModuleFailure.blocked("请将填写结果保存为新文件，不能覆盖原件或已有文件。")
        }
        let source = try Data(contentsOf: sourceURL)
        let xml = try Self.checkedXML(source, document: document)
        let original = try Self.document(source: source, xml: xml)
        // 先验证全部目标，再修改内存文档。恢复快照不能伪造路径、字段或选项。
        guard Set(document.fields.map(\.id)).count == document.fields.count,
              Set(document.fields.map(\.id)) == Set(original.fields.map(\.id)) else {
            throw ModuleFailure.blocked("Word 字段结构已变化，请重新导入原表。")
        }
        var writes: [(WordFieldAnchor, [(NSRange, String)])] = []
        var answerBytes = 0
        for field in document.fields {
            try Self.validate(field: field, original: original)
            if field.constraints.isRequired, field.answer?.confirmationState != .confirmed {
                throw ModuleFailure.blocked("请先确认必填字段：\(field.label)")
            }
            guard let answer = field.answer, answer.confirmationState == .confirmed, let anchor = field.wordAnchor else { continue }
            let replacements = try Self.replacements(field: field, answer: answer)
            answerBytes += replacements.reduce(0) { $0 + $1.1.utf8.count }
            try wordRequire(answerBytes <= 1_000_000, "total answer size limit")
            writes.append((anchor, replacements))
        }
        for (anchor, replacements) in writes {
            try Task.checkCancellation()
            try Self.replace(replacements, anchor: anchor, xml: xml)
        }
        let output = try WordPackage(source).replacingDocument(xml.serialized())
        let verified = try Self.inspect(WordPackage(output))
        for (anchor, replacements) in writes {
            let expected = NSMutableString(string: anchor.originalText)
            for (range, value) in replacements.sorted(by: { $0.0.location > $1.0.location }) { expected.replaceCharacters(in: range, with: value) }
            guard try Self.visibleText(verified, path: anchor.path) == (expected as String) else {
                throw ModuleFailure.blocked("Word 写入内容复核失败，未生成结果。")
            }
        }
        let directory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try output.write(to: temporary, options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destinationURL)
    }

    private static func checkedXML(_ source: Data, document: GeneralFormDocument) throws -> WordXMLDocument {
        guard document.effectiveFormat == .docx, document.structureVersion == GeneralFormDocument.currentStructureVersion,
              document.fingerprint.algorithm == "SHA-256", document.fingerprint.value == wordFingerprint(source),
              document.fingerprint.byteCount == source.count else {
            throw ModuleFailure.blocked("Word 原件或字段版本已变化，请重新导入。")
        }
        return try inspect(WordPackage(source))
    }

    private static func validate(field: DynamicFormField, original: GeneralFormDocument) throws {
        guard let detected = original.fields.first(where: { $0.id == field.id }),
              field.wordAnchor == detected.wordAnchor, field.anchors.isEmpty,
              field.kind == detected.kind, field.options == detected.options, field.constraints == detected.constraints,
              field.label == detected.label, field.section == detected.section else {
            throw ModuleFailure.blocked("Word 字段位置或约束已变化，请重新导入原表。")
        }
    }

    private static func replacements(field: DynamicFormField, answer: PersonalAnswer) throws -> [(NSRange, String)] {
        guard let anchor = field.wordAnchor else { throw ModuleFailure.blocked("缺少 Word 填写位置。") }
        if !field.options.isEmpty {
            let selected = Set(answer.selectedOptionIDs)
            guard selected.count == answer.selectedOptionIDs.count,
                  selected.isSubset(of: Set(field.options.map(\.id))),
                  selected.count >= (field.constraints.minimumSelections ?? 0),
                  selected.count <= (field.constraints.maximumSelections ?? field.options.count),
                  field.kind != .singleChoice || selected.count == 1 else {
                throw ModuleFailure.blocked("请选择有效的选项。")
            }
            let ranges = anchor.originalText.indices.filter { anchor.originalText[$0] == "□" }
            guard ranges.count == field.options.count else { throw ModuleFailure.blocked("勾选位置已变化。") }
            return zip(ranges, field.options).map { index, option in
                (NSRange(index..<anchor.originalText.index(after: index), in: anchor.originalText), selected.contains(option.id) ? "☑" : "□")
            }
        }
        let text = (answer.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 64_000,
              text.unicodeScalars.allSatisfy({ $0.value == 10 || ($0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF) }) else {
            throw ModuleFailure.blocked("请填写非空的有效文字，单项不超过 64 KB。")
        }
        if let maximum = field.constraints.maximumCharacters, text.count > maximum { throw ModuleFailure.blocked("答案超过字段字数限制。") }
        if field.kind == .date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = field.constraints.dateFormat ?? "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: text), formatter.string(from: date) == text else { throw ModuleFailure.blocked("请使用有效的 yyyy-MM-dd 日期。") }
        }
        if let placeholder = anchor.placeholder, let range = anchor.originalText.range(of: placeholder) {
            return [(NSRange(range, in: anchor.originalText), text)]
        }
        guard anchor.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModuleFailure.blocked("填写区域已有文字，不能覆盖。")
        }
        return [(NSRange(location: 0, length: (anchor.originalText as NSString).length), text)]
    }

    /// 按 UTF-16 范围替换文本，保留原 run/段落属性及占位符两侧的标签说明。
    /// 跨 run 占位符写入首个相交 run，其余相交片段清空；显式换行生成 w:br。
    private static func replace(_ replacements: [(NSRange, String)], anchor: WordFieldAnchor, xml: WordXMLDocument) throws {
        guard let paragraph = try xml.nodes(anchor.path).first else { throw ModuleFailure.blocked("Word 位置不存在。") }
        var nodes = try xml.nodes(anchor.path + "/w:r/w:t")
        if nodes.isEmpty {
            let runs = try xml.nodes(anchor.path + "/w:r")
            guard let run = runs.first ?? xmlNewChild(paragraph, paragraph.pointee.ns, "r", nil),
                  let text = xmlNewChild(run, paragraph.pointee.ns, "t", nil) else { throw WordPackageError.rejected("allocate text") }
            nodes = [text]
        }
        var texts = nodes.map { xml.text($0) }
        for (range, value) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            var offset = 0
            var inserted = false
            for index in nodes.indices {
                let length = (texts[index] as NSString).length
                let nodeRange = NSRange(location: offset, length: length)
                let intersection = NSIntersectionRange(nodeRange, range)
                let insertion = range.length == 0 && !inserted && range.location >= offset && range.location <= offset + length
                if intersection.length > 0 || insertion {
                    let local = NSRange(location: insertion ? range.location - offset : intersection.location - offset, length: intersection.length)
                    texts[index] = (texts[index] as NSString).replacingCharacters(in: local, with: inserted ? "" : value)
                    inserted = true
                }
                offset += length
            }
            guard inserted else { throw WordPackageError.rejected("text range") }
        }
        for (node, value) in zip(nodes, texts) {
            // xmlNodeSetContent 解释实体；先转义，避免用户输入的 & 或 < 被误解。
            let lines = value.components(separatedBy: "\n")
            setText(node, lines[0])
            var cursor = node
            for line in lines.dropFirst() {
                guard let br = xmlNewNode(node.pointee.ns, "br"), let next = xmlNewNode(node.pointee.ns, "t") else { throw WordPackageError.rejected("allocate line") }
                xmlAddNextSibling(cursor, br)
                xmlAddNextSibling(br, next)
                setText(next, line)
                cursor = next
            }
        }
    }

    private static func setText(_ node: xmlNodePtr, _ text: String) {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        xmlNodeSetContent(node, escaped)
        let xmlNamespace = xmlSearchNsByHref(node.pointee.doc, node, "http://www.w3.org/XML/1998/namespace")
        xmlSetNsProp(node, xmlNamespace, "space", "preserve")
    }

    private static func visibleText(_ xml: WordXMLDocument, path: String) throws -> String {
        try xml.nodes(path + "//w:r[not(w:rPr/w:vanish or w:rPr/w:webHidden)]/*[self::w:t or self::w:br]").map {
            String(cString: $0.pointee.name) == "br" ? "\n" : xml.text($0)
        }.joined()
    }

    private static func plausibleLabel(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 100 && !value.contains("\n")
            && !["{{", "}}", "__", "＿", "□", "☑"].contains(where: value.contains)
    }

    /// 自建带命名空间的绝对路径，不依赖源文件选用的 XML 前缀。
    private static func nodePath(_ node: xmlNodePtr) -> String {
        guard node.pointee.type == XML_ELEMENT_NODE else { return "" }
        let name = String(cString: node.pointee.name)
        var index = 1
        var sibling = node.pointee.prev
        while let previous = sibling {
            if previous.pointee.type == XML_ELEMENT_NODE,
               String(cString: previous.pointee.name) == name { index += 1 }
            sibling = previous.pointee.prev
        }
        let prefix = node.pointee.parent.map(nodePath) ?? ""
        return prefix + "/w:\(name)[\(index)]"
    }
}
