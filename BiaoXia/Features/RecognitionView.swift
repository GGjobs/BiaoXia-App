import SwiftData
import SwiftUI

struct RecognitionView: View {
    @Environment(\.modelContext) private var modelContext
    let flow: FlowStore

    private var progress: Double {
        guard let snapshot = flow.snapshot,
              snapshot.recognitionTotalPages > 0 else { return 0 }
        return Double(snapshot.recognitionCompletedPages)
            / Double(snapshot.recognitionTotalPages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(
                step: "第 2 步，共 5 步",
                title: "本地识别",
                detail: "本机识别 PDF/图片并读取 Word 正文，个人材料和提取结果不会离开设备。"
            )

            VStack(alignment: .leading, spacing: 14) {
                ProgressView(value: progress)
                    .tint(.teal)
                HStack {
                    Text("识别进度")
                    Spacer()
                    Text("\(flow.snapshot?.recognitionCompletedPages ?? 0) / \(flow.snapshot?.recognitionTotalPages ?? 0) 个处理单元")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            .padding()
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if let materials = flow.snapshot?.materials {
                ForEach(materials) { material in
                    HStack {
                        Image(systemName: material.kind.systemImage)
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading) {
                            Text(material.displayName)
                                .lineLimit(1)
                            Text(material.kind == .docx ? "DOCX 正文" : "\(material.pageCount) 页")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
            }

            Spacer()
            Label("可切换到其他 App，返回后任务仍会保留", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .navigationBarBackButtonHidden()
        .task(id: flow.snapshot?.id) {
            if flow.snapshot?.status == .imported {
                await flow.startRecognition(in: modelContext)
            }
        }
    }
}
