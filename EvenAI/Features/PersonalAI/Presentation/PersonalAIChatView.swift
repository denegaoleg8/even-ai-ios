import SwiftUI

/// The dedicated Personal AI chat. Always opens, retains history, drives
/// `PersonalAIService` (which uses `PersonalAIContextBuilding` +
/// `PersonalAIModelProviding` under the hood). Text input only for Phase 1;
/// voice is a future-compatible addition, not a redesign.
struct PersonalAIChatView: View {
    @Environment(PersonalAIService.self) private var personalAI
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            Divider()
            footer
            MessageInputBar(text: $draft, isSending: personalAI.status == .thinking) {
                let text = draft
                draft = ""
                Task { await personalAI.send(text) }
            }
        }
        .navigationTitle("Personal AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await personalAI.startNewConversation() }
                    } label: {
                        Label("New Conversation", systemImage: "square.and.pencil")
                    }
                    Toggle(isOn: Binding(
                        get: { personalAI.conversationDoNotRemember },
                        set: { v in Task { await personalAI.setConversationDoNotRemember(v) } }
                    )) {
                        Label("Do Not Remember This Conversation", systemImage: "eye.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await personalAI.open() }
    }

    @ViewBuilder
    private var messagesList: some View {
        if personalAI.messages.isEmpty {
            EmptyStateView(
                systemImage: "brain.head.profile",
                title: "Your Personal AI",
                subtitle: "Tell it what you're working on, ask for help, or say things like \"remember that…\" or \"from now on…\". It connects new questions to what it already knows."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppMetrics.Spacing.md) {
                        ForEach(personalAI.messages) { message in
                            PersonalAIMessageRow(message: message)
                                .id(message.id)
                        }
                        if personalAI.status == .thinking {
                            TypingIndicatorView()
                                .padding(.leading, AppMetrics.Spacing.sm)
                        }
                    }
                    .padding(AppMetrics.Spacing.md)
                }
                .onChange(of: personalAI.messages.count) {
                    if let last = personalAI.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case let .failed(message) = personalAI.status {
            banner(text: message, systemImage: "exclamationmark.triangle", tint: .orange)
        } else if let note = personalAI.lastCommandNote {
            banner(text: note, systemImage: "checkmark.circle", tint: AppColor.accent)
        } else if personalAI.conversationDoNotRemember {
            banner(text: "This conversation won't be remembered.", systemImage: "eye.slash", tint: AppColor.textSecondary)
        } else if !personalAI.memoryEnabled {
            banner(text: "Memory is off — answering from this conversation only.", systemImage: "tray", tint: AppColor.textSecondary)
        }
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: AppMetrics.Spacing.sm) {
            Image(systemName: systemImage)
            Text(text).font(.footnote)
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, AppMetrics.Spacing.md)
        .padding(.vertical, AppMetrics.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.secondaryBackground)
    }
}

private struct PersonalAIMessageRow: View {
    let message: PersonalAIChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .padding(.horizontal, AppMetrics.Spacing.md)
                .padding(.vertical, AppMetrics.Spacing.sm)
                .background(message.role == .user ? AppColor.accent.opacity(0.15) : AppColor.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.bubble, style: .continuous))
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
