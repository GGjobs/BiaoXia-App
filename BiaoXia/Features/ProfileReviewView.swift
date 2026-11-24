import SwiftUI

struct ProfileReviewView: View {
    let flow: FlowStore

    private var fields: [ResolvedField] {
        flow.profileLibrary.resolvedFields.sorted {
            if ($0.confidence < 0.85) != ($1.confidence < 0.85) {
                return $0.confidence < 0.85
            }
            return FieldKey.allCases.firstIndex(of: $0.key)! < FieldKey.allCases.firstIndex(of: $1.key)!
        }
    }

    private var isComplete: Bool {
        fields.contains { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !(flow.profileLibrary.profileItems ?? []).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    step: "第 2 步，共 2 步",
                    title: "确认我的信息",
                    detail: "低置信度字段已置顶。展开来源可查看材料名称、页码和识别原文。"
                )
                if let warning = flow.profileLibrary.lastError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(fields) { field in
                    ProfileEvidenceCard(
                        field: field,
                        value: Binding(
                            get: { flow.profileLibrary.resolvedFields.first(where: { $0.key == field.key })?.value ?? "" },
                            set: { flow.updateProfileField(field.key, value: $0) }
                        )
                    )
                }
                let additionalItems = (flow.profileLibrary.profileItems ?? []).filter {
                    !FieldKey.allCases.map(\.rawValue).contains($0.fieldID)
                }
                if !additionalItems.isEmpty {
                    Text("识别到的其他有用信息")
                        .font(.title3.bold())
                    ForEach(additionalItems) { item in
                        ProfileReviewItemCard(item: item)
                    }
                }
                if let pending = flow.profileLibrary.pendingItems, !pending.isEmpty {
                    HStack(spacing: 12) {
                        Text("待确认更新")
                            .font(.title3.bold())
                        Spacer()
                        Button {
                            flow.acceptAllPendingProfileItems()
                        } label: {
                            Label("一键确认全部", systemImage: "checkmark.circle.fill")
                        }
                        .accessibilityIdentifier("accept-all-pending-profile-items")
                        .buttonStyle(.borderedProminent)
                        .disabled(flow.isWorking)
                    }
                    ForEach(pending) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            ProfileReviewItemCard(item: item)
                            HStack {
                                Button("接受") { flow.acceptPendingProfileItem(item) }
                                    .buttonStyle(.borderedProminent)
                                Button("忽略", role: .destructive) { flow.rejectPendingProfileItem(item) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                Button("保存为我的信息") { Task { await flow.saveConfirmedProfile() } }
                    .accessibilityIdentifier("save-confirmed-profile")
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isComplete || flow.isWorking)
            }
            .padding(24)
        }
        .navigationBarBackButtonHidden()
    }
}

private struct ProfileReviewItemCard: View {
    let item: ProfileItem
    @State private var revealSensitive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.label).font(.headline)
                Text(item.category.label)
                    .font(.caption2.bold())
                    .foregroundStyle(.teal)
                Spacer()
                Text("\(Int(item.confidence * 100))%")
                    .font(.caption.monospacedDigit())
            }
            HStack(alignment: .top) {
                Text(revealSensitive ? item.value : item.maskedValue)
                if item.sensitivity == .highlySensitive {
                    Button(revealSensitive ? "隐藏" : "查看") { revealSensitive.toggle() }
                        .font(.caption)
                }
            }
            if let source = item.sources.first {
                Text("\(source.materialName) · \(source.locationDescription) · \(source.excerpt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct ProfileEvidenceCard: View {
    let field: ResolvedField
    @Binding var value: String

    private var confidenceColor: Color {
        field.confidence >= 0.85 ? .green : (field.confidence >= 0.60 ? .orange : .red)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(field.key.label).font(.headline)
                if field.resolvedByAI {
                    Text("AI 已选").font(.caption2.bold()).foregroundStyle(.purple)
                } else if field.modifiedByUser {
                    Text("人工确认").font(.caption2.bold()).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(field.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(confidenceColor)
            }
            TextField("请输入\(field.key.label)", text: $value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("profile-review-\(field.key.rawValue)")
            if let sources = field.sources, !sources.isEmpty {
                DisclosureGroup("\(sources.count) 处来源") {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(source.materialName) · \(source.locationDescription)")
                                .font(.caption.weight(.semibold))
                            Text(source.excerpt).font(.caption).foregroundStyle(.secondary)
                            Text("本地 OCR \(Int(source.confidence * 100))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.top, 5)
                    }
                }
                .font(.caption)
            } else {
                Label("未找到来源，请人工补充", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            if field.confidence < 0.85 {
                RoundedRectangle(cornerRadius: 16).stroke(confidenceColor.opacity(0.45))
            }
        }
    }
}
