import Foundation
import CryptoKit
// libxml2 的 allocator 函数指针是 C 全局变量；原型不更换 allocator，且串行调用。
@preconcurrency import libxml2
import zlib

// 基于仓库 T03 原型的本地包读写。限制解压体积并校验 CRC，避免把不可信 ZIP 写到文件系统。
// 只替换正文部件，其余样式、媒体、关系部件的解压字节保持不变。
enum WordPackageError: LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        "暂不支持此 Word 文件的结构或格式，请使用无修订的普通 DOCX 文件。原文件已保留。"
    }
}
func wordRequire(_ condition: Bool, _ reason: String) throws {
    if !condition { throw WordPackageError.rejected(reason) }
}
func wordFingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct WordPackage {
    struct Entry { let name: String; let data: Data }
    let entries: [Entry]
    init(_ source: Data) throws {
        let b = [UInt8](source)
        func n(_ p: Int, _ width: Int) throws -> Int {
            try wordRequire(p >= 0 && p + width <= b.count, "truncated ZIP")
            return (0..<width).reduce(0) { $0 | Int(b[p + $1]) << (8 * $1) }
        }
        try wordRequire(b.count >= 22 && b.count <= 32_000_000, "package size")
        let end = try stride(from: b.count - 22, through: max(0, b.count - 65557), by: -1).first {
            try n($0, 4) == 0x06054b50 && $0 + 22 + n($0 + 20, 2) == b.count
        }
        guard let end else { throw WordPackageError.rejected("ZIP end record") }
        try wordRequire(n(end + 4, 2) == 0 && n(end + 6, 2) == 0, "multipart ZIP")
        let count = try n(end + 10, 2)
        try wordRequire(count > 0 && count < 2048 && n(end + 8, 2) == count, "ZIP entry count")
        var cursor = try n(end + 16, 4)
        let centralEnd = try cursor + n(end + 12, 4)
        try wordRequire(centralEnd == end, "ZIP64 or invalid directory")
        var result: [Entry] = [], names = Set<String>(), total = 0
        for _ in 0..<count {
            try wordRequire(n(cursor, 4) == 0x02014b50, "ZIP directory signature")
            let flags = try n(cursor + 8, 2), method = try n(cursor + 10, 2)
            let crc = try n(cursor + 16, 4), compressed = try n(cursor + 20, 4)
            let size = try n(cursor + 24, 4), length = try n(cursor + 28, 2)
            let extra = try n(cursor + 30, 2), comment = try n(cursor + 32, 2)
            let offset = try n(cursor + 42, 4)
            total += size
            try wordRequire(flags & ~0x0808 == 0 && [0, 8].contains(method), "ZIP encryption/flags/method")
            try wordRequire(size <= 8_000_000 && total <= 32_000_000, "ZIP expanded size")
            try wordRequire(cursor + 46 + length + extra + comment <= centralEnd, "ZIP directory bounds")
            guard let name = String(bytes: b[(cursor + 46)..<(cursor + 46 + length)], encoding: .utf8) else {
                throw WordPackageError.rejected("ZIP name encoding")
            }
            try wordRequire(!name.hasPrefix("/") && !name.contains("\\") && !name.split(separator: "/").contains("..") && !name.contains("\0") && names.insert(name).inserted, "unsafe/duplicate ZIP name")
            try wordRequire(n(offset, 4) == 0x04034b50 && n(offset + 8, 2) == method && n(offset + 6, 2) == flags, "ZIP local header")
            let localLength = try n(offset + 26, 2)
            let start = try offset + 30 + localLength + n(offset + 28, 2)
            try wordRequire(start + compressed <= centralEnd && offset + 30 + localLength <= b.count, "ZIP local bounds")
            try wordRequire(Array(b[(offset + 30)..<(offset + 30 + localLength)]) == Array(name.utf8), "ZIP local name mismatch")
            let packed = Array(b[start..<(start + compressed)])
            var unpacked = [UInt8](repeating: 0, count: max(size, 1))
            if method == 0 {
                try wordRequire(compressed == size, "stored ZIP size")
                unpacked = packed
            } else {
                var stream = z_stream()
                let code = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                try wordRequire(code == Z_OK, "inflate init")
                defer { inflateEnd(&stream) }
                let status = packed.withUnsafeBytes { input in
                    unpacked.withUnsafeMutableBytes { output in
                        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(compressed)
                        stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(max(size, 1))
                        return inflate(&stream, Z_FINISH)
                    }
                }
                try wordRequire(status == Z_STREAM_END && stream.total_out == size && stream.total_in == compressed, "invalid deflate")
                unpacked = Array(unpacked.prefix(size))
            }
            let actual = unpacked.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(size)) }
            try wordRequire(actual == crc, "ZIP CRC")
            result.append(Entry(name: name, data: Data(unpacked)))
            cursor += 46 + length + extra + comment
        }
        try wordRequire(cursor == centralEnd, "ZIP directory remainder")
        entries = result
    }
    func part(_ name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else { throw WordPackageError.rejected("missing part") }
        return entry.data
    }
    // 重新封装 ZIP，但非目标部件解压字节完全不变；无损保留样式、关系、媒体。
    // 使用 stored 输出；整个包的内存预算由读取时的体积上限约束。
    func replacingDocument(_ document: Data) -> Data {
        var output = Data(), directory = Data()
        func append(_ value: Int, _ width: Int, to data: inout Data) {
            for i in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
        }
        for entry in entries {
            let bytes = entry.name == "word/document.xml" ? document : entry.data
            let name = Data(entry.name.utf8), offset = output.count
            let crc = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) }
            for (v, w) in [(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,2),(33,2),(Int(crc),4),(bytes.count,4),(bytes.count,4),(name.count,2),(0,2)] { append(v,w,to:&output) }
            output.append(name); output.append(bytes)
            for (v, w) in [(0x02014b50,4),(20,2),(20,2),(0x800,2),(0,2),(0,2),(33,2),(Int(crc),4),(bytes.count,4),(bytes.count,4),(name.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(offset,4)] { append(v,w,to:&directory) }
            directory.append(name)
        }
        let start = output.count
        output.append(directory)
        for (v,w) in [(0x06054b50,4),(0,2),(0,2),(entries.count,2),(entries.count,2),(directory.count,4),(start,4),(0,2)] { append(v,w,to:&output) }
        return output
    }
}

