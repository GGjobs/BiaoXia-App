import Foundation
import PDFKit
import UIKit

protocol PDFExporting: Sendable {
    func export(
        taskID: UUID,
        sourceFormRelativePath: String?,
        resolvedFields: [ResolvedField],
        formValues: [FormFieldValue]?
    ) async throws -> (url: URL, relativePath: String)
}

actor PDFExportService: PDFExporting {
    private let fileStore: any TaskFileStoring

    init(fileStore: any TaskFileStoring) {
        self.fileStore = fileStore
    }

    func export(
        taskID: UUID,
        sourceFormRelativePath: String?,
        resolvedFields: [ResolvedField],
        formValues: [FormFieldValue]? = nil
    ) async throws -> (url: URL, relativePath: String) {
        let templateURL: URL
        if let sourceFormRelativePath {
            templateURL = try await fileStore.absoluteURL(
                for: sourceFormRelativePath,
                taskID: taskID
            )
        } else if let bundledTemplate = Bundle.main.url(
            forResource: "competition_registration_template",
            withExtension: "pdf"
        ) {
            templateURL = bundledTemplate
        } else {
            throw BiaoXiaError.resourceMissing("competition_registration_template.pdf")
        }
        guard let manifestURL = Bundle.main.url(
            forResource: "template_manifest",
            withExtension: "json"
        ) else {
            throw BiaoXiaError.resourceMissing("template_manifest.json")
        }
        guard let document = PDFDocument(url: templateURL) else {
            throw BiaoXiaError.unreadableDocument("上传的报名表")
        }

        let manifest = try JSONDecoder().decode(
            TemplateManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        var valuesByKey = Dictionary(uniqueKeysWithValues: resolvedFields.map { ($0.key.rawValue, $0.value) })
        for value in formValues ?? [] {
            valuesByKey[value.fieldID] = value.value
        }

        for fieldManifest in manifest.fields {
            guard let page = document.page(at: fieldManifest.pageIndex),
                  let value = valuesByKey[fieldManifest.key],
                  !value.isEmpty else { continue }

            let pageBounds = page.bounds(for: .mediaBox)
            let annotationBounds = Self.pdfBounds(
                from: fieldManifest.rect,
                pageBounds: pageBounds
            )
            let annotation = PDFAnnotation(
                bounds: annotationBounds,
                forType: .freeText,
                withProperties: nil
            )
            annotation.contents = value
            annotation.font = fittedFont(
                text: value,
                bounds: annotationBounds,
                preferredSize: fieldManifest.fontSize,
                minimumSize: fieldManifest.minimumFontSize,
                maximumLines: fieldManifest.maximumLines
            )
            annotation.fontColor = .black
            annotation.color = .clear
            annotation.alignment = fieldManifest.alignment == "center" ? .center : .left
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            page.addAnnotation(annotation)
        }

        let name = valuesByKey[FieldKey.fullName.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = sanitizeFileName(name?.isEmpty == false ? name! : "未命名")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let fileName = "表匣_竞赛报名表_\(safeName)_\(formatter.string(from: .now)).pdf"
        let destination = try await fileStore.exportURL(fileName: fileName, taskID: taskID)

        guard document.write(
            to: destination,
            withOptions: [.burnInAnnotationsOption: true]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (destination, "exports/\(fileName)")
    }

    static func pdfBounds(from rect: NormalizedRect, pageBounds: CGRect) -> CGRect {
        CGRect(
            x: pageBounds.minX + rect.x * pageBounds.width,
            y: pageBounds.minY + (1 - rect.y - rect.height) * pageBounds.height,
            width: rect.width * pageBounds.width,
            height: rect.height * pageBounds.height
        )
    }

    private func fittedFont(
        text: String,
        bounds: CGRect,
        preferredSize: Double,
        minimumSize: Double,
        maximumLines: Int
    ) -> UIFont {
        var size = CGFloat(preferredSize)
        let minimum = CGFloat(minimumSize)
        let constrainedSize = CGSize(
            width: bounds.width,
            height: bounds.height * CGFloat(max(1, maximumLines))
        )
        while size > minimum {
            let font = UIFont.systemFont(ofSize: size)
            let measured = (text as NSString).boundingRect(
                with: constrainedSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            if measured.width <= constrainedSize.width,
               measured.height <= constrainedSize.height {
                return font
            }
            size -= 0.5
        }
        return UIFont.systemFont(ofSize: minimum)
    }

    private func sanitizeFileName(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"[/\\:*?"<>|]"#,
            with: "_",
            options: .regularExpression
        )
    }
}
