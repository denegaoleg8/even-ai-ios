import SwiftUI

/// Settings → Personal AI. The landing screen for Phase 1: a link into the
/// Personal AI Chat and into the Memory Center, plus the global memory
/// switch. Intentionally small — it adds nothing to the proven sidebar /
/// root navigation.
struct PersonalAIView: View {
    @Environment(PersonalAIService.self) private var personalAI

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PersonalAIChatView()
                } label: {
                    Label("Personal AI Chat", systemImage: "brain.head.profile")
                }
                NavigationLink {
                    MemoryCenterView()
                } label: {
                    Label("Memory", systemImage: "tray.full")
                }
                NavigationLink {
                    PersonalAIDataBackupView()
                } label: {
                    Label("Data & Backup", systemImage: "externaldrive.badge.icloud")
                }
            } footer: {
                Text("Your Personal AI remembers useful things you tell it and connects new questions to relevant past context. Everything it remembers is visible and editable in Memory.")
            }

            Section {
                Toggle("Remember things from conversations", isOn: Binding(
                    get: { personalAI.memoryEnabled },
                    set: { newValue in Task { await personalAI.setMemoryEnabled(newValue) } }
                ))
            } footer: {
                Text("When off, the Personal AI answers only from the current conversation and stores nothing new. Existing memories are kept but not used.")
            }
        }
        .navigationTitle("Personal AI")
        .navigationBarTitleDisplayMode(.inline)
        .task { await personalAI.open() }
    }
}
