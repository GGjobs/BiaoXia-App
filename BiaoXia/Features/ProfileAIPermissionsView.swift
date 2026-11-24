import SwiftUI

struct ProfileAIPermissionsView: View {
    @Environment(\.dismiss) private var dismiss
    let flow: FlowStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选择云端 AI 可以使用的建档资料项。整表填写和单空填写共用这些设置；关闭的资料仍可在本机匹配、填写和导出。")
                    Text("新资料默认关闭，内容改变后需要重新允许。这里仅设置可用范围，点击填写页的发送按钮后才会发送。原文件和完整提取原文不会自动附带。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("已允许 \(flow.aiSharingEntries.filter { flow.isAISharingAllowed($0) }.count) / \(flow.aiSharingEntries.count) 项") {
                    if flow.aiSharingEntries.isEmpty {
                        Text("暂无已建档资料。请先完成建档并核对内容，也可以在信息库中手动添加。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(flow.aiSharingEntries) { entry in
                        ProfileAIPermissionRow(flow: flow, entry: entry)
                    }
                }
                if let error = flow.transientError {
                    Section { Text(error).foregroundStyle(.orange) }
                }
                if flow.aiSharingSaveFailed {
                    Section {
                        Button("重试保存当前权限") { Task { await flow.retryAISharingSave() } }
                            .disabled(flow.isUpdatingAISharing)
                    }
                }
            }
            .navigationTitle("AI 可用资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(flow.isUpdatingAISharing || flow.aiSharingSaveFailed)
                }
            }
            .interactiveDismissDisabled(flow.isUpdatingAISharing || flow.aiSharingSaveFailed)
        }
    }
}

private struct ProfileAIPermissionRow: View {
    let flow: FlowStore
    let entry: ProfileAISharingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { flow.isAISharingAllowed(entry) },
                set: { allowed in Task { await flow.setAISharingAllowed(entry, allowed: allowed) } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.label).font(.headline)
                    Text(entry.personLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(flow.isUpdatingAISharing || (!flow.isAISharingAllowed(entry) && flow.aiSharingBlockReason(entry) != nil))
            .accessibilityIdentifier("ai-sharing-\(entry.id.uuidString)")
            Text(entry.value).font(.subheadline).textSelection(.enabled)
            if let reason = flow.aiSharingBlockReason(entry) {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("查看允许后可发送的内容") {
                Text(entry.text).font(.footnote).textSelection(.enabled)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct ProfileAIPermissionsEntry: View {
    let flow: FlowStore
    var onDismiss: () -> Void = {}
    @State private var presented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                presented = true
            } label: {
                Label("AI 可用资料 · 已允许 \(flow.aiSharingEntries.filter { flow.isAISharingAllowed($0) }.count) 项", systemImage: "hand.raised")
            }
            .disabled(flow.isUpdatingAISharing)
            .accessibilityIdentifier("manage-ai-sharing")
            Text("整表与单空共用；未允许的资料仍可本地填写。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $presented, onDismiss: onDismiss) {
            ProfileAIPermissionsView(flow: flow)
        }
    }
}
