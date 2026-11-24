import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var flow = FlowStore(fieldExplanationSubmitter: ConfiguredFieldExplanationService(), answerComposer: ConfiguredAnswerCompositionService())

    var body: some View {
        NavigationStack {
            Group {
                if flow.isProfileLibraryPresented {
                    profileView(for: flow.profileLibrary)
                } else if let snapshot = flow.snapshot {
                    if flow.isFormImportPresented {
                        ImportView(flow: flow)
                    } else {
                        taskView(for: snapshot)
                    }
                } else {
                    HomeView(flow: flow)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: flow.snapshot?.status)
            .alert(
                "提示",
                isPresented: Binding(
                    get: { flow.transientError != nil },
                    set: { if !$0 { flow.transientError = nil } }
                ),
                actions: {
                    Button("知道了") { flow.transientError = nil }
                },
                message: {
                    Text(flow.transientError ?? "")
                }
            )
        }
        .tint(Color(red: 0.12, green: 0.38, blue: 0.34))
        .task {
            await flow.loadProfile()
        }
    }

    @ViewBuilder
    private func profileView(for snapshot: ProfileLibrarySnapshot) -> some View {
        switch snapshot.status {
        case .draft, .imported, .confirmed:
            MaterialLibraryView(flow: flow)
        case .recognizing:
            ProfileRecognitionView(flow: flow)
        case .awaitingAIConsent, .resolving, .reviewing:
            ProfileReviewView(flow: flow)
        case .failed:
            MaterialLibraryView(flow: flow)
        }
    }

    @ViewBuilder
    private func taskView(for snapshot: FillTaskSnapshot) -> some View {
        switch snapshot.status {
        case .draft:
            ImportView(flow: flow)
        case .imported, .recognizing:
            RecognitionView(flow: flow)
        case .awaitingAIConsent, .resolving, .reviewing, .exporting:
            ReviewView(flow: flow)
        case .completed:
            ExportView(flow: flow)
        case .failed:
            FailureView(flow: flow)
        }
    }
}

struct PageHeader: View {
    let step: String
    let title: String
    let detail: String
    var onPrevious: (() -> Void)? = nil
    var previousDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text(step)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let onPrevious {
                    Spacer(minLength: 0)
                    Button(action: onPrevious) {
                        Label("上一步", systemImage: "chevron.backward")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 4)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(previousDisabled)
                    .accessibilityLabel("返回上一步")
                    .accessibilityIdentifier("previous-step")
                }
            }
            Text(title)
                .font(.largeTitle.bold())
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                Color(red: 0.12, green: 0.38, blue: 0.34)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            )
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.8))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
