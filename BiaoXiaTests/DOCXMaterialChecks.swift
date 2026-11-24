import Foundation
#if !DOCX_STANDALONE
@testable import BiaoXia
#endif

/// 虚构材料覆盖文字读取、表格关联、隐私边界和现有本地字段规则。
enum DOCXMaterialChecks {
    static func run(repository: URL, output: URL) throws -> Int {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let package = try WordPackage(Data(contentsOf: repository.appending(path: "TestAssets/GeneralForms/debug/normal/F01-docx.docx")))
        let reader = DOCXMaterialReader(), materialID = UUID()
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            try DOCXEngineChecks.check(condition, name)
            count += 1
        }
        func fixture(_ body: String) throws -> URL {
            let xml = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)</w:body></w:document>"
            let url = output.appending(path: "\(UUID().uuidString).docx")
            try package.replacingDocument(Data(xml.utf8)).write(to: url)
            return url
        }
        func p(_ value: String) -> String { "<w:p><w:r><w:t>\(value)</w:t></w:r></w:p>" }
        func cell(_ value: String) -> String { "<w:tc>\(p(value))</w:tc>" }
        func read(_ body: String) throws -> [OCRBlock] {
            try reader.read(from: fixture(body), materialID: materialID)
        }
        func reject(_ body: String) throws {
            do { _ = try read(body) } catch { count += 1; return }
            throw DOCXEngineChecks.Failure(description: "Word material should reject unsupported input")
        }

        let paragraphs = try read("<w:p><w:r><w:t>姓名：</w:t></w:r><w:r><w:t>虚构甲</w:t></w:r></w:p>" + p("邮箱：fictional@example.com") + p("技能：Swift &amp; Python"))
        try check(paragraphs.map(\.text) == ["姓名：虚构甲", "邮箱：fictional@example.com", "技能：Swift & Python"], "run 合并与 XML 转义")
        let fields = RuleBasedFieldExtractor().extract(from: paragraphs).resolved
        try check(fields.first { $0.key == .fullName }?.value == "虚构甲" && fields.first { $0.key == .email }?.value == "fictional@example.com", "段落本地建档")
        let material = MaterialAsset(id: materialID, displayName: "虚构简历.docx", kind: .docx, pageCount: 0, relativePath: "materials/test.docx")
        let items = RuleBasedProfileItemExtractor().extractItems(from: paragraphs, materials: [material])
        try check(items.first { $0.fieldID == "skill" }?.value == "Swift & Python" && items.first?.sources.first?.materialID == materialID, "扩展信息与来源")
        try check(paragraphs.allSatisfy { $0.pageIndex == -1 && $0.boundingBox.width == 0 && $0.locationDescription == "Word 正文" }, "无伪造页码与几何")

        let table = "<w:tbl><w:tr>\(cell("姓名"))\(cell("虚构乙"))\(cell("学校"))\(cell("虚构测试大学"))</w:tr><w:tr>\(cell("项目经历"))<w:tc>\(p("虚构项目"))\(p("负责测试"))</w:tc></w:tr></w:tbl>"
        let rows = try read(p("简历") + table + p("结束"))
        try check(rows.map(\.text) == ["简历", "姓名：虚构乙", "学校：虚构测试大学", "项目经历：虚构项目\n负责测试", "结束"], "多对单元格和多段经历顺序")
        try check(RuleBasedFieldExtractor().extract(from: rows).resolved.first { $0.key == .school }?.value == "虚构测试大学", "表格字段实际提取")
        let header = try read("<w:tbl><w:tr>\(cell("姓名"))\(cell("学校"))</w:tr><w:tr><w:trPr><w:tblHeader/></w:trPr>\(cell("姓名"))\(cell("单位"))</w:tr></w:tbl>")
        try check(RuleBasedFieldExtractor().extract(from: header).resolved.first { $0.key == .fullName }?.value == "", "表头与无坐标邻近内容不冒充姓名")
        let nested = try read("<w:tbl><w:tr><w:tc>\(p("外层"))\(table)</w:tc></w:tr></w:tbl>")
        try check(nested.map(\.text).filter { $0 == "姓名：虚构乙" }.count == 1, "嵌套表格文字不重复")
        let hidden = try read(p("可见") + "<w:p><w:r><w:rPr><w:vanish/></w:rPr><w:t>隐藏资料</w:t></w:r><w:r><w:drawing><w:txbxContent>\(p("文本框资料"))</w:txbxContent></w:drawing></w:r></w:p>")
        try check(hidden.map(\.text) == ["可见"], "隐藏文本及浮动内容不混入正文")
        let field = try read(p("可见") + "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText>DATE</w:instrText></w:r><w:r><w:t>过期缓存</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>")
        try check(field.map(\.text) == ["可见"], "不读取域的过期缓存")
        try reject("<w:ins>\(p("旧值"))</w:ins>")
        try reject("<w:p><w:r><w:drawing/></w:r></w:p>")
        try reject("<w:altChunk/>")
        let restored = try JSONDecoder().decode([OCRBlock].self, from: JSONEncoder().encode(rows))
        let restoredMaterial = try JSONDecoder().decode(MaterialAsset.self, from: JSONEncoder().encode(material))
        try check(restored == rows && restoredMaterial.kind == .docx, "Word 材料与原文快照恢复")
        let sourceURL = try fixture(table)
        let before = try Data(contentsOf: sourceURL)
        _ = try reader.read(from: sourceURL, materialID: materialID)
        try check(try Data(contentsOf: sourceURL) == before, "读取保留原文件")
        return count
    }
}
