import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FillTaskRecord.updatedAt, order: .reverse)
    private var tasks: [FillTaskRecord]
    let flow: FlowStore
    @State private var taskPendingDeletion: FillTaskRecord?
    @State private var isClearConfirmationPresented = false
    @State private var isDemoAccessPresented = false

    private var profileTitle: String {
        flow.profile.hasInformation ? "我的信息库" : "建立我的信息"
    }

    private var profileSummary: String {
        flow.profile.hasInformation
            ? "\(flow.profile.informationItems.count) 项信息 · \(flow.profile.fullName.isEmpty ? "可随时补充" : flow.profile.fullName)"
            : "导入简历、学生证或成绩单"
    }

    private var profileDetail: String {
        flow.profile.hasInformation
            ? "可分类搜索、查看来源并持续复用"
            : "先在本机识别材料，建立不限项的信息库"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("表匣")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text("选一份空白表，用我的信息自动填写。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .listRowInsets(EdgeInsets(top: 24, leading: 24, bottom: 14, trailing: 24))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                Button {
                    Task { await flow.createTask(in: modelContext) }
                } label: {
                    Label("填写空白表", systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("start-form-filling")
                .buttonStyle(PrimaryButtonStyle())
                .disabled(flow.isWorking || !flow.profile.hasInformation)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 14, trailing: 24))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                Button {
                    flow.openProfileLibrary()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.text.rectangle")
                            .font(.title2)
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profileTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(profileSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(profileDetail)
                                .font(.caption)
                                .foregroundStyle(flow.profile.hasInformation ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("manage-profile")
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 18, trailing: 24))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    isDemoAccessPresented = true
                } label: {
                    Label("演示访问", systemImage: "key.horizontal")
                }
                .accessibilityIdentifier("open-demo-access")
                .disabled(flow.isWorking)
            }

            if !tasks.isEmpty {
                Section {
                    ForEach(tasks) { task in
                        Button {
                            Task { await flow.open(task, in: modelContext) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: task.status == .completed
                                      ? "checkmark.circle.fill"
                                      : "doc.text")
                                    .font(.title2)
                                    .foregroundStyle(task.status == .completed ? .green : .teal)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title)
                                        .foregroundStyle(.primary)
                                    Text("\(task.status.title) · \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("recent-task-\(task.id.uuidString)")
                        .disabled(flow.isWorking)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) {
                                taskPendingDeletion = task
                            }
                            .disabled(flow.isWorking)
                        }
                    }
                } header: {
                    HStack {
                        Text("最近任务")
                        Spacer()
                        Button("清空", role: .destructive) {
                            isClearConfirmationPresented = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .textCase(nil)
                        .accessibilityIdentifier("clear-recent-tasks")
                        .disabled(flow.isWorking)
                    }
                }
            }
        }
        .sheet(isPresented: $isDemoAccessPresented) { DemoAccessView() }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationBarHidden(true)
        .alert(
            "删除任务？",
            isPresented: Binding(
                get: { taskPendingDeletion != nil },
                set: { if !$0 { taskPendingDeletion = nil } }
            ),
            presenting: taskPendingDeletion
        ) { task in
            Button("删除", role: .destructive) {
                taskPendingDeletion = nil
                Task { await flow.deleteTask(task, in: modelContext) }
            }
            Button("取消", role: .cancel) {
                taskPendingDeletion = nil
            }
        } message: { task in
            Text("将永久删除“\(task.title)”及其空表、填写结果和导出文件。")
        }
        .alert("清空最近任务？", isPresented: $isClearConfirmationPresented) {
            Button("全部清空", role: .destructive) {
                Task { await flow.clearTasks(tasks, in: modelContext) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将永久删除全部 \(tasks.count) 个任务及其空表、填写结果和导出文件。此操作无法撤销。")
        }
    }
}
