import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

protocol OCRServing: Sendable {
    func recognize(
        materials: [MaterialAsset],
        existingBlocks: [OCRBlock],
        progress: @escaping @Sendable (
            _ completedPages: Int,
            _ totalPages: Int,
            _ accumulatedBlocks: [OCRBlock]
        ) async -> Void
    ) async throws -> [OCRBlock]
}

actor VisionOCRService: OCRServing {
    private let fileResolver: any MaterialFileResolving
    private let maximumPixelDimension = 3_000

    init(fileResolver: any MaterialFileResolving) {
        self.fileResolver = fileResolver
    }

    func recognize(
        materials: [MaterialAsset],
        existingBlocks: [OCRBlock],
        progress: @escaping @Sendable (
            _ completedPages: Int,
            _ totalPages: Int,
            _ accumulatedBlocks: [OCRBlock]
        ) async -> Void
    ) async throws -> [OCRBlock] {
        let totalPages = materials.reduce(0) { $0 + max(1, $1.pageCount) }
        let completedPageKeys = Set(existingBlocks.map {
            pageKey(materialID: $0.materialID, pageIndex: $0.pageIndex)
        })
        var completedPages = min(completedPageKeys.count, totalPages)
        var blocks = existingBlocks

        for material in materials {
            try Task.checkCancellation()
            let url = try await fileResolver.absoluteURL(for: material.relativePath)

            switch material.kind {
            case .docx:
                let key = pageKey(materialID: material.id, pageIndex: -1)
                guard !completedPageKeys.contains(key) else { continue }
                // 整份 Word 一次读取成功后才发布，恢复任务不会重复追加半份文档。
                let textBlocks = try DOCXMaterialReader().read(from: url, materialID: material.id)
                try Task.checkCancellation()
                blocks += textBlocks
                completedPages += 1
                await progress(completedPages, totalPages, blocks)

            case .image:
                let key = pageKey(materialID: material.id, pageIndex: 0)
                guard !completedPageKeys.contains(key) else { continue }
                let image = try makeThumbnail(from: url)
                blocks += try await recognize(
                    image: image,
                    materialID: material.id,
                    pageIndex: 0
                )
                completedPages += 1
                await progress(completedPages, totalPages, blocks)

            case .pdf:
                guard let document = PDFDocument(url: url) else {
                    throw BiaoXiaError.unreadableDocument(material.displayName)
                }
                for pageIndex in 0..<document.pageCount {
                    try Task.checkCancellation()
                    let key = pageKey(
                        materialID: material.id,
                        pageIndex: pageIndex
                    )
                    guard !completedPageKeys.contains(key) else { continue }
                    guard let page = document.page(at: pageIndex) else { continue }
                    let textBlocks = nativeTextBlocks(
                        from: page,
                        materialID: material.id,
                        pageIndex: pageIndex
                    )
                    // Keep the embedded text for exact copy/search and also run Vision.
                    // Some PDFs expose only part of the visible content in their text layer.
                    blocks += textBlocks
                    let image = try render(page: page)
                    blocks += try await recognize(
                        image: image,
                        materialID: material.id,
                        pageIndex: pageIndex
                    )
                    completedPages += 1
                    await progress(completedPages, totalPages, blocks)
                }
            }
        }

        return blocks
    }

    private func pageKey(materialID: UUID, pageIndex: Int) -> String {
        "\(materialID.uuidString.lowercased()):\(pageIndex)"
    }

    private func recognize(
        image: CGImage,
        materialID: UUID,
        pageIndex: Int
    ) async throws -> [OCRBlock] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "en")
        ]
        request.usesLanguageCorrection = true

        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let topLeftRect = observation.boundingBox.verticallyFlipped().cgRect
            return OCRBlock(
                text: text,
                pageIndex: pageIndex,
                boundingBox: NormalizedRect(topLeftRect),
                confidence: Double(candidate.confidence),
                materialID: materialID
            )
        }
    }

    /// Prefer the PDF text layer when it contains usable text. Scanned pages have no
    /// selections and fall back to Vision OCR above.
    private func nativeTextBlocks(
        from page: PDFPage,
        materialID: UUID,
        pageIndex: Int
    ) -> [OCRBlock] {
        guard page.numberOfCharacters > 0,
              let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else {
            return []
        }
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let bounds = line.bounds(for: page)
            let normalized = CGRect(
                x: (bounds.minX - pageBounds.minX) / pageBounds.width,
                y: (pageBounds.maxY - bounds.maxY) / pageBounds.height,
                width: bounds.width / pageBounds.width,
                height: bounds.height / pageBounds.height
            )
            return OCRBlock(
                text: text,
                pageIndex: pageIndex,
                boundingBox: NormalizedRect(normalized),
                confidence: 1,
                materialID: materialID
            )
        }
    }

    private func makeThumbnail(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
                ] as CFDictionary
              ) else {
            throw BiaoXiaError.unreadableDocument(url.lastPathComponent)
        }
        return image
    }

    private func render(page: PDFPage) throws -> CGImage {
        let pageBounds = page.bounds(for: .mediaBox)
        let longestSide = max(pageBounds.width, pageBounds.height)
        let scale = min(CGFloat(maximumPixelDimension) / longestSide, 4)
        let pixelWidth = max(1, Int((pageBounds.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((pageBounds.height * scale).rounded(.up)))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw BiaoXiaError.unreadableDocument("PDF 页面")
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else {
            throw BiaoXiaError.unreadableDocument("PDF 页面")
        }
        return image
    }
}
