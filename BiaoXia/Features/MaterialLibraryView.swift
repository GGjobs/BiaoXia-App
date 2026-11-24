import SwiftUI
import UniformTypeIdentifiers

struct MaterialLibraryView: View {
    let flow: FlowStore
    @State private var isImporterPresented = false
    @State private var materialToDelete: MaterialAsset?
    @State private var materialToRename: MaterialAsset?
    @State private var renameText = ""
    @State private var isManualEditorPresented = false
    @State private var isClearConfirmationPresented = false
    @State private var searchText = ""
    @State private var itemToEdit: ProfileItem?
    @State private var itemLabel = ""
    @State private var itemValue = ""
    @State private var manualItemDraft: ManualProfileItemDraft?
    @State private var isSubjectEditorPresented = false

    private var informationItems: [ProfileItem] {
        let items = flow.profileLibrary.profileItems ?? flow.profile.informationItems
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.value.localizedCaseInsensitiveContains(query)
                || $0.category.label.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        configuredContent
    }

    private var configuredContent: some View {
        libraryContent
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.pdf, .image, UTType(filenameExtension: "docx") ?? .data],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .sheet(isPresented: $isManualEditorPresented) {
                ProfileEditorView(flow: flow)
            }
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                ProfileAIPermissionsEntry(flow: flow)
                informationDashboard
                materialsSection
                Text("Word 支持原生 DOCX 的正文和表格文字，暂不读取内嵌图片、浮动文本框及页眉页脚。请核对提取结果；未自动提取的信息可从材料原文搜索并补录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                warningSection
                actionsSection
            }
            .padding(24)
        }
        .navigationTitle("我的信息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { flow.closeProfileLibrary() }
            }
        }
        .alert("重命名材料", isPresented: Binding(
            get: { materialToRename != nil },
            set: { if !$0 { materialToRename = nil } }
        )) {
            TextField("材料名称", text: $renameText)
            Button("保存") {
                guard let material = materialToRename else { return }
                materialToRename = nil
                Task { await flow.renameProfileMaterial(material, to: renameText) }
            }
            Button("取消", role: .cancel) { materialToRename = nil }
        }
        .alert("删除材料？", isPresented: Binding(
            get: { materialToDelete != nil },
            set: { if !$0 { materialToDelete = nil } }
        ), presenting: materialToDelete) { material in
            Button("删除", role: .destructive) {
                materialToDelete = nil
                Task { await flow.deleteProfileMaterial(material) }
            }
            Button("取消", role: .cancel) { materialToDelete = nil }
        } message: { material in
            Text("将删除“\(material.displayName)”及其识别结果和字段来源。")
        }
        .alert("清空我的信息？", isPresented: $isClearConfirmationPresented) {
            Button("全部清空", role: .destructive) {
                Task { await flow.clearProfileInformation() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除结构化信息、提取原文、字段来源、变更历史和全部导入材料。最近填写任务会保留，此操作无法撤销。")
        }
        .alert("编辑信息", isPresented: Binding(
            get: { itemToEdit != nil },
            set: { if !$0 { itemToEdit = nil } }
        )) {
            TextField("标签", text: $itemLabel)
            TextField("内容", text: $itemValue, axis: .vertical)
            Button("保存") {
                guard let item = itemToEdit else { return }
                flow.updateProfileItem(item, label: itemLabel, value: itemValue)
                itemToEdit = nil
            }
            Button("取消", role: .cancel) { itemToEdit = nil }
        }
        .sheet(item: $manualItemDraft) { draft in
            ManualProfileItemEditor(flow: flow, draft: draft)
        }
        .sheet(isPresented: $isSubjectEditorPresented) {
            ProfileSubjectEditor(flow: flow)
        }
    }

    private var headerSection: some View {
        PageHeader(
            step: "个人材料库",
            title: flow.profile.hasInformation ? "管理我的信息库" : "从材料建立我的信息",
            detail: "结构化信息不限十项；原文件与提取原文保存在本机。按资料项设置 AI 可用范围，未允许的信息仍可本地填写。"
        )
    }

    @ViewBuilder
    private var materialsSection: some View {
        if flow.profileLibrary.materials.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 44))
                    .foregroundStyle(.teal)
                Text("导入简历、学生证、成绩单").font(.headline)
                Text("支持一次选择多份 PDF、DOCX、JPG、PNG 或 HEIC")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        } else {
            VStack(spacing: 0) {
                ForEach(flow.profileLibrary.materials) { material in
                    materialRow(material)
                    if material.id != flow.profileLibrary.materials.last?.id { Divider() }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func materialRow(_ material: MaterialAsset) -> some View {
        HStack(spacing: 13) {
            Image(systemName: material.kind.systemImage)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text(material.displayName).lineLimit(1)
                Text(material.kind == .docx ? "DOCX · \(statusText(material.status))" : "\(material.pageCount) 页 · \(statusText(material.status))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("重命名", systemImage: "pencil") {
                    renameText = material.displayName
                    materialToRename = material
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                    materialToDelete = material
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("material-menu-\(material.id.uuidString)")
        }
        .padding()
    }

    @ViewBuilder
    private var warningSection: some View {
        if let warning = flow.profileLibrary.lastError {
            VStack(alignment: .leading, spacing: 10) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Button {
            isImporterPresented = true
        } label: {
            Label("从“文件”添加材料", systemImage: "folder.badge.plus")
        }
        .accessibilityIdentifier("add-profile-materials")
        .buttonStyle(PrimaryButtonStyle())

        if !flow.profileLibrary.materials.isEmpty {
            Button {
                Task { await flow.startProfileRecognition() }
            } label: {
                Label(
                    flow.profileLibrary.isRecognized || flow.profileLibrary.status == .confirmed
                        ? "重新识别并更新信息库"
                        : "识别材料并建立信息库",
                    systemImage: "viewfinder"
                )
            }
            .accessibilityIdentifier("recognize-profile-materials")
            .buttonStyle(PrimaryButtonStyle())
            .disabled(flow.isWorking)
        }

        if flow.profileLibrary.profileItems?.contains(where: {
            $0.state != .pending && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) == true {
            Button {
                Task { await flow.saveConfirmedProfile() }
            } label: {
                Label("保存并使用当前信息库", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier("save-profile-information-library")
            .buttonStyle(PrimaryButtonStyle())
            .disabled(flow.isWorking)
        }

        HStack {
            Button("编辑基础信息") { isManualEditorPresented = true }
            Spacer()
            Button("添加人物") { isSubjectEditorPresented = true }
            Spacer()
            Button("添加自定义信息") {
                manualItemDraft = ManualProfileItemDraft(label: "", value: "", sourceBlock: nil)
            }
        }

        if flow.profile != .empty || !flow.profileLibrary.materials.isEmpty {
            Button(role: .destructive) {
                isClearConfirmationPresented = true
            } label: {
                Label("一键清空我的信息", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("clear-profile-information")
            .buttonStyle(.bordered)
            .disabled(flow.isWorking)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls): Task { await flow.importProfileMaterials(from: urls) }
        case let .failure(error): flow.transientError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var informationDashboard: some View {
        let allItems = flow.profileLibrary.profileItems ?? flow.profile.informationItems
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("\(allItems.count) 项可复用信息", systemImage: "archivebox.fill")
                    .font(.headline)
                Spacer()
                if let pendingCount = flow.profileLibrary.pendingItems?.count, pendingCount > 0 {
                    Text("\(pendingCount) 项待确认")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            TextField("搜索信息或材料原文", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("profile-information-search")

            if let subjects = flow.profileLibrary.subjects, !subjects.isEmpty {
                DisclosureGroup("人物与关系（\(subjects.count)）") {
                    ForEach(subjects) { subject in
                        LabeledContent(subject.displayName) {
                            Text(subject.relationshipToSelf ?? subject.kind.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let pending = flow.profileLibrary.pendingItems, !pending.isEmpty {
                DisclosureGroup("待处理更新（\(pending.count)）") {
                    ForEach(pending) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            ProfileItemRow(item: item)
                            HStack {
                                Button("接受") { flow.acceptPendingProfileItem(item) }
                                Button("忽略", role: .destructive) { flow.rejectPendingProfileItem(item) }
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 5)
                    }
                }
                .foregroundStyle(.orange)
            }

            if let latest = flow.profileLibrary.changeHistory?.first, !latest.changes.isEmpty {
                let addedCount = latest.changes.filter { $0.previous == nil }.count
                let replacedCount = latest.changes.count - addedCount
                DisclosureGroup("最近识别：新增 \(addedCount) 项，覆盖 \(replacedCount) 项") {
                    ForEach(latest.changes) { change in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(change.label).font(.caption.bold())
                            Text("原：\(change.previous?.value ?? "未收录")")
                            Text("新：\(change.current?.value ?? "已删除")")
                            Button("撤销这一项") {
                                flow.undoProfileChange(change, in: latest)
                            }
                            .font(.caption2.weight(.semibold))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                    }
                    Button("撤销本批更新") { flow.undoProfileChangeBatch(latest) }
                        .font(.caption.weight(.semibold))
                }
            }

            ForEach(ProfileItemCategory.allCases) { category in
                let categoryItems = informationItems.filter { $0.category == category }
                if !categoryItems.isEmpty {
                    DisclosureGroup("\(category.label)（\(categoryItems.count)）") {
                        ForEach(categoryItems) { item in
                            HStack(alignment: .top) {
                                ProfileItemRow(item: item)
                                Spacer()
                                Menu {
                                    Button("编辑", systemImage: "pencil") {
                                        itemLabel = item.label
                                        itemValue = item.value
                                        itemToEdit = item
                                    }
                                    if category.allowsMultiple {
                                        Button("设为首选", systemImage: "star") {
                                            flow.setPreferredProfileItem(item)
                                        }
                                    }
                                    Button("删除", systemImage: "trash", role: .destructive) {
                                        flow.deleteProfileItem(item)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }

            let ocrMatches = flow.searchOCR(searchText)
            if !searchText.isEmpty, !ocrMatches.isEmpty {
                DisclosureGroup("材料原文匹配（\(ocrMatches.count)）") {
                    ForEach(ocrMatches.prefix(20)) { block in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(block.text)
                            Text(block.pageIndex < 0 ? "Word 正文 · 本地文字读取" : "第 \(block.pageIndex + 1) 页 · 本地 OCR \(Int(block.confidence * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("将这段原文加入信息库") {
                                manualItemDraft = ManualProfileItemDraft(
                                    label: "自定义信息",
                                    value: block.text,
                                    sourceBlock: block
                                )
                            }
                            .font(.caption2.weight(.semibold))
                        }
                        .font(.caption)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statusText(_ status: MaterialProcessingStatus) -> String {
        switch status {
        case .pending: "等待识别"
        case .recognizing: "正在识别"
        case .completed: "识别完成"
        case .failed: "识别失败"
        }
    }
}

private struct ManualProfileItemDraft: Identifiable {
    let id = UUID()
    var label: String
    var value: String
    var sourceBlock: OCRBlock?
}

private struct ManualProfileItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    let flow: FlowStore
    let sourceBlock: OCRBlock?
    @State private var label: String
    @State private var value: String
    @State private var category: ProfileItemCategory
    @State private var subjectID: UUID?

    init(flow: FlowStore, draft: ManualProfileItemDraft) {
        self.flow = flow
        sourceBlock = draft.sourceBlock
        _label = State(initialValue: draft.label)
        _value = State(initialValue: draft.value)
        _category = State(initialValue: .other)
        _subjectID = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("语义分类") {
                    Picker("类别", selection: $category) {
                        ForEach(ProfileItemCategory.allCases) { category in
                            Text(category.label).tag(category)
                        }
                    }
                    if let subjects = flow.profileLibrary.subjects, !subjects.isEmpty {
                        Picker("所属人物", selection: $subjectID) {
                            Text("本人").tag(UUID?.none)
                            ForEach(subjects) { subject in
                                Text(subject.displayName).tag(Optional(subject.id))
                            }
                        }
                    }
                    TextField("标签", text: $label)
                }
                Section("内容") {
                    TextField("信息内容", text: $value, axis: .vertical)
                        .lineLimit(3...8)
                    if sourceBlock != nil {
                        Text("内容需保留在所选材料原文中，材料与来源位置会一并保存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(sourceBlock == nil ? "添加结构化信息" : "分类材料原文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let sourceBlock {
                            flow.addOCRBlockToProfile(
                                sourceBlock,
                                label: label,
                                value: value,
                                category: category,
                                subjectID: subjectID
                            )
                        } else {
                            flow.addCustomProfileItem(
                                label: label,
                                value: value,
                                category: category,
                                subjectID: subjectID
                            )
                        }
                        dismiss()
                    }
                    .disabled(
                        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

private struct ProfileSubjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    let flow: FlowStore
    @State private var displayName = ""
    @State private var relationship = ""
    @State private var kind = ProfileSubjectKind.familyMember

    var body: some View {
        NavigationStack {
            Form {
                Picker("人物类型", selection: $kind) {
                    ForEach(ProfileSubjectKind.editableCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                TextField("姓名或称呼", text: $displayName)
                TextField("与本人的关系", text: $relationship)
            }
            .navigationTitle("添加人物关系")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        flow.addProfileSubject(
                            displayName: displayName,
                            kind: kind,
                            relationshipToSelf: relationship
                        )
                        dismiss()
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private extension ProfileSubjectKind {
    static let editableCases: [ProfileSubjectKind] = [.familyMember, .emergencyContact, .other]

    var label: String {
        switch self {
        case .selfPerson: "本人"
        case .familyMember: "家属"
        case .emergencyContact: "紧急联系人"
        case .other: "其他人物"
        }
    }
}

private struct ProfileItemRow: View {
    let item: ProfileItem
    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.label).font(.subheadline.weight(.semibold))
                if item.isPreferred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                if item.sensitivity == .highlySensitive {
                    Button(isRevealed ? "隐藏" : "查看") { isRevealed.toggle() }
                        .font(.caption2)
                }
            }
            Text(isRevealed ? item.value : item.maskedValue)
                .font(.subheadline)
            HStack {
                Text(item.modifiedByUser ? "人工内容" : "置信度 \(Int(item.confidence * 100))%")
                if let source = item.sources.first {
                    Text("· \(source.materialName) \(source.locationDescription)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if !item.sources.isEmpty {
                DisclosureGroup("查看 \(item.sources.count) 处来源") {
                    ForEach(item.sources) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(source.materialName) · \(source.locationDescription)")
                                .font(.caption2.weight(.semibold))
                            Text(source.excerpt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .font(.caption2)
            }
        }
    }
}
