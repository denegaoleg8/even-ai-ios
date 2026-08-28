import SwiftUI

/// Settings → Personal AI → Data & Backup (§25).
///
/// **Honesty first (§16):** the UI's wording is driven by
/// `PersonalAIService.cloudEnvironment`. Today a shipping build is
/// `.notConfigured` — no external provider — so this screen says exactly
/// that and offers only what is genuinely available: on-device encrypted
/// storage plus Export / local Backup files. It never says "synced" or
/// "backed up to the cloud" unless a real provider is `.connected`.
struct PersonalAIDataBackupView: View {
    @Environment(PersonalAIService.self) private var personalAI
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var showDeleteCloudConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var busy = false

    private var env: PersonalCloudEnvironment { personalAI.cloudEnvironment }

    var body: some View {
        List {
            environmentSection
            if env != .notConfigured { syncSection }
            if env != .notConfigured { statusSection }
            exportSection
            backupSection
            dangerSection
        }
        .navigationTitle("Data & Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await personalAI.open() }
        .sheet(isPresented: $isExporting) {
            if let exportURL {
                VStack(spacing: 16) {
                    Text("Export ready").font(.headline)
                    Text(exportURL.lastPathComponent).font(.footnote).foregroundStyle(.secondary)
                    ShareLink(item: exportURL)
                    Button("Done") { isExporting = false }
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task {
                busy = true
                switch await personalAI.importBackup(from: url) {
                case .success(let r): importMessage = "Restored \(r.memoriesImported) memories, \(r.messagesImported) messages."
                case .failure(let e): importMessage = e.userFacingMessage
                }
                busy = false
            }
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importMessage ?? "") }
    }

    // MARK: Sections

    @ViewBuilder private var environmentSection: some View {
        Section {
            LabeledContent("Personal AI Cloud", value: env.displayName)
        } footer: {
            switch env {
            case .notConfigured:
                Text("Personal AI Cloud isn't set up. Your memory is stored **only on this device**, encrypted. It will **not** survive losing or erasing this iPhone. To keep a copy elsewhere, use Export or create a Backup file below.")
            case .simulated:
                Text("⚠️ Simulated cloud — development build only. The \"server\" is in memory: data here does **not** survive an app relaunch, a reinstall, or device loss. This is for testing the sync flow, not real durability.")
            case .connected:
                Text("Your Personal AI memory is synced to the cloud and restored automatically on a new device after you sign in.")
            }
        }
    }

    @ViewBuilder private var syncSection: some View {
        Section {
            Toggle("Cloud Sync", isOn: Binding(
                get: { personalAI.cloudSyncEnabled },
                set: { v in Task { await personalAI.setCloudSyncEnabled(v) } }
            ))
            .disabled(!personalAI.isAuthenticated)
            Button {
                Task { busy = true; _ = await personalAI.syncNow(); busy = false }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!personalAI.cloudSyncEnabled || busy)
            Button {
                Task { busy = true; _ = await personalAI.restoreFromCloud(); busy = false }
            } label: {
                Label("Restore from Cloud", systemImage: "icloud.and.arrow.down")
            }
            .disabled(!personalAI.isAuthenticated || busy)
        } footer: {
            if !personalAI.isAuthenticated {
                Text("Sign in to enable cloud sync.")
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section("Status") {
            statusRow("Last synced", value: relative(personalAI.lastSyncedAt), status: personalAI.syncStatus)
            LabeledContent("Pending changes", value: "\(personalAI.pendingSyncCount)")
            statusRow("Last backup", value: relative(personalAI.lastBackupAt), status: personalAI.backupStatus)
        }
    }

    @ViewBuilder private var exportSection: some View {
        Section {
            exportButton("Export All Personal AI Data", .everything)
            exportButton("Export Memories & Rules", .memoriesOnly)
            exportButton("Export Conversations", .conversationsOnly)
        } header: {
            Text("Export")
        } footer: {
            Text("A portable JSON file you can read without EvenAI and re-import on any device. Contains your memories, rules, style, and conversations — never passwords or tokens.")
        }
    }

    @ViewBuilder private var backupSection: some View {
        Section {
            Button {
                Task { busy = true; _ = await personalAI.backupNow(); busy = false }
            } label: {
                Label("Create Backup File", systemImage: "externaldrive.badge.plus")
            }.disabled(busy)
            Button {
                isImporting = true
            } label: {
                Label("Restore from Backup File", systemImage: "arrow.uturn.backward.circle")
            }.disabled(busy)
        } header: {
            Text("Backup")
        } footer: {
            Text("Backup files are AES-256 encrypted on this device before they are written. \(env == .connected ? "They are also uploaded to independent storage." : "They are stored in this app's container — move a copy somewhere safe (iCloud Drive, a computer) for real protection against device loss.")")
        }
    }

    @ViewBuilder private var dangerSection: some View {
        Section {
            if personalAI.cloudProvidesDurability || env == .simulated {
                Button(role: .destructive) { showDeleteCloudConfirm = true } label: {
                    Label("Delete Cloud Data", systemImage: "trash")
                }
            }
            Button(role: .destructive) { showDeleteAccountConfirm = true } label: {
                Label("Delete Personal AI Data", systemImage: "person.crop.circle.badge.xmark")
            }
        } header: {
            Text("Danger Zone")
        } footer: {
            Text(env == .connected
                 ? "Deleting cloud data removes the server copy but keeps this device's data. Deleting all Personal AI data removes memories, rules, conversations, style, and the local encryption key everywhere. Independent backups already made may be retained for up to 30 days per the retention policy."
                 : "Deleting all Personal AI data erases every memory, rule, conversation, style setting, and the local encryption key on this device. Any Export or Backup files you already saved are not touched.")
        }
        .confirmationDialog("Delete all Personal AI data from the cloud?", isPresented: $showDeleteCloudConfirm, titleVisibility: .visible) {
            Button("Delete Cloud Data", role: .destructive) { Task { await personalAI.deleteCloudData() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Permanently delete all Personal AI data?", isPresented: $showDeleteAccountConfirm, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { Task { await personalAI.deletePersonalAIAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases every memory, rule, conversation, and the local encryption key. It cannot be undone.")
        }
    }

    // MARK: Helpers

    private func exportButton(_ title: String, _ selection: ExportSelection) -> some View {
        Button {
            Task {
                busy = true
                exportURL = await personalAI.exportData(selection)
                busy = false
                if exportURL != nil { isExporting = true }
            }
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }.disabled(busy)
    }

    private func statusRow(_ label: String, value: String, status: PersonalCloudOperationStatus) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                switch status {
                case .running: ProgressView().controlSize(.mini)
                case .failed(let code): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(code).font(.caption)
                case .succeeded, .idle: EmptyView()
                }
                Text(value).foregroundStyle(.secondary)
            }
        }
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}
