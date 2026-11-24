import SwiftUI
import SwiftData

struct FormPlanningEntry: View {
    @Environment(\.modelContext) private var context
    let flow: FlowStore
    var fieldID: String? = nil
    @State private var presented = false
    @State private var replacingDraft = false
    var body: some View {
        Button(fieldID == nil ? "AI 填写整表" : "AI 填写此空", systemImage: "sparkles") {
            if let draft = flow.snapshot?.generalForm?.planDraft, draft.scopeFieldID != fieldID {
                replacingDraft = true
            } else {
                Task {
                    if flow.snapshot?.generalForm?.planDraft == nil {
                        await flow.beginFormPlan(fieldID: fieldID, in: context)
                    }
                    presented = true
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(flow.isWorking || flow.isUpdatingAISharing)
        .accessibilityIdentifier(fieldID.map { "plan-field-entry-\($0)" } ?? "plan-form-entry")
        .confirmationDialog("重新准备 AI 填写？", isPresented: $replacingDraft, titleVisibility: .visible) {
            Button("重新准备") {
                Task {
                    await flow.beginFormPlan(fieldID: fieldID, in: context)
                    presented = true
                }
            }
            Button("保留当前草稿", role: .cancel) {}
        } message: {
            Text("将清除上一轮未采用的建议，已采用答案保留。整表和单空仍共用同一套 AI 可用资料设置。")
        }
        .sheet(isPresented: $presented) { FormPlanningView(flow: flow, fieldID: fieldID) }
    }
}

private struct FormPlanningView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let flow: FlowStore
    let fieldID: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var selectedResults: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let document = flow.snapshot?.generalForm, let draft = document.planDraft {
                        ProfileAIPermissionsEntry(flow: flow) { flow.refreshFormPlanSources() }
                        FormPlanProgressCard(flow: flow, draft: draft, cancel: { requestTask?.cancel() })
                        if !flow.isWorking && !draft.batches.isEmpty {
                            FormPlanSummary(flow: flow, draft: draft) { id in
                                withAnimation { scroll.scrollTo(id, anchor: .top) }
                            }
                        }
                        if !flow.formPlanIsCurrent {
                            Text("资料权限、内容或表格已改变，或这是此前保存的草稿。请重新准备，已有答案仍保留。")
                                .foregroundStyle(.orange)
                        }
                        if draft.batches.isEmpty {
                            FormPlanFieldSelection(flow: flow,
                                fields: fieldID.map { id in document.fields.filter { $0.id == id } } ?? document.fields,
                                targets: draft.targets)
                            FormPlanSourceSelection(flow: flow, sources: flow.formPlanSources, selected: draft.sources)
                            if !draft.targets.isEmpty && !draft.sources.isEmpty {
                                if let batches = try? FormPlanRules.makeBatches(draft) {
                                    FormPlanBatchPreview(title: "本次将发送 \(batches.count) 批", batches: batches)
                                } else {
                                    Text(FormPlanBatchPreview.errorMessage(for: draft))
                                        .foregroundStyle(.orange)
                                }
                            }
                        } else {
                            Text("已完成 \(draft.batches.filter { $0.response != nil }.count) / \(draft.batches.count) 批")
                                .font(.headline)
                            FormPlanFrozenReview(draft: draft)
                            FormPlanResults(flow: flow, draft: draft, selected: $selectedResults)
                            if draft.batches.allSatisfy({ $0.response != nil }) {
                                FormPlanMergeReview(flow: flow, draft: draft, requestTask: $requestTask)
                            }
                            Button("采用勾选的普通事实答案") {
                                let ids = selectedResults
                                Task { await flow.adoptFormPlan(ids, in: context); selectedResults = [] }
                            }
                            .disabled(flow.isWorking || selectedResults.isEmpty || !flow.formPlanIsCurrent)
                            .accessibilityIdentifier("plan-form-adopt-selected")
                        }
                        Text("以上已允许的建档资料和字段要求将经中转发给模型服务商。点击发送仅授权本轮列出的批次及每批最多两次模型尝试；不附带原文件、完整提取原文或未允许的资料项。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if flow.isWorking {
                            EmptyView()
                        } else if draft.batches.isEmpty || draft.batches.contains(where: { $0.response == nil }) {
                            Button(draft.batches.isEmpty
                                ? (fieldID == nil ? "允许发送以上资料并生成整表建议" : "允许发送以上资料并填写此空")
                                : FormPlanBatchPreview.retryTitle(draft.batches)) {
                                requestTask = Task { await flow.submitFormPlan(in: context) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(flow.isUpdatingAISharing || draft.targets.isEmpty || draft.sources.isEmpty || !flow.formPlanIsCurrent
                                || (draft.batches.isEmpty && (try? FormPlanRules.makeBatches(draft)) == nil))
                            .accessibilityIdentifier("plan-form-send")
                        }
                        if !draft.batches.isEmpty || !flow.formPlanIsCurrent {
                            Button("按当前权限重新准备") {
                                Task { await flow.beginFormPlan(fieldID: fieldID, in: context); selectedResults = [] }
                            }.disabled(flow.isWorking || flow.isUpdatingAISharing)
                            Text("重新准备会清除本轮未采用的建议，已采用答案保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = flow.transientError { Text(error).foregroundStyle(.orange) }
                    }
                }.padding()
            }
            }
            .navigationTitle(fieldID == nil ? "AI 填写整表" : "AI 填写此空")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并关闭") { Task { await flow.persist(in: context); if !flow.hasUnsavedTaskChanges { dismiss() } } }
                        .disabled(flow.isWorking || flow.isUpdatingAISharing)
                }
            }
            .interactiveDismissDisabled(flow.isWorking || flow.isUpdatingAISharing || flow.hasUnsavedTaskChanges)
            .task(id: flow.snapshot?.generalForm?.planDraft) {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                if !flow.isWorking { await flow.persist(in: context) }
            }
            .onDisappear { requestTask?.cancel(); Task { await flow.persist(in: context) } }
        }
    }
}

