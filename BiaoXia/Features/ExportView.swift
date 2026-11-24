import PDFKit
import SwiftUI
import SwiftData

struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    let flow: FlowStore
    @State private var exportURL: URL?

    private var isWord: Bool { flow.snapshot?.form?.isWord == true }

    private var isProfileMode: Bool {
        flow.snapshot?.effectiveInputMode == .reusableProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                step: isProfileMode ? "第 3 步，共 3 步" : "第 5 步，共 5 步",
                title: isWord ? "Word 内容已写入" : (flow.snapshot?.exportSummary?.isPartial == true ? "已生成部分填写结果" : "已生成填写结果"),
                detail: isWord
                    ? "已生成可编辑 DOCX。请用 Word/WPS 核对最终版式后再提交。"
                    : "已确认内容已写入 PDF。请逐页检查填写位置和遗漏后再使用。"
            )

            if let summary = flow.snapshot?.exportSummary {
                Text("已写入 \(summary.written) 项 · 明确留空 \(summary.leftBlank) 项 · 未处理 \(summary.pending) 项")
                    .font(.footnote)
                if summary.diagnosticCount > 0 { Text("还有 \(summary.diagnosticCount) 项解析或旧答案问题待核对。").font(.footnote).foregroundStyle(.orange) }
            }
            if flow.hasUnsavedTaskChanges {
                Text("文件已生成，但任务完成状态尚未保存。请重试保存后再离开。")
                    .foregroundStyle(.orange)
                Button("重试保存") {
                    Task { await flow.retrySaving(in: modelContext) }
                }
                .buttonStyle(.borderedProminent)
            }

            if flow.snapshot?.generalForm != nil {
                Button("返回核对与修正") { Task { await flow.returnToFormReview(in: modelContext) } }
            }
            if let exportURL {
                if isWord {
                    WordExportSummary()
                } else {
                    PDFPreview(url: exportURL)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.quaternary)
                        }
                }

                ShareLink(item: exportURL) {
                    Label(isWord ? "保存 Word 或用 Word/WPS 打开" : "导出或分享 PDF", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier(isWord ? "share-filled-word" : "share-filled-pdf")
                .buttonStyle(PrimaryButtonStyle())
            } else {
                ProgressView("正在载入预览…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回首页") { flow.closeTask() }
            }
        }
        .task {
            exportURL = await flow.exportFileURL()
        }
    }
}

private struct PDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}

private struct WordExportSummary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "doc.text.fill")
                .font(.largeTitle)
                .foregroundStyle(.teal)
            Text("已保留原文档结构与样式，写入已确认内容。")
            Text("App 尚未验证 Word 的分页、行高和文字裁切。请保存文件，在 Word/WPS 中检查，也可继续编辑未识别的项目。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
