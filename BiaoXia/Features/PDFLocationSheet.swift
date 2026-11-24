import PDFKit
import SwiftUI
import SwiftData

struct PDFLocationSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let field: DynamicFormField?
    let flow: FlowStore
    @State private var drawing = false
    @State private var label = ""
    @State private var selected: PDFFieldAnchor?

    var body: some View {
        NavigationStack {
            VStack {
                if field == nil { TextField("新增字段名称", text: $label).textFieldStyle(.roundedBorder).padding(.horizontal) }
                Text("先翻到目标页，再开启框选。拖动框住答案区域，避开标签与原有文字。").font(.footnote).padding(.horizontal)
                Toggle("框选模式（暂时停止翻页）", isOn: $drawing).padding(.horizontal)
                PDFRegionCanvas(url: url, anchor: selected ?? field?.anchors.first, drawing: drawing) { selected = $0 }
                Button("保存此填写区域") {
                    guard let selected else { return }
                    Task {
                        if let field {
                            await flow.adjustPDFRegion(fieldID: field.id, anchorIndex: 0, pageIndex: selected.pageIndex, rect: selected.rect, in: context)
                        } else {
                            await flow.addManualPDFField(label: label, pageIndex: selected.pageIndex, rect: selected.rect, in: context)
                        }
                        dismiss()
                    }
                }.disabled(selected == nil || (field == nil && label.trimmingCharacters(in: .whitespaces).isEmpty))
                    .buttonStyle(.borderedProminent).padding()
            }
            .navigationTitle(field?.label ?? "补充漏识别字段")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

private struct PDFRegionCanvas: UIViewRepresentable {
    let url: URL
    let anchor: PDFFieldAnchor?
    let drawing: Bool
    let onSelect: (PDFFieldAnchor) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.document = PDFDocument(url: url); view.autoScales = true
        view.displayMode = .singlePageContinuous
        let gesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        gesture.isEnabled = drawing; view.addGestureRecognizer(gesture)
        context.coordinator.gesture = gesture; context.coordinator.view = view
        if let anchor, let page = view.document?.page(at: anchor.pageIndex) { view.go(to: page) }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.gesture?.isEnabled = drawing
        func scrolling(_ parent: UIView) {
            if let scroll = parent as? UIScrollView { scroll.isScrollEnabled = !drawing }
            parent.subviews.forEach(scrolling)
        }
        scrolling(view)
        context.coordinator.show(anchor)
    }
    @MainActor final class Coordinator: NSObject {
        weak var view: PDFView?
        var gesture: UIPanGestureRecognizer?
        var start: CGPoint?
        var startPage: PDFPage?
        var annotation: PDFAnnotation?
        let onSelect: (PDFFieldAnchor) -> Void
        init(onSelect: @escaping (PDFFieldAnchor) -> Void) { self.onSelect = onSelect }
        func show(_ anchor: PDFFieldAnchor?) {
            if let annotation { annotation.page?.removeAnnotation(annotation) }
            guard let view, let anchor, let page = view.document?.page(at: anchor.pageIndex) else { return }
            let annotation = PDFAnnotation(bounds: PDFFormEngine.pdfBounds(from: anchor.rect, pageBounds: page.bounds(for: .mediaBox)), forType: .square, withProperties: nil)
            annotation.color = .systemTeal; annotation.interiorColor = UIColor.systemTeal.withAlphaComponent(0.12)
            page.addAnnotation(annotation); self.annotation = annotation
        }
        @objc func drag(_ gesture: UIPanGestureRecognizer) {
            guard let view, let document = view.document else { return }
            let point = gesture.location(in: view)
            if gesture.state == .began {
                startPage = view.page(for: point, nearest: false)
                start = startPage.map { view.convert(point, to: $0) }
            }
            guard let page = startPage, let start, view.page(for: point, nearest: false) === page else { return }
            let end = view.convert(point, to: page)
            let bounds = page.bounds(for: .mediaBox)
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
            guard rect.width >= 16, rect.height >= 16 else { return }
            let anchor = PDFFieldAnchor(pageIndex: document.index(for: page), rect: NormalizedRect(x: (rect.minX-bounds.minX)/bounds.width, y: 1-(rect.maxY-bounds.minY)/bounds.height, width: rect.width/bounds.width, height: rect.height/bounds.height), kind: .manuallyAdjustedRegion, confidence: 1)
            show(anchor)
            if gesture.state == .ended { onSelect(anchor) }
        }
    }
}
