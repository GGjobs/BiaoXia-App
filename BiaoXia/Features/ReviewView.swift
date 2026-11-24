import PDFKit
import SwiftData
import SwiftUI

struct ReviewView: View {
    @Environment(\.modelContext) private var modelContext
    let flow: FlowStore
    @State private var sourceFormURL: URL?
    @State private var showPartialExport = false
    @State private var showManualField = false

    private var isWord: Bool { flow.snapshot?.form?.isWord == true }

    private var isProfileMode: Bool {
        flow.snapshot?.effectiveInputMode == .reusableProfile
    }

    private var fields: [ResolvedField] {
        let values = flow.snapshot?.resolvedFields ?? []
        if isProfileMode {
            return values.sorted {
                FieldKey.allCases.firstIndex(of: $0.key)!
                    < FieldKey.allCases.firstIndex(of: $1.key)!
            }
        }
        return values.sorted {
            if ($0.confidence < 0.85) != ($1.confidence < 0.85) {
                return $0.confidence < 0.85
            }
            return FieldKey.allCases.firstIndex(of: $0.key)!
                < FieldKey.allCases.firstIndex(of: $1.key)!
        }
    }

    private var generalFields: [DynamicFormField] {
        flow.snapshot?.generalForm?.fields ?? []
    }

    private var formValues: [FormFieldValue] {
        flow.snapshot?.formValues ?? []
    }

