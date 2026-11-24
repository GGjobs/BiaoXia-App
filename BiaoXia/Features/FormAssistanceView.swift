import SwiftUI
import SwiftData

struct FormAssistanceView: View {
    @Environment(\.modelContext) private var context
    let field: DynamicFormField
    let flow: FlowStore
    let sourceURL: URL?
    @State private var includeAll = false
    @State private var showLocation = false
    @State private var replaceAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if field.wordAnchor == nil, sourceURL != nil {
                Button("查看或框选填写位置") { showLocation = true }
            }
            FormPlanningEntry(flow: flow, fieldID: field.id)
            if field.options.isEmpty {
                DisclosureGroup("选择资料，组合本地答案") {
                    Toggle("查看全部人物的资料", isOn: $includeAll)
                        .font(.caption)
                    Text("这些资料仅用于本地组合，不受 AI 可用资料设置影响。勾选不会发送或替换已有答案。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(flow.records(for: field, includeAll: includeAll)) { record in
                        Button {
                            Task { await flow.toggleRecord(record.id, fieldID: field.id, in: context) }
                        } label: {
                            Label(record.displayValue, systemImage: (field.selectedRecordIDs ?? []).contains(record.id) ? "checkmark.circle.fill" : "circle")
                                .font(.caption).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain)
                    }
                    Button("组合为本地建议") {
                        if field.answer?.modifiedByUser == true || field.answer?.confirmationState == .confirmed { replaceAnswer = true }
                        else { Task { await flow.combineSelectedRecords(fieldID: field.id, in: context) } }
                    }
                }
                if let draft = field.compositionDraft {
                    AnswerDraftReview(field: field, draft: draft, flow: flow)
                }
            }
            if !(flow.snapshot?.generalForm?.retainedAnswers ?? []).isEmpty {
                Menu("恢复旧任务答案到此字段") {
                    ForEach(flow.snapshot?.generalForm?.retainedAnswers ?? []) { retained in
                        Button("\(retained.label) · \(retained.pageIndex.map { "第 \($0 + 1) 页" } ?? "Word")") {
                            Task { await flow.restoreAnswer(retained.id, to: field.id, in: context) }
                        }
                    }
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal)
        .confirmationDialog("用所选资料替换当前答案为待确认建议？", isPresented: $replaceAnswer, titleVisibility: .visible) {
            Button("替换为待确认建议") { Task { await flow.combineSelectedRecords(fieldID: field.id, replacingConfirmed: true, in: context) } }
            Button("保留当前答案", role: .cancel) {}
        }
        .sheet(isPresented: $showLocation) {
            if let sourceURL { PDFLocationSheet(url: sourceURL, field: field, flow: flow) }
        }
    }
}

private struct AnswerDraftReview: View {
    @Environment(\.modelContext) private var context
    let field: DynamicFormField
    let draft: AnswerCompositionDraft
    let flow: FlowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("此前保存的整理草稿").font(.headline)
            Text("可继续核对已有结果。重新使用 AI 时，请点击“AI 填写此空”，使用当前允许的建档资料。")
                .font(.footnote)
            if let error = draft.error { Text(error).foregroundStyle(.orange) }
            if let response = draft.response {
                Text("返回草稿：确认采用后才会写入").font(.headline)
                if response.answer != nil {
                    TextField("编辑答案草稿", text: Binding(get: { currentDraft?.editedAnswer ?? "" }, set: { value in
                        Task { await flow.updateCompositionDraft(fieldID: field.id, edit: { $0.editedAnswer = value }, in: context) }
                    }), axis: .vertical).lineLimit(3...10)
                    Text("依据：\(response.sourceIDs.joined(separator: "、"))").font(.caption)
                    Button("核对无误，采用此答案") { Task { await flow.adoptComposition(fieldID: field.id, in: context) } }
                        .accessibilityIdentifier("adopt-answer-\(field.id)")
                }
                if !response.missingInformation.isEmpty { Text(response.missingInformation.joined(separator: "；")).foregroundStyle(.orange) }
            }
            Button("放弃此前草稿", role: .destructive) {
                Task { await flow.discardComposition(fieldID: field.id, in: context) }
            }.disabled(flow.isWorking)
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private var currentDraft: AnswerCompositionDraft? {
        flow.snapshot?.generalForm?.fields.first { $0.id == field.id }?.compositionDraft
    }
}

struct FormExportReview: View {
    let document: GeneralFormDocument
    var body: some View {
        let summary = FormExportSummary(document: document)
        VStack(alignment: .leading, spacing: 8) {
            Text("已确认 \(summary.written) 项 · 明确留空 \(summary.leftBlank) 项 · 未处理 \(summary.pending) 项")
            Text("仅统计已发现的字段，请对照原表检查遗漏。")
            ForEach(document.diagnostics ?? []) { issue in
                Text("第 \(issue.pageIndex + 1) 页：\(issue.message)").foregroundStyle(.orange)
            }
            if !(document.retainedAnswers ?? []).isEmpty { Text("还有旧答案尚未关联新位置。").foregroundStyle(.orange) }
        }.font(.footnote)
    }
}
