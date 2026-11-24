import SwiftUI

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let flow: FlowStore
    @State private var draft: PersonalProfile
    @State private var isSaving = false

    init(flow: FlowStore) {
        self.flow = flow
        _draft = State(initialValue: flow.profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "这里编辑常用基础字段；其他信息可在信息库中单独添加或修改。",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("基本信息") {
                    profileField("姓名", text: $draft.fullName, id: "profile-fullName")
                    profileField("性别", text: $draft.gender, id: "profile-gender")
                    profileField("出生日期", text: $draft.birthDate, id: "profile-birthDate")
                }

                Section("学校信息") {
                    profileField("学校", text: $draft.school, id: "profile-school")
                    profileField("学院", text: $draft.college, id: "profile-college")
                    profileField("专业", text: $draft.major, id: "profile-major")
                    profileField("学号", text: $draft.studentID, id: "profile-studentID")
                }

                Section("联系信息") {
                    profileField("手机", text: $draft.phone, id: "profile-phone")
                    profileField("邮箱", text: $draft.email, id: "profile-email")
                    TextField("地址", text: $draft.address, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("profile-address")
                }
            }
            .navigationTitle("我的信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            await flow.saveProfile(draft)
                            isSaving = false
                            if flow.profile == draft {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSaving || !draft.hasInformation)
                    .accessibilityIdentifier("save-profile")
                }
            }
        }
    }

    @ViewBuilder
    private func profileField(
        _ title: String,
        text: Binding<String>,
        id: String
    ) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }
}
