import Foundation
@preconcurrency import libxml2

/// 只读取原生 Word 的正文文字；不渲染、不执行域或关系、不上传个人资料。
/// 与待填表格解析分离：材料中的合并单元格和嵌套表格可读取，但不推断视觉位置。
struct DOCXMaterialReader {
    func read(from url: URL, materialID: UUID) throws -> [OCRBlock] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try wordRequire(size > 0 && size <= 32_000_000, "material package size")
        let package = try WordPackage(Data(contentsOf: url))
        try wordRequire(!package.entries.contains { $0.name.lowercased().contains("vbaproject") }, "macro material")
        let types = try WordXMLDocument(package.part("[Content_Types].xml"))
        try wordRequire(try !types.nodes("/*[local-name()='Types']/*[local-name()='Override'][@PartName='/word/document.xml' and @ContentType='application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml']").isEmpty, "not a native DOCX")
        let xml = try WordXMLDocument(package.part("word/document.xml"))
        // 修订内容可能包含互相矛盾的旧值；要求用户先在 Word 中处理修订。
        try wordRequire(try xml.nodes("//*[local-name()='ins' or local-name()='del' or local-name()='moveFrom' or local-name()='moveTo' or local-name()='altChunk']").isEmpty, "unresolved revisions or imported content")
        guard let body = try xml.nodes("/w:document/w:body").first else {
            throw WordPackageError.rejected("missing Word body")
        }
        let labels = Set((RuleBasedFieldExtractor().materialLabels + RuleBasedProfileItemExtractor().materialLabels).map { $0.lowercased() })
        var lines: [String] = []
        var totalBytes = 0
        func append(_ text: String) throws {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            totalBytes += text.utf8.count
            try wordRequire(totalBytes <= 1_000_000 && lines.count < 10_000, "material text limit")
            lines.append(text)
        }
        func label(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "：: \t\n"))
            return labels.contains(value.lowercased()) ? value : nil
        }
        func visit(_ node: xmlNodePtr) throws {
            switch name(node) {
            case "p": try append(paragraphText(node, xml: xml))
            case "tbl":
                for row in children(node).filter({ name($0) == "tr" }) {
                    let cells = children(row).filter { name($0) == "tc" }
                    var index = 0
                    while index < cells.count {
                        let cell = cells[index]
                        let paragraphs = children(cell).filter { name($0) == "p" }
                        let value = paragraphs.map { paragraphText($0, xml: xml) }.joined(separator: "\n")
                        // 只将明确的已知标签与紧邻内容关联；表头“姓名｜学校”不会成为姓名值。
                        // 有嵌套表格或纵向合并时仅保留原文，不跨结构配对。
                        let isHeader = children(row).filter { name($0) == "trPr" }.flatMap(children).contains { name($0) == "tblHeader" }
                        if !isHeader, index + 1 < cells.count, isSimpleCell(cell), isSimpleCell(cells[index + 1]),
                           let key = label(value) {
                            let next = children(cells[index + 1]).filter { name($0) == "p" }
                                .map { paragraphText($0, xml: xml) }.joined(separator: "\n")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !next.isEmpty, label(next) == nil {
                                try append("\(key)：\(next)")
                                index += 2
                                continue
                            }
                        }
                        for child in children(cell) { try visit(child) }
                        index += 1
                    }
                }
            case "body", "sdt", "sdtContent", "customXml":
                for child in children(node) { try visit(child) }
            default: break
            }
        }
        try visit(body)
        guard !lines.isEmpty else { throw BiaoXiaError.wordMaterialHasNoText }
        // -1 明确表示无物理页码，零矩形表示无页面几何；现有快照和来源链可直接保存。
        return lines.map {
            OCRBlock(text: $0, pageIndex: -1, boundingBox: .init(x: 0, y: 0, width: 0, height: 0),
                     confidence: 1, materialID: materialID)
        }
    }

    private func name(_ node: xmlNodePtr) -> String {
        guard let namespace = node.pointee.ns?.pointee.href,
              String(cString: namespace) == "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
              let name = node.pointee.name else { return "" }
        return String(cString: name)
    }

    private func children(_ node: xmlNodePtr) -> [xmlNodePtr] {
        var result: [xmlNodePtr] = [], child = node.pointee.children
        while let current = child { result.append(current); child = current.pointee.next }
        return result
    }

    private func isSimpleCell(_ cell: xmlNodePtr) -> Bool {
        !children(cell).contains { name($0) == "tbl" || (name($0) == "tcPr" && children($0).contains { name($0) == "vMerge" }) }
    }

    private func paragraphText(_ paragraph: xmlNodePtr, xml: WordXMLDocument) -> String {
        func hasField(_ node: xmlNodePtr) -> Bool {
            name(node) == "fldChar" || name(node) == "fldSimple" || children(node).contains(where: hasField)
        }
        // 域的缓存结果可能过期；不把它当作用户的静态资料，也不执行域计算。
        guard !hasField(paragraph) else { return "" }
        func text(_ node: xmlNodePtr) -> String {
            switch name(node) {
            case "t": return xml.text(node)
            case "tab": return "\t"
            case "br", "cr": return "\n"
            case "r":
                let hidden = children(node).filter { name($0) == "rPr" }.flatMap(children)
                    .contains { ["vanish", "webHidden"].contains(name($0)) }
                return hidden ? "" : children(node).map(text).joined()
            case "p", "hyperlink", "sdt", "sdtContent", "smartTag", "customXml":
                return children(node).map(text).joined()
            default: return "" // 图片、浮动文本框、域指令和批注不混入正文资料。
            }
        }
        return text(paragraph)
    }
}