    private var missingRequiredValues: [FormFieldValue] {
        // General PDF review displays and exports generalForm, not legacy template values.
        guard flow.snapshot?.generalForm == nil else { return [] }
        return formValues.filter { $0.required && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var selectableItems: [ProfileItem] {
        flow.profile.informationItems.filter {
            [.project, .course, .skill, .language, .certificate, .award,
             .internship, .work, .campus, .volunteer].contains($0.category)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    step: isProfileMode ? "第 2 步，共 3 步" : "第 4 步，共 5 步",
                    title: isProfileMode ? "核对自动填写内容" : "人工确认",
                    detail: isProfileMode
                        ? "已按导入表格从信息库匹配内容；带“必填”的项目确认后才能导出。"
                        : "低置信度字段已置顶。请核对后再生成报名表。",
                    onPrevious: isProfileMode ? { flow.isFormImportPresented = true } : nil,
                    previousDisabled: flow.isWorking || flow.hasUnsavedTaskChanges
                )

                if let form = flow.snapshot?.form {
                    Label(form.displayName, systemImage: "doc.text")
                        .font(.subheadline.weight(.semibold))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if let warning = flow.snapshot?.lastError {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding()
                        .background(.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if !missingRequiredValues.isEmpty {
                    Label(
                        "还需补充：\(missingRequiredValues.map(\.label).joined(separator: "、"))",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                if !unconfirmedOptionalGeneralFields.isEmpty {
                    Label(
                        "以下可选建议不会写入结果文件：\(unconfirmedOptionalGeneralFields.map(\.label).joined(separator: "、"))",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if flow.hasUnsavedTaskChanges {
                    Text("最新修改尚未保存，离开前请重试保存。")
                        .foregroundStyle(.orange)
                    Button("重试保存") {
                        Task { await flow.retrySaving(in: modelContext) }
                    }
                }

                if let draft = flow.snapshot?.fieldExplanationDraft {
                    FieldExplanationReviewSection(draft: draft, flow: flow)
                } else if generalFields.contains(where: {
                    [.needsReview, .allowedForRemoteExplanation, .unresolved].contains($0.meaning.state)
                }) {
                    Button("核对并解释陌生字段") {
                        Task { await flow.prepareFieldExplanationReview(in: modelContext) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("review-field-explanation")
                }

                if !generalFields.isEmpty {
                    FormPlanningEntry(flow: flow)
                    GeneralFormReviewSection(fields: generalFields, flow: flow, sourceURL: sourceFormURL)
                    if let document = flow.snapshot?.generalForm {
                        FormExportReview(document: document)
                        if document.effectiveFormat == .pdf {
                            Button("重新识别并保留旧答案") { Task { await flow.reparseCurrentForm(in: modelContext) } }
                            Button("框选补充漏识别字段") { showManualField = true }
                        }
                    }
                    Button(isWord ? "保存此 Word 版本的字段含义" : "保存此 PDF 版本的字段与位置映射") {
                        Task { await flow.saveCurrentVersionMapping(in: modelContext) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("save-version-mapping")
                } else if isProfileMode, !formValues.isEmpty {
                    if !selectableItems.isEmpty {
                        DisclosureGroup("选择用于本表的经历与能力") {
                            ForEach(selectableItems) { item in
                                Button {
                                    flow.toggleTaskProfileItem(item, in: modelContext)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.label).foregroundStyle(.primary)
                                            Text(item.value).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer()
                                        Image(systemName: isSelected(item) ? "checkmark.circle.fill" : "circle")
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 4)
                            }
                        }
                        .padding()
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    ForEach(formValues) { field in
                        FormFieldReviewCard(
                            field: field,
                            value: Binding(
                                get: {
                                    flow.snapshot?.formValues?
                                        .first(where: { $0.fieldID == field.fieldID })?.value ?? ""
                                },
                                set: {
                                    flow.updateFormValue(field.fieldID, value: $0, in: modelContext)
                                }
                            )
                        )
                    }
                    if formValues.contains(where: { $0.modifiedByUser }) {
                        Button("将本次修改保存回我的信息") {
                            Task { await flow.saveTaskValuesBackToProfile() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(fields) { field in
                        FieldReviewCard(
                            field: field,
                            isProfileMode: isProfileMode,
                            value: Binding(
                                get: {
                                    flow.snapshot?.resolvedFields
                                        .first(where: { $0.key == field.key })?.value ?? ""
                                },
                                set: {
                                    flow.updateField(field.key, value: $0, in: modelContext)
                                }
                            )
                        )
                    }
                }

                if isWord {
                    WordReviewNotice()
                    if let sourceFormURL {
                        ShareLink("用其他 App 查看原 Word", item: sourceFormURL)
                    }
                } else if !generalFields.isEmpty {
                    DisclosureGroup("核对原 PDF 文档") {
                        if let sourceFormURL {
                            SourcePDFPreview(url: sourceFormURL)
                                .frame(minHeight: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            ProgressView("正在载入原文档…")
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    if let document = flow.snapshot?.generalForm, FormExportSummary(document: document).isPartial {
                        showPartialExport = true
                    } else { Task { await flow.export(in: modelContext) } }
                } label: {
                    if flow.snapshot?.status == .exporting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(isWord ? "确认内容并生成 Word" : (isProfileMode ? "确认并生成已填写 PDF" : "确认并生成 PDF"))
                    }
                }
                .accessibilityIdentifier(isWord ? "generate-filled-word" : "generate-filled-pdf")
                .buttonStyle(PrimaryButtonStyle())
                .disabled(
                    flow.snapshot?.status == .exporting || flow.isWorking
                        || !missingRequiredValues.isEmpty
                        || hasBlockingGeneralFields
                )
            }
            .padding(24)
            .disabled(flow.snapshot?.status == .exporting)
        }
        .confirmationDialog("仍有未处理项目或解析疑点", isPresented: $showPartialExport, titleVisibility: .visible) {
            Button("导出已确认内容") { Task { await flow.export(in: modelContext, allowPartial: true) } }
            Button("继续核对", role: .cancel) {}
        } message: { Text("未确认建议和草稿不会写入，导出后请对照原表检查遗漏。") }
        .sheet(isPresented: $showManualField) {
            if let sourceFormURL { PDFLocationSheet(url: sourceFormURL, field: nil, flow: flow) }
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回首页") { flow.closeTask() }
                    .disabled(flow.hasUnsavedTaskChanges || flow.isWorking)
            }
        }
        .task(id: flow.snapshot?.form?.id) {
            sourceFormURL = await flow.sourceFormFileURL()
        }
    }

    private var hasBlockingGeneralFields: Bool {
        generalFields.contains { field in
            guard field.constraints.isRequired else { return false }
            return field.answer?.confirmationState != .confirmed
        }
    }

    private var unconfirmedOptionalGeneralFields: [DynamicFormField] {
        generalFields.filter {
            !$0.constraints.isRequired && $0.answer?.confirmationState == .suggested
        }
    }

    private func isSelected(_ item: ProfileItem) -> Bool {
        formValues.contains { $0.sourceItemIDs.contains(item.id) }
    }
}

private struct SourcePDFPreview: UIViewRepresentable {
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

private struct GeneralFormReviewSection: View {
    @Environment(\.modelContext) private var modelContext
    let fields: [DynamicFormField]
    let flow: FlowStore
    let sourceURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                "已离线识别 \(fields.count) 个字段；不确定项集中在这里处理",
                systemImage: "checkmark.shield"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.teal)

            ForEach(fields) { field in
                VStack(alignment: .leading) {
                GeneralFormFieldCard(
                    field: field,
                    value: Binding(
                        get: {
                            flow.snapshot?.generalForm?.fields
                                .first(where: { $0.id == field.id })?
                                .answer?.value ?? ""
                        },
                        set: {
                            flow.updateGeneralFormAnswer(
                                fieldID: field.id,
                                value: $0,
                                in: modelContext
                            )
                        }
                    ),
                    onSelectOptions: { optionIDs in
                        flow.updateGeneralFormAnswer(
                            fieldID: field.id,
                            value: "",
                            selectedOptionIDs: optionIDs,
                            in: modelContext
                        )
                    },
                    onConfirmSuggestion: {
                        Task {
                            await flow.confirmSuggestedGeneralFormAnswer(
                                fieldID: field.id,
                                in: modelContext
                            )
                        }
                    },
                    onLeaveBlank: {
                        flow.updateGeneralFormAnswer(
                            fieldID: field.id,
                            value: "",
                            intentionallyBlank: true,
                            in: modelContext
                        )
                    },
                    onSpecifyMeaning: { canonicalKey in
                        flow.updateFieldMeaning(
                            fieldID: field.id,
                            canonicalKey: canonicalKey,
                            in: modelContext
                        )
                    },
                    onAdjustRegion: { anchorIndex, pageIndex, rect in
                        Task {
                            await flow.adjustPDFRegion(
                                fieldID: field.id,
                                anchorIndex: anchorIndex,
                                pageIndex: pageIndex,
                                rect: rect,
                                in: modelContext
                            )
                        }
                    }
                )
                if let draft = flow.snapshot?.generalForm?.planDraft,
                   let target = draft.targets.first(where: { $0.original.id == field.id }) {
                    FormPlanInlineSuggestion(
                        flow: flow,
                        draft: draft,
                        target: target,
                        result: FormPlanRules.finalSuggestion(draft, target: target)
                    )
                }
                FormAssistanceView(field: field, flow: flow, sourceURL: sourceURL)
                if let sources = field.answer?.planSources, !sources.isEmpty {
                    DisclosureGroup("整表填写依据") {
                        Text(sources.map { "\($0.title)：\n\($0.quote)" }.joined(separator: "\n\n"))
                            .font(.footnote).textSelection(.enabled)
                    }
                }
                }
            }
        }
    }
}

private struct FormPlanInlineSuggestion: View {
    @Environment(\.modelContext) private var modelContext
    let flow: FlowStore
    let draft: FormPlanDraft
    let target: FormPlanTarget
    let result: FormPlanSuggestion?

    private var adopted: Bool { draft.adoptedFieldIDs.contains(target.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI 建议", systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .foregroundStyle(.teal)
                Spacer()
                if adopted { Text("已采用").foregroundStyle(.green) }
                else if !flow.formPlanTargetIsCurrent(target) { Text("已失效").foregroundStyle(.orange) }
                else { Text(flow.formPlanFieldStatus(target, draft: draft)) }
            }
            .font(.caption)

            if let result {
                if result.status == .suggested {
                    if let answer = result.answer {
                        Text(answer).font(.body.weight(.medium)).textSelection(.enabled)
                    } else {
                        Text(target.field.options.filter { result.selectedOptionIDs.contains($0.id) }
                            .map(\.label).joined(separator: "、"))
                            .font(.body.weight(.medium))
                    }
                    if result.generated {
                        Text("AI 撰写草稿，请逐项核对后采用。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !result.reason.isEmpty {
                        Text(result.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if !adopted && flow.formPlanTargetIsCurrent(target) {
                        Button("核对无误，采用 AI 建议") {
                            Task { await flow.adoptFormPlan([target.id], individually: true, in: modelContext) }
                        }
                        .disabled(flow.isWorking)
                        .accessibilityIdentifier("review-plan-adopt-\(fieldID)")
                    }
                } else {
                    Text(result.reason).foregroundStyle(.orange)
                }
                if !result.evidence.isEmpty {
                    DisclosureGroup("查看 AI 建议依据") {
                        Text(result.evidence.map { evidence in
                            "\(FormPlanRules.source(for: evidence, targetID: target.id, draft: draft)?.title ?? evidence.sourceId)：\n\(evidence.quote)"
                        }.joined(separator: "\n\n"))
                        .font(.footnote).textSelection(.enabled)
                    }
                }
            } else {
                Text(flow.formPlanFieldStatus(target, draft: draft))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !flow.formPlanTargetIsCurrent(target) && !adopted {
                Text("资料或字段已改变，请重新生成建议。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var fieldID: String { target.original.id }
}

private struct GeneralFormFieldCard: View {
    let field: DynamicFormField
    @Binding var value: String
    let onSelectOptions: ([String]) -> Void
    let onConfirmSuggestion: () -> Void
    let onLeaveBlank: () -> Void
    let onSpecifyMeaning: (String) -> Void
    let onAdjustRegion: (Int, Int, NormalizedRect) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(field.label)
                    .font(.headline)
                if field.constraints.isRequired {
                    Text("必填")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(statusTitle)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            if field.kind == .singleChoice || field.kind == .multipleChoice {
                ForEach(field.options) { option in
                    Button {
                        toggle(option.id)
                    } label: {
                        Label(
                            option.label,
                            systemImage: selectedOptionIDs.contains(option.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                TextField("请输入\(field.label)", text: $value, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(field.kind == .multilineText ? 2...8 : 1...2)
                .accessibilityIdentifier("general-field-\(field.id)")
            }

            if let reasons = field.answer?.reviewReasons, !reasons.isEmpty {
                Text(reasons.joined(separator: "；"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let answer = field.answer, !answer.sourceRecordIDs.isEmpty {
                Label(
                    "来自信息库 \(answer.sourceRecordIDs.count) 条记录",
                    systemImage: "link"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if field.answer?.confirmationState == .suggested {
                Button("确认使用此建议", action: onConfirmSuggestion)
                    .buttonStyle(.borderedProminent)
            }
            if !field.constraints.isRequired {
                Button("本次留空", action: onLeaveBlank)
                    .font(.caption)
            }
            DisclosureGroup("字段含义与填写位置") {
                TextField(
                    "字段含义（例如 employer）",
                    text: Binding(
                        get: { field.meaning.canonicalKey ?? "" },
                        set: { value in onSpecifyMeaning(value) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                if let anchor = field.wordAnchor {
                    Text(anchor.location)
                    Text("Word 使用原文结构定位；本版不提供坐标调整。")
                        .foregroundStyle(.secondary)
                } else if field.options.count > 1, field.options.count == field.anchors.count {
                    ForEach(field.options) { option in
                        if let index = field.options.firstIndex(where: { $0.id == option.id }) {
                            Text(option.label)
                            PDFRegionEditor(anchor: field.anchors[index]) { pageIndex, rect in
                                onAdjustRegion(index, pageIndex, rect)
                            }
                        }
                    }
                } else {
                    PDFRegionEditor(anchor: field.anchors.first) { pageIndex, rect in
                        onAdjustRegion(0, pageIndex, rect)
                    }
                }
            }
            .font(.caption)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var selectedOptionIDs: Set<String> {
        Set(field.answer?.selectedOptionIDs ?? [])
    }

    private var statusTitle: String {
        switch field.answer?.confirmationState {
        case .confirmed: "已确认"
        case .suggested: "建议值"
        case .intentionallyBlank: "留空"
        case .blocked: "受阻"
        case .unresolved, nil: "待确认"
        }
    }

    private var statusColor: Color {
        switch field.answer?.confirmationState {
        case .confirmed: .green
        case .suggested: .teal
        case .intentionallyBlank: .secondary
        case .blocked, .unresolved, nil: .orange
        }
    }

    private func toggle(_ optionID: String) {
        var selected = selectedOptionIDs
        if field.kind == .singleChoice {
            selected = [optionID]
        } else if selected.contains(optionID) {
            selected.remove(optionID)
        } else {
            selected.insert(optionID)
        }
        onSelectOptions(field.options.map(\.id).filter(selected.contains))
    }
}

private struct FieldExplanationReviewSection: View {
    @Environment(\.modelContext) private var modelContext
    let draft: FieldExplanationDraft
    let flow: FlowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("发送前核对", systemImage: "hand.raised")
                .font(.headline)
            Text("仅下列字段标签、章节、说明和选项可发送；不会发送答案、个人资料、文件名或 PDF。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(draft.texts) { text in
                VStack(alignment: .leading, spacing: 6) {
                    Text(text.value.isEmpty ? "（已移除）" : text.value)
                    Text(reviewStateTitle(text.state))
                        .font(.caption)
                        .foregroundStyle(text.state == .blocked ? .red : .secondary)
                    if text.state == .pendingReview {
                        HStack {
                            Button("允许发送") {
                                flow.allowExplanationText(text.id, in: modelContext)
                            }
                            Button("移除") {
                                flow.removeExplanationText(text.id, in: modelContext)
                            }
                        }
                        .buttonStyle(.bordered)
                    } else if text.state == .blocked {
                        Button("移除敏感文字") {
                            flow.removeExplanationText(text.id, in: modelContext)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("允许其余安全文字") {
                    flow.allowAllExplanationTexts(in: modelContext)
                }
                .accessibilityIdentifier("allow-remaining-explanation-texts")
                Button("发送并解释") {
                    Task { await flow.submitReviewedFieldExplanation(in: modelContext) }
                }
                .accessibilityIdentifier("send-reviewed-explanation")
                .disabled(!draft.canSend || flow.isWorking)
            }
            .buttonStyle(.borderedProminent)
            Button("不发送，人工继续") {
                Task { await flow.continueWithoutRemoteExplanation(in: modelContext) }
            }
            .accessibilityIdentifier("continue-without-remote-explanation")
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func reviewStateTitle(_ state: OutboundTextReviewState) -> String {
        switch state {
        case .pendingReview: "待核对"
        case .allowed: "允许发送"
        case .removed: "不发送"
        case .blocked: "检测到敏感内容，禁止发送"
        }
    }
}

private struct PDFRegionEditor: View {
    let anchor: PDFFieldAnchor?
    let onSave: (Int, NormalizedRect) -> Void
    @State private var page: String
    @State private var x: String
    @State private var y: String
    @State private var width: String
    @State private var height: String

    init(anchor: PDFFieldAnchor?, onSave: @escaping (Int, NormalizedRect) -> Void) {
        self.anchor = anchor
        self.onSave = onSave
        _page = State(initialValue: String((anchor?.pageIndex ?? 0) + 1))
        _x = State(initialValue: String(format: "%.3f", anchor?.rect.x ?? 0))
        _y = State(initialValue: String(format: "%.3f", anchor?.rect.y ?? 0))
        _width = State(initialValue: String(format: "%.3f", anchor?.rect.width ?? 0.2))
        _height = State(initialValue: String(format: "%.3f", anchor?.rect.height ?? 0.04))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("使用 0–1 的页面比例坐标；页码从 1 开始。")
                .foregroundStyle(.secondary)
            HStack {
                coordinateField("页", text: $page)
                coordinateField("X", text: $x)
                coordinateField("Y", text: $y)
            }
            HStack {
                coordinateField("宽", text: $width)
                coordinateField("高", text: $height)
                Button("保存位置", action: save)
                    .disabled(parsedRegion == nil)
            }
        }
    }

    private func coordinateField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
    }

    private var parsedRegion: (Int, NormalizedRect)? {
        guard let pageNumber = Int(page), pageNumber > 0,
              let x = Double(x), let y = Double(y),
              let width = Double(width), let height = Double(height) else { return nil }
        let rect = NormalizedRect(x: x, y: y, width: width, height: height)
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else { return nil }
        return (pageNumber - 1, rect)
    }

    private func save() {
        guard let (pageIndex, rect) = parsedRegion else { return }
        onSave(pageIndex, rect)
    }
}

private struct FormFieldReviewCard: View {
    let field: FormFieldValue
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(field.label).font(.headline)
                if field.required {
                    Text("必填").font(.caption2.bold()).foregroundStyle(.orange)
                }
                Spacer()
                if !field.sourceItemIDs.isEmpty {
                    Text("来自信息库").font(.caption).foregroundStyle(.teal)
                }
            }
            TextField("请输入\(field.label)", text: $value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .accessibilityIdentifier("form-field-\(field.fieldID)")
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct FieldReviewCard: View {
    let field: ResolvedField
    let isProfileMode: Bool
    @Binding var value: String

    private var confidenceColor: Color {
        if field.confidence >= 0.85 { return .green }
        if field.confidence >= 0.60 { return .orange }
        return .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(field.key.label)
                    .font(.headline)
                if field.resolvedByAI {
                    Text("AI 已选")
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.purple.opacity(0.12))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(field.modifiedByUser ? "人工确认" : "\(Int(field.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(field.modifiedByUser ? .secondary : confidenceColor)
            }
            TextField("请输入\(field.key.label)", text: $value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(field.key == .address ? 2...4 : 1...2)
                .accessibilityIdentifier("field-\(field.key.rawValue)")
            if let sources = field.sources, !sources.isEmpty {
                DisclosureGroup("查看 \(sources.count) 处材料来源") {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(source.materialName) · \(source.locationDescription)")
                                .font(.caption.weight(.semibold))
                            Text(source.excerpt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 5)
                    }
                }
                .font(.caption)
            } else {
                Label(isProfileMode ? "来自已确认的我的信息" : "未找到材料来源", systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            if !field.modifiedByUser && field.confidence < 0.85 {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(confidenceColor.opacity(0.45), lineWidth: 1)
            }
        }
    }
}

private struct WordReviewNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Word 内容核对", systemImage: "doc.text")
                .font(.headline)
            Text("这里只列出已识别字段。复杂表格可能有漏项；当前不自动扩行，未确认的内容不会写入。")
            Text("导出后请用 Word/WPS 检查漏填、换行、分页和裁切，再提交使用。")
        }
        .font(.footnote)
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