private struct FormPlanFieldSelection: View {
    let flow: FlowStore
    let fields: [DynamicFormField]
    let targets: [FormPlanTarget]
    var body: some View {
        DisclosureGroup("核对字段与要求（\(targets.count) 项）") {
            Text("默认处理未确认字段。已确认、明确留空及手写答案受到保护；需要重填时，请先返回字段编辑。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(fields) { field in
                FormPlanFieldRow(flow: flow, field: field, target: targets.first { $0.original.id == field.id })
            }
        }
    }
}
private struct FormPlanFieldRow: View {
    let flow: FlowStore
    let field: DynamicFormField
    let target: FormPlanTarget?
    var body: some View {
        VStack(alignment: .leading) {
            Toggle(field.label, isOn: Binding(get: { target != nil }, set: { _ in flow.toggleFormPlanField(field) }))
                .disabled(FormPlanRules.isProtected(field))
            if let target {
                TextField("字段名称", text: binding(target.id, \.label))
                TextField("所属章节或人物关系", text: binding(target.id, \.section))
                TextField("填写要求", text: binding(target.id, \.instructions), axis: .vertical)
                if !field.options.isEmpty { Text("选项：\(field.options.map(\.label).joined(separator: "、"))").font(.caption) }
                if let maximum = field.constraints.maximumCharacters { Text("最多 \(maximum) 字").font(.caption) }
                if target.field.mode == .generated { Text("AI 撰写草稿，返回后需逐项确认").font(.caption).foregroundStyle(.secondary) }
                if target.field.mode == .manual { Text("签名及承诺由本人填写").font(.caption).foregroundStyle(.secondary) }
            }
        }.textFieldStyle(.roundedBorder).padding(.vertical, 5)
    }
    private func binding(_ id: String, _ key: WritableKeyPath<FormPlanField, String>) -> Binding<String> {
        Binding(get: { flow.snapshot?.generalForm?.planDraft?.targets.first { $0.id == id }?.field[keyPath: key] ?? "" },
                set: { value in flow.editFormPlan { draft in
                    if let index = draft.targets.firstIndex(where: { $0.id == id }) { draft.targets[index].field[keyPath: key] = value }
                } })
    }
}
private struct FormPlanSourceSelection: View {
    let flow: FlowStore
    let sources: [FormPlanSource]
    let selected: [FormPlanSource]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本次使用的建档资料（\(selected.count) 项）").font(.headline)
                Spacer()
                Button("全选") { flow.selectAllFormPlanSources() }
                    .disabled(flow.isUpdatingAISharing || sources.isEmpty || sources.allSatisfy { source in
                        selected.contains { $0.originID == source.originID }
                    })
                    .accessibilityIdentifier("plan-form-select-all-sources")
            }
            Text("默认使用当前已允许的资料项，可为本次填写取消勾选。调整长期可用范围，请打开上方“AI 可用资料”。")
                .font(.footnote).foregroundStyle(.secondary)
            if sources.isEmpty { Text("暂无允许 AI 使用的建档资料。请先打开“AI 可用资料”逐项允许；也可以继续本地填写。") }
            ForEach(sources) { source in
                Toggle(source.title, isOn: Binding(get: { selected.contains { $0.originID == source.originID } },
                    set: { _ in flow.toggleFormPlanSource(source) }))
                    .disabled(flow.isUpdatingAISharing)
            }
            DisclosureGroup("核对本次使用的资料内容") {
                ForEach(selected) { source in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.title).font(.subheadline.bold())
                        Text(source.text).font(.footnote).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
        }
    }
}
private struct FormPlanFrozenReview: View {
    let draft: FormPlanDraft
    var body: some View {
        DisclosureGroup("查看本次发送内容与批次") {
            ForEach(draft.sources) { source in
                VStack(alignment: .leading) { Text("\(source.id) · \(source.title)").bold(); Text(source.text).textSelection(.enabled) }
            }
            ForEach(draft.batches) { batch in
                VStack(alignment: .leading) {
                    Text(batch.request.fields.map { "\($0.label) · \($0.section) · \($0.instructions)" }.joined(separator: "\n"))
                    Text("来源片段：\(batch.request.sources.count) 个")
                    ForEach(batch.request.sources, id: \.id) { source in
                        Text("\(source.id)：\n\(source.text)").textSelection(.enabled)
                    }
                    if let error = batch.error { Text(error).foregroundStyle(.orange) }
                }.padding(.vertical, 4)
            }
        }.font(.footnote)
    }
}
private struct FormPlanBatchPreview: View {
    let title: String
    let batches: [FormPlanBatch]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本次将发送 \(batches.count) 批，约 \(max(1, (batches.count * 20 + 59) / 60)) 分钟（每批约 20 秒，排队另计）")
                .font(.subheadline.bold())
            Text("\(title)；总计最多 \(batches.count * 2) 次模型尝试。请核对后再授权。")
                .font(.subheadline.bold())
            DisclosureGroup("查看每批将发送的文字") {
                ForEach(Array(batches.enumerated()), id: \.element.id) { index, batch in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("第 \(index + 1) 批 · \(batch.request.fields.count) 字段 · \(batch.request.sources.count) 片段").bold()
                        Text(batch.request.fields.map { field in
                            "\(field.label) · \(field.section)：\(field.instructions)"
                                + (field.options.isEmpty ? "" : "\n选项：\(field.options.map(\.label).joined(separator: "、"))")
                        }.joined(separator: "\n"))
                        ForEach(batch.request.sources, id: \.id) { source in
                            Text("\(source.id)：\n\(source.text)").textSelection(.enabled)
                        }
                    }.padding(.vertical, 5)
                }
            }.font(.footnote)
        }
    }

    static func retryTitle(_ batches: [FormPlanBatch]) -> String {
        let failures = batches.filter { $0.response == nil && $0.error != nil }.count
        let pending = batches.filter { $0.response == nil && $0.error == nil }.count
        if failures == 0 { return "继续发送未完成的 \(pending) 批" }
        return "重试失败的 \(failures) 批" + (pending > 0 ? "，并继续其余 \(pending) 批" : "")
    }

    static func errorMessage(for draft: FormPlanDraft) -> String {
        do { _ = try FormPlanRules.makeBatches(draft); return "" }
        catch { return error.localizedDescription }
    }
}

