import Foundation

/// 按原格式分派；PDF 的排版校验和 Word 的内容校验保持各自语义。
struct GeneralFormEngine: FormParsing, FormWriting, FormPreflighting {
    func parse(formURL: URL) async throws -> GeneralFormDocument {
        switch formURL.pathExtension.lowercased() {
        case "pdf": try await PDFFormEngine().parse(formURL: formURL)
        case "docx": try await DOCXFormEngine().parse(formURL: formURL)
        default: throw BiaoXiaError.unsupportedForm
        }
    }

    func write(document: GeneralFormDocument, sourceURL: URL, destinationURL: URL) async throws {
        try validateFormat(document, sourceURL: sourceURL)
        guard destinationURL.pathExtension.lowercased() == document.effectiveFormat.rawValue else {
            throw BiaoXiaError.unsupportedForm
        }
        switch document.effectiveFormat {
        case .pdf: try await PDFFormEngine().write(document: document, sourceURL: sourceURL, destinationURL: destinationURL)
        case .docx: try await DOCXFormEngine().write(document: document, sourceURL: sourceURL, destinationURL: destinationURL)
        }
    }

    func preflight(document: GeneralFormDocument, sourceURL: URL) throws -> [PDFFieldLayoutResult] {
        try validateFormat(document, sourceURL: sourceURL)
        return switch document.effectiveFormat {
        case .pdf: try PDFFormEngine().preflight(document: document, sourceURL: sourceURL)
        case .docx: try DOCXFormEngine().preflight(document: document, sourceURL: sourceURL)
        }
    }

    private func validateFormat(_ document: GeneralFormDocument, sourceURL: URL) throws {
        guard sourceURL.pathExtension.lowercased() == document.effectiveFormat.rawValue else { throw BiaoXiaError.unsupportedForm }
    }
}
