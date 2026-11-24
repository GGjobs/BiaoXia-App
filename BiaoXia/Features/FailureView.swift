import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct FailureView: View {
    @Environment(\.modelContext) private var modelContext
    let flow: FlowStore
    @State private var isFormImporterPresented = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.orange)
            Text("这一步没有完成")
                .font(.title.bold())
            Text(flow.snapshot?.lastError ?? "发生未知错误")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("已导入材料和识别结果不会被清除。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("重试") {
                Task { await flow.retry(in: modelContext) }
            }
            .buttonStyle(PrimaryButtonStyle())
            if flow.snapshot?.generalForm != nil {
                Button("返回核对与修正") { Task { await flow.returnToFormReview(in: modelContext) } }
            }
            if flow.snapshot?.form != nil && flow.snapshot?.generalForm == nil {
                Button("更换表格") { isFormImporterPresented = true }
            }
            if flow.hasUnsavedTaskChanges {
                Text("任务尚未保存")
                    .foregroundStyle(.orange)
                Button("重试保存") {
                    Task { await flow.retrySaving(in: modelContext) }
                }
            }
            Button("返回首页") {
                flow.closeTask()
            }
        }
        .padding(28)
        .navigationBarBackButtonHidden()
        .fileImporter(isPresented: $isFormImporterPresented, allowedContentTypes: FormImportTypes.supported) { result in
            switch result {
            case .success(let url):
                Task { await flow.importForm(from: url, in: modelContext) }
            case .failure(let error):
                flow.transientError = error.localizedDescription
            }
        }
    }
}