private struct FormPlanMergeReview: View {
    let flow: FlowStore
    let draft: FormPlanDraft
    @Binding var requestTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let batches = try? pendingBatches(), !batches.isEmpty {
                Text("长文合成前再次核对：以下是 AI 分批草稿，不是原始资料。")
                    .font(.footnote).foregroundStyle(.orange)
                FormPlanBatchPreview(title: "合成将发送 \(batches.count) 批", batches: batches)
                Button(batches.contains { $0.error != nil } ? FormPlanBatchPreview.retryTitle(batches) : "允许发送以上草稿并合成长文") {
                    requestTask = Task { await flow.submitFormPlanMerge(in: modelContext) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(flow.isWorking || flow.isUpdatingAISharing || !flow.formPlanIsCurrent)
                .accessibilityIdentifier("plan-form-merge-send")
            } else if let message = pendingError() {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    @Environment(\.modelContext) private var modelContext

    private func pendingBatches() throws -> [FormPlanBatch] {
        if let last = draft.mergeRounds?.last, last.contains(where: { $0.response == nil }) { return last.filter { $0.response == nil } }
        return try FormPlanRules.makeMergeBatches(draft)
    }

    private func pendingError() -> String? {
        do { _ = try pendingBatches(); return nil }
        catch { return error.localizedDescription }
    }
}
private struct FormPlanResults: View {
    let flow: FlowStore
    let draft: FormPlanDraft
    @Binding var selected: Set<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("集中核对答案").font(.headline)
            Text("来源可追溯不代表事实已自动核实。生成长文和勾选建议请逐项确认；冲突或缺失请回到字段编辑。")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(draft.targets) { target in
                FormPlanResultRow(flow: flow, target: target,
                    result: FormPlanRules.finalSuggestion(draft, target: target),
                    draft: draft, adopted: draft.adoptedFieldIDs.contains(target.id), selected: $selected)
                    .id(target.id)
            }
        }
    }
}
private struct FormPlanResultRow: View {
    @Environment(\.modelContext) private var context
    let flow: FlowStore
    let target: FormPlanTarget
    let result: FormPlanSuggestion?
    let draft: FormPlanDraft
    let adopted: Bool
    @Binding var selected: Set<String>
    @State private var edited: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(target.field.label).font(.headline)
            Text(flow.formPlanFieldStatus(target, draft: draft)).font(.caption).foregroundStyle(.secondary)
            if adopted { Label("已采用", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else if let result {
                if result.status == .suggested {
                    if result.generated { Text("AI 撰写草稿 · 需逐项确认").foregroundStyle(.orange) }
                    if let answer = result.answer {
                        TextField("核对或编辑答案", text: Binding(get: { edited ?? answer }, set: { edited = $0 }), axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...10)
                    } else {
                        Text(target.field.options.filter { result.selectedOptionIDs.contains($0.id) }.map(\.label).joined(separator: "、"))
                    }
                    if !result.generated && target.field.mode == .fact && target.field.options.isEmpty && edited == nil {
                        Toggle("加入批量采用", isOn: Binding(get: { selected.contains(target.id) }, set: { value in
                            if value { selected.insert(target.id) } else { selected.remove(target.id) }
                        }))
                        .disabled(flow.isWorking || !flow.formPlanTargetIsCurrent(target))
                    }
                    Button("核对无误，采用此项") {
                        Task { await flow.adoptFormPlan([target.id], editedAnswer: edited, individually: true, in: context) }
                    }
                    .disabled(flow.isWorking || !flow.formPlanTargetIsCurrent(target))
                    .accessibilityIdentifier("plan-form-adopt-\(target.id)")
                }
                if !result.reason.isEmpty { Text(result.reason).foregroundStyle(.orange) }
                if !result.evidence.isEmpty {
                    DisclosureGroup("查看依据") {
                        Text(result.evidence.map { evidence in
                            "\(FormPlanRules.source(for: evidence, targetID: target.id, draft: draft)?.title ?? evidence.sourceId)：\n\(evidence.quote)"
                        }.joined(separator: "\n\n")).font(.footnote).textSelection(.enabled)
                    }
                }
            } else {
                Text(flow.formPlanFieldStatus(target, draft: draft))
                    .foregroundStyle(.secondary)
            }
        }
        .padding().background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: edited) { _, value in if value != nil { selected.remove(target.id) } }
    }
}

