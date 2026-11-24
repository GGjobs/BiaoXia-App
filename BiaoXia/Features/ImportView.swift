import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    let flow: FlowStore
    @State private var isImporterPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(
                    step: "第 1 步，共 3 步",
                    title: "选择空白 PDF 或 Word 表格",
                    detail: "支持文字 PDF 和原生 DOCX；原文件与个人资料保存在本机。"
                )

                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 46))
                        .foregroundStyle(.teal)
                    Text("选择尚未填写的表格")
                        .font(.headline)
                    Text("表匣会离线识别字段，并用“我的信息”匹配答案")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))

                Text("Word 首批支持普通表格和明确占位符；生成可编辑 DOCX 后，请用 Word/WPS 核对最终版式。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("将使用 \(flow.profile.fullName) 的演示档案")
                            .font(.subheadline.weight(.semibold))
                        Text("默认本地填写；仅在你核对并发送后，选中片段才用于云端整理")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if flow.isFormImportPresented {
                    if let form = flow.snapshot?.form {
                        Label(form.displayName, systemImage: "doc.text")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button("继续核对当前表格") {
                        flow.isFormImportPresented = false
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(flow.isWorking)
                }

                Button {
                    isImporterPresented = true
                } label: {
                    Label("从“文件”选择 PDF 或 DOCX", systemImage: "folder")
                }
                .accessibilityIdentifier("choose-blank-form")
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
        }
        .navigationTitle("新任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(flow.isFormImportPresented ? "返回首页" : "取消") { flow.closeTask() }
                    .disabled(flow.isWorking)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: FormImportTypes.supported,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task { await flow.importForm(from: url, in: modelContext) }
            case let .failure(error):
                flow.transientError = error.localizedDescription
            }
        }
        .overlay {
            if flow.isWorking {
                ProgressView("正在读取空白表…")
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

/// 待填写模板仅支持 PDF/DOCX；个人材料入口另外允许图片。
enum FormImportTypes {
    static let supported: [UTType] = [.pdf, UTType(filenameExtension: "docx") ?? .data]
}
