import SwiftUI

struct ProfileRecognitionView: View {
    let flow: FlowStore

    private var progress: Double {
        let total = flow.profileLibrary.recognitionTotalPages
        guard total > 0 else { return 0 }
        return Double(flow.profileLibrary.recognitionCompletedPages) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(
                step: "第 1 步，共 2 步",
                title: "本地识别材料",
                detail: "正在本机识别 PDF/图片并读取 Word 正文，个人材料和提取结果不会发送到云端。"
            )
            ProgressView(value: progress)
                .tint(.teal)
            Text("\(flow.profileLibrary.recognitionCompletedPages) / \(flow.profileLibrary.recognitionTotalPages) 个处理单元")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            ForEach(flow.profileLibrary.materials) { material in
                Label(material.displayName, systemImage: material.kind.systemImage)
            }
            Spacer()
            Label("识别结果会自动保存，可在完成后逐字段核对", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .navigationBarBackButtonHidden()
    }
}