private struct FormPlanProgressCard: View {
    let flow: FlowStore
    let draft: FormPlanDraft
    let cancel: () -> Void

    var body: some View {
        let progress = flow.formPlanProgress.flatMap { $0.draftID == draft.id ? $0 : nil }
        let active = flow.isWorking && progress != nil
        let phase = progress?.phase ?? (draft.batches.isEmpty ? .reviewing : .results)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("① 核对资料").foregroundStyle(phase == .reviewing ? .primary : .secondary)
                Text("② AI 生成中").foregroundStyle(active ? .primary : .secondary)
                Text("③ 核对采用").foregroundStyle(phase == .results ? .primary : .secondary)
            }.font(.caption.bold())
            if let progress, active {
                ProgressView(value: Double(progress.completedBatches), total: Double(max(1, progress.totalBatches)))
                Text("第 \(progress.batchNumber)/\(progress.totalBatches) 批：\(phase == .queued ? "等待生成" : "正在生成")\(progress.fieldNames.prefix(2).map { "「\($0)」" }.joined())等 \(progress.fieldNames.count) 个字段")
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(alignment: .leading, spacing: 6) {
                        if let deadline = progress.queueDeadline {
                            Text("云端限额，已自动排队，约 \(max(0, Int(ceil(deadline.timeIntervalSince(timeline.date))))) 秒后继续")
                                .foregroundStyle(.orange)
                        }
                        if let start = progress.startedAt {
                            Text("已用 \(max(0, Int(timeline.date.timeIntervalSince(start)))) 秒 · 已完成字段 \(draft.targets.filter { FormPlanRules.finalSuggestion(draft, target: $0) != nil }.count)/\(draft.targets.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let notice = progress.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                Button("取消后续请求", action: cancel)
            } else if let notice = progress?.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("plan-form-progress")
    }
}

private struct FormPlanSummary: View {
    let flow: FlowStore
    let draft: FormPlanDraft
    let scrollTo: (String) -> Void

    var body: some View {
        let results = draft.targets.compactMap { target in
            FormPlanRules.finalSuggestion(draft, target: target).map { (target, $0) }
        }
        let facts = results.filter { $0.1.status == .suggested && !$0.1.generated && $0.0.field.options.isEmpty }.count
        let generated = results.filter { $0.1.status == .suggested && $0.1.generated }.count
        let choices = results.filter { $0.1.status == .suggested && !$0.0.field.options.isEmpty }.count
        let missing = results.filter { $0.1.status == .missing }.count
        let conflicts = results.filter { $0.1.status == .conflict }.count
        let manual = draft.targets.filter { flow.formPlanFieldStatus($0, draft: draft) == "需本人填写" }.count
        VStack(alignment: .leading, spacing: 8) {
            Text("已生成 \(facts + generated + choices) 项：\(facts) 项普通事实可批量采用，\(generated) 项长文、\(choices) 项选项需逐项确认；\(missing) 项缺资料、\(conflicts) 项冲突、\(manual) 项需本人填写。")
            Text("请核对并采用可用答案；缺资料或冲突项请补充资料重新生成，或手动填写。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(draft.targets.filter { target in
                let status = FormPlanRules.finalSuggestion(draft, target: target)?.status
                return status == .missing || status == .conflict
            }) { target in
                Button("\(target.field.label) · \(flow.formPlanFieldStatus(target, draft: draft))") { scrollTo(target.id) }
            }
        }.accessibilityIdentifier("plan-form-summary")
    }
}