final class WordXMLDocument {
    let doc: xmlDocPtr
    init(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw WordPackageError.rejected("XML encoding/DTD")
        }
        guard let parsed = text.withCString({ xmlReadMemory($0, Int32(data.count), nil, nil, Int32(XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue | XML_PARSE_NOWARNING.rawValue)) }) else {
            throw WordPackageError.rejected("malformed XML")
        }
        doc = parsed
    }
    deinit { xmlFreeDoc(doc) }
    func nodes(_ path: String) throws -> [xmlNodePtr] {
        guard let context = xmlXPathNewContext(doc) else { throw WordPackageError.rejected("XPath context") }
        defer { xmlXPathFreeContext(context) }
        xmlXPathRegisterNs(context, "w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
        guard let value = xmlXPathEvalExpression(path, context) else { throw WordPackageError.rejected("XPath expression") }
        defer { xmlXPathFreeObject(value) }
        guard let set = value.pointee.nodesetval else { return [] }
        return (0..<Int(set.pointee.nodeNr)).compactMap { set.pointee.nodeTab[$0] }
    }
    func text(_ node: xmlNodePtr) -> String {
        guard let content = xmlNodeGetContent(node) else { return "" }
        defer { xmlFree(content) }
        return String(cString: content)
    }
    func serialized() -> Data {
        var pointer: UnsafeMutablePointer<xmlChar>?, size: Int32 = 0
        xmlDocDumpMemoryEnc(doc, &pointer, &size, "UTF-8")
        guard let pointer else { return Data() }
        defer { xmlFree(pointer) }
        return Data(bytes: pointer, count: Int(size))
    }
}
