import Foundation
#if !DOCX_STANDALONE
@testable import BiaoXia
#endif

/// 同一组真实引擎检查可由 iOS 单测或 macOS CLI 执行，CLI 不启动模拟器。
enum DOCXEngineChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    static func run(repository: URL, output: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = DOCXFormEngine()
        let base = repository.appending(path: "TestAssets/GeneralForms/debug/normal/F01-docx.docx")
        let originalBytes = try Data(contentsOf: base)
        let package = try WordPackage(originalBytes)
        var count = 0
        func passed() { count += 1 }
        func fixture(_ body: String, _ name: String) throws -> URL {
            let data = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + body + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>").utf8)
            let url = output.appendingPathComponent(name + ".docx")
            try package.replacingDocument(data).write(to: url)
            return url
        }
        func filled(_ document: GeneralFormDocument) -> GeneralFormDocument {
            var result = document
            for index in result.fields.indices {
                let field = result.fields[index]
                result.fields[index].answer = PersonalAnswer(value: field.kind == .date ? "2026-09-22" : "虚构示例",
                    selectedOptionIDs: field.options.first.map { [$0.id] } ?? [], sourceRecordIDs: [], confirmationState: .confirmed, modifiedByUser: true)
            }
            return result
        }
        func rejected(_ action: () async throws -> Void, _ reason: String) async throws {
            do { try await action() } catch { passed(); return }
            throw Failure(description: "未阻断：" + reason)
        }

        let parsed = try await engine.parse(formURL: base)
        try check(parsed.effectiveFormat == .docx && parsed.fields.count >= 5, "真实调试表字段发现")
        try check(parsed.fields.contains { $0.kind == .singleChoice }, "真实调试表勾选识别")
        try check(parsed.fields.allSatisfy { $0.anchors.isEmpty && $0.wordAnchor != nil }, "Word 不伪造 PDF 坐标")
        passed()
        let document = filled(parsed)
        let preflight = try engine.preflight(document: document, sourceURL: base)
        try check(preflight.count == document.fields.count && preflight.allSatisfy { $0.state == .contentReadyNeedsExternalReview }, "内容通过不等于排版通过")
        passed()
        let result = output.appendingPathComponent("filled-table.docx")
        try await engine.write(document: document, sourceURL: base, destinationURL: result)
        try check(Data(contentsOf: base) == originalBytes, "原件未改动")
        let outputPackage = try WordPackage(Data(contentsOf: result))
        for entry in package.entries where entry.name != "word/document.xml" {
            try check(outputPackage.part(entry.name) == entry.data, "非目标 ZIP 部件保留：" + entry.name)
        }
        passed()

        // 跨 run 占位符、多种样式、相同段落中的前后说明、XML 字符与显式换行。
        let split = try fixture("<w:p><w:pPr><w:jc w:val=\"left\"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t>个人简介 *：{{</w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>简介}}</w:t></w:r><w:r><w:t>（保留说明）</w:t></w:r></w:p>", "split-source")
        var splitDoc = try await engine.parse(formURL: split)
        try check(splitDoc.fields.count == 1 && splitDoc.fields[0].label == "个人简介 *", "跨 run 定位")
        let special = "研发 & 设计 <测试>\n第二行"
        splitDoc.fields[0].answer = PersonalAnswer(value: special, selectedOptionIDs: [], sourceRecordIDs: [], confirmationState: .confirmed, modifiedByUser: true)
        let splitOutput = output.appendingPathComponent("filled-split.docx")
        try await engine.write(document: splitDoc, sourceURL: split, destinationURL: splitOutput)
        let splitXML = try WordXMLDocument(WordPackage(Data(contentsOf: splitOutput)).part("word/document.xml"))
        let allText = try splitXML.nodes("//w:t").map { splitXML.text($0) }.joined()
        try check(allText.contains("研发 & 设计 <测试>") && allText.hasSuffix("（保留说明）"), "XML 转义与非目标文字")
        try check(splitXML.nodes("//w:b | //w:i | //w:jc").count == 3 && splitXML.nodes("//w:br").count == 1, "保留 run/段落样式并生成换行")
        passed()

        let borders = "<w:tblPr><w:tblBorders><w:top w:val=\"single\"/><w:left w:val=\"single\"/><w:bottom w:val=\"single\"/><w:right w:val=\"single\"/><w:insideH w:val=\"single\"/><w:insideV w:val=\"single\"/></w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w=\"2200\"/><w:gridCol w:w=\"6800\"/></w:tblGrid>"
        func row(_ label: String, _ value: String = "") -> String {
            "<w:tr><w:tc><w:tcPr><w:tcW w:w=\"2200\" w:type=\"dxa\"/></w:tcPr><w:p><w:r><w:t>\(label)</w:t></w:r></w:p></w:tc><w:tc><w:tcPr><w:tcW w:w=\"6800\" w:type=\"dxa\"/></w:tcPr><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>\(value)</w:t></w:r></w:p></w:tc></w:tr>"
        }
        let blanks = try fixture("<w:p><w:r><w:t>普通 Word 相邻空格示例</w:t></w:r></w:p><w:tbl>" + borders + row("姓名 *") + row("出生日期（YYYY-MM-DD） *") + row("通讯地址") + row("预填姓名", "不可覆盖") + "</w:tbl>", "blank-source")
        let blanksDoc = try await engine.parse(formURL: blanks)
        try check(blanksDoc.fields.count == 3, "发现相邻空格，不覆盖预填值")
        let blanksOut = output.appendingPathComponent("filled-blanks.docx")
        try await engine.write(document: filled(blanksDoc), sourceURL: blanks, destinationURL: blanksOut)
        let blanksXML = try WordXMLDocument(WordPackage(Data(contentsOf: blanksOut)).part("word/document.xml"))
        try check(blanksXML.nodes("//w:t").map { blanksXML.text($0) }.contains("不可覆盖"), "保留预填内容")
        passed()

        let relation = repository.appending(path: "TestAssets/GeneralForms/debug/normal/F04-docx.docx")
        let relationDoc = try await engine.parse(formURL: relation)
        let me = ProfileSubject(id: UUID(), kind: .selfPerson, displayName: "本人示例")
        let contact = ProfileSubject(id: UUID(), kind: .emergencyContact, displayName: "联系人示例")
        let answers = try await LocalRuleAnswerMatcher().match(fields: relationDoc.fields, subjects: [me, contact], records: [])
        let contactName = relationDoc.fields.first { $0.label.contains("姓名") && $0.section == "紧急联系人" }
        try check(contactName != nil && answers[contactName!.id]?.value == "联系人示例", "重复姓名依章节匹配人物")
        passed()

        var wrongDate = document
        let dateIndex = wrongDate.fields.firstIndex { $0.kind == .date }!
        wrongDate.fields[dateIndex].answer?.value = "2026-02-30"
        try await rejected({ try await engine.write(document: wrongDate, sourceURL: base, destinationURL: output.appendingPathComponent("invalid-date.docx")) }, "非法日期")
        var wrongChoice = document
        let choiceIndex = wrongChoice.fields.firstIndex { !$0.options.isEmpty }!
        wrongChoice.fields[choiceIndex].answer?.selectedOptionIDs = ["unknown"]
        try await rejected({ try await engine.write(document: wrongChoice, sourceURL: base, destinationURL: output.appendingPathComponent("invalid-choice.docx")) }, "未知选项")
        var changed = document
        changed.fields[0].wordAnchor?.path = "/w:document/w:body/w:p[1]"
        try await rejected({ try await engine.write(document: changed, sourceURL: base, destinationURL: output.appendingPathComponent("invalid-anchor.docx")) }, "快照锚点篡改")
        var missing = document
        missing.fields.removeFirst()
        try await rejected({ try await engine.write(document: missing, sourceURL: base, destinationURL: output.appendingPathComponent("missing-field.docx")) }, "快照丢失字段")
        var unconfirmed = document
        unconfirmed.fields[0].answer?.confirmationState = .suggested
        try await rejected({ try await engine.write(document: unconfirmed, sourceURL: base, destinationURL: output.appendingPathComponent("unconfirmed.docx")) }, "未确认必填")
        try await rejected({ try await engine.write(document: document, sourceURL: base, destinationURL: base) }, "覆盖原件")
        try await rejected({ try await engine.write(document: document, sourceURL: base, destinationURL: result) }, "覆盖已有结果")
        try await rejected({ try await engine.write(document: document, sourceURL: blanks, destinationURL: output.appendingPathComponent("stale.docx")) }, "原件指纹变化")

        for (name, body) in [
            ("revision", "<w:ins><w:p><w:r><w:t>姓名：{{姓名}}</w:t></w:r></w:p></w:ins>"),
            ("nested", "<w:tbl><w:tr><w:tc><w:tbl><w:tr><w:tc><w:p/></w:tc></w:tr></w:tbl></w:tc></w:tr></w:tbl>"),
            ("vertical", "<w:tbl><w:tr><w:tc><w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr><w:p/></w:tc></w:tr></w:tbl>"),
            ("hidden", "<w:p><w:r><w:rPr><w:vanish/></w:rPr><w:t>隐私姓名：{{姓名}}</w:t></w:r></w:p>")
        ] {
            let url = try fixture(body, name)
            try await rejected({ _ = try await engine.parse(formURL: url) }, name)
        }
        // 真实解析的锚点含原文，但出站 DTO 必须只包含核对后的标签，不得序列化答案或路径。
        var reviewed = FieldExplanationRequestBuilder().makeDraft(fields: splitDoc.fields)
        reviewed.allowAllPending()
        let request = try FieldExplanationRequestBuilder().build(from: reviewed)
        let outbound = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try check(!outbound.contains("研发") && !outbound.contains("wordAnchor") && !outbound.contains("/w:"), "出站白名单不序列化 Word 锚点和答案")
        passed()
        let restored = try JSONDecoder().decode(GeneralFormDocument.self, from: JSONEncoder().encode(document))
        try check(restored == document, "Word 快照恢复")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
        legacy.removeValue(forKey: "format")
        legacy["fields"] = []
        let legacyDoc = try JSONDecoder().decode(GeneralFormDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(legacyDoc.effectiveFormat == .pdf, "旧 PDF 快照兼容")
        passed()
        return count
    }
}
