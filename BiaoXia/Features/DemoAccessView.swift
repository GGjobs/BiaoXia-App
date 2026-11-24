import SwiftUI

struct DemoAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var status: DemoAccessStatus?
    @State private var hasSavedAccess = false
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                DemoAccessInputSection(address: $address, token: $token)
                    .disabled(isWorking)
                if let status {
                    DemoAccessStatusSection(status: status)
                }
                Section {
                    Button("验证并保存") { Task { await save() } }
                        .disabled(isWorking || address.isEmpty || token.isEmpty)
                        .accessibilityIdentifier("save-demo-access")
                    if hasSavedAccess {
                        Button("刷新已保存凭证的状态") { Task { await refresh() } }
                            .disabled(isWorking)
                        Button("移除本机演示凭证", role: .destructive) { remove() }
                            .disabled(isWorking)
                    }
                    if isWorking { ProgressView("正在验证演示访问…") }
                    if let message { Text(message).foregroundStyle(.secondary) }
                } footer: {
                    Text("验证只发送演示凭证。解释表格时仍需逐项核对并允许发送文字。未开通或云端不可用时，可继续人工填写、核对和导出。")
                }
            }
            .navigationTitle("演示访问")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(isWorking) } }
            .interactiveDismissDisabled(isWorking)
            .task { load() }
        }
    }

    private func load() {
        do {
            if let saved = try DemoAccessKeychain.load() {
                address = saved.endpoint.absoluteString
                hasSavedAccess = true
                message = "已保存演示凭证，可刷新状态。"
            }
        } catch { message = error.localizedDescription }
    }

    private func save() async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let configuration = try DemoAccessConfiguration(
                address: address, token: token.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let verified = try await DemoAccessService.status(for: configuration)
            try DemoAccessKeychain.save(configuration)
            status = verified
            token = ""
            hasSavedAccess = true
            message = "演示访问已保存。"
        } catch { message = error.localizedDescription }
    }

    private func refresh() async {
        isWorking = true
        status = nil
        defer { isWorking = false }
        do {
            guard let saved = try DemoAccessKeychain.load() else { hasSavedAccess = false; return }
            status = try await DemoAccessService.status(for: saved)
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func remove() {
        do {
            try DemoAccessKeychain.remove()
            hasSavedAccess = false
            token = ""
            status = nil
            message = "已移除本机演示凭证。"
        } catch { message = error.localizedDescription }
    }
}

private struct DemoAccessInputSection: View {
    @Binding var address: String
    @Binding var token: String

    var body: some View {
        Section {
            TextField("HTTPS 服务地址", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("demo-access-address")
            SecureField("演示凭证", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .accessibilityIdentifier("demo-access-token")
        } header: {
            Text("由演示提供者发放")
        } footer: {
            Text("仅填写你信任的演示服务地址。凭证保存在这台设备的安全存储中。")
        }
    }
}

private struct DemoAccessStatusSection: View {
    let status: DemoAccessStatus

    var body: some View {
        Section("已保存凭证的状态") {
            LabeledContent("有效期至") {
                Text(Date(timeIntervalSince1970: status.expiresAt), format: .dateTime.year().month().day().hour().minute())
            }
            Text("演示访问已启用。请求较频繁时，请稍后重试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
