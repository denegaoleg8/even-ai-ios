import SwiftUI

// MARK: - Memory detail

struct MemoryDetailView: View {
    let record: MemoryRecord
    let model: MemoryCenterViewModel
    @Environment(PersonalAIService.self) private var personalAI
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var revisions: [RecordRevision] = []

    var body: some View {
        List {
            Section {
                Text(record.canonicalContent)
            } header: {
                Text(record.category.displayName)
            }

            Section("Controls") {
                Toggle("Enabled", isOn: binding(\.enabled) { await personalAI.setMemoryEnabled(id: record.id, enabled: $0) })
                Toggle("Pinned", isOn: binding(\.pinned) { await personalAI.setMemoryConfirmed(id: record.id, confirmed: true, pinned: $0) })
                Toggle("Confirmed by me", isOn: binding(\.userConfirmed) { await personalAI.setMemoryConfirmed(id: record.id, confirmed: $0, pinned: record.pinned) })
                Button("Edit Text") { isEditing = true }
                Button("Delete", role: .destructive) {
                    Task { await personalAI.deleteMemory(id: record.id); await model.reload(personalAI); dismiss() }
                }
            }

            Section("Details") {
                LabeledContent("Status", value: record.status.rawValue)
                LabeledContent("Confidence", value: String(format: "%.0f%%", record.confidence * 100))
                LabeledContent("Importance", value: String(format: "%.0f%%", record.importance * 100))
                LabeledContent("Created", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Updated", value: record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                if let expiresAt = record.expiresAt {
                    LabeledContent("Expires", value: expiresAt.formatted(date: .abbreviated, time: .shortened))
                }
                if !record.entities.isEmpty {
                    LabeledContent("Entities", value: record.entities.joined(separator: ", "))
                }
            }

            Section("Provenance") {
                LabeledContent("Source conversations", value: "\(record.sourceConversationIDs.count)")
                LabeledContent("Source messages", value: "\(record.sourceMessageIDs.count)")
                if let supersedes = record.supersedesID {
                    LabeledContent("Replaced memory", value: supersedes.uuidString.prefix(8).description)
                }
                if let supersededBy = record.supersededByID {
                    LabeledContent("Replaced by", value: supersededBy.uuidString.prefix(8).description)
                }
                LabeledContent("Sync state", value: record.syncState.rawValue)
                LabeledContent("Revision", value: "\(record.revision)")
            }

            if !revisions.isEmpty {
                Section("Version History") {
                    ForEach(revisions) { rev in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.previewText(rev.previousPayloadJSON))
                                .font(.footnote)
                                .lineLimit(2)
                            Text("\(rev.reason) · \(rev.changedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Restore") {
                                Task {
                                    _ = await personalAI.restoreMemoryRevision(rev.id)
                                    await model.reload(personalAI)
                                    dismiss()
                                }
                            }.tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .task { revisions = await personalAI.revisions(recordID: record.id).reversed() }
        .sheet(isPresented: $isEditing) {
            MemoryEditorView(mode: .edit(record)) { content, category in
                _ = await personalAI.updateMemoryContent(id: record.id, content: content, category: category)
                await model.reload(personalAI)
                dismiss()
            }
        }
    }

    static func previewText(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["canonicalContent"] as? String else { return "(earlier version)" }
        return content
    }

    private func binding(_ keyPath: KeyPath<MemoryRecord, Bool>, _ apply: @escaping (Bool) async -> Void) -> Binding<Bool> {
        Binding(
            get: { record[keyPath: keyPath] },
            set: { newValue in Task { await apply(newValue); await model.reload(personalAI) } }
        )
    }
}

// MARK: - Memory editor (add / edit)

struct MemoryEditorView: View {
    enum Mode {
        case add
        case edit(MemoryRecord)
    }

    let mode: Mode
    let onSave: (_ content: String, _ category: MemoryCategory) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var category: MemoryCategory = .knowledge
    @State private var showSecretWarning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Memory") {
                    TextField("What should the Personal AI remember?", text: $content, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(MemoryCategory.userFacing, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                }
                if showSecretWarning {
                    Text("That looks like a password or key. Personal AI memory never stores credentials.")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle(isEdit ? "Edit Memory" : "Add Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if SecretDetector.containsSecret(content) {
                            showSecretWarning = true
                        } else {
                            Task { await onSave(content.trimmingCharacters(in: .whitespacesAndNewlines), category); dismiss() }
                        }
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                }
            }
            .onAppear {
                if case let .edit(record) = mode {
                    content = record.canonicalContent
                    category = record.category
                }
            }
        }
    }

    private var isEdit: Bool { if case .edit = mode { return true } else { return false } }
}

// MARK: - Rules

struct RuleListView: View {
    let model: MemoryCenterViewModel
    @Environment(PersonalAIService.self) private var personalAI
    @State private var isAdding = false

    var body: some View {
        List {
            if model.rules.isEmpty {
                Text("No rules yet. Say things like \"from now on, keep replies short\" or \"never open with 'thanks for sharing'\".")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rules) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.text)
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                    HStack(spacing: 6) {
                        Text(rule.priority.displayName).font(.caption2)
                        Text("·").font(.caption2)
                        Text(rule.scope.displayName).font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        Task { await personalAI.deleteRule(id: rule.id); await model.reload(personalAI) }
                    }
                    Button(rule.enabled ? "Disable" : "Enable") {
                        Task { await personalAI.setRuleEnabled(id: rule.id, enabled: !rule.enabled); await model.reload(personalAI) }
                    }
                }
            }
        }
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $isAdding) {
            RuleEditorView { text in
                await personalAI.addManualRule(text: text)
                await model.reload(personalAI)
            }
        }
    }
}

struct RuleEditorView: View {
    let onSave: (_ text: String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule") {
                    TextField("e.g. Keep business replies short.", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Add Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                }
            }
        }
    }
}

// MARK: - Style profile

struct StyleProfileView: View {
    let profile: PersonalAIStyleProfile

    var body: some View {
        List {
            if !profile.hasSignal {
                Text("Nothing learned yet. Tell the Personal AI things like \"keep replies short\", \"be direct\", or \"use Ukrainian with me\".")
                    .foregroundStyle(.secondary)
            }
            if let lang = profile.preferredLanguage {
                LabeledContent("Language", value: Locale(identifier: "en").localizedString(forLanguageCode: lang) ?? lang)
            }
            if profile.responseLength != .unspecified {
                LabeledContent("Length", value: profile.responseLength.rawValue.capitalized)
            }
            row("Directness", profile.directness)
            row("Formality", profile.formality)
            row("Technical depth", profile.technicalDepth)
            row("Proactiveness", profile.proactiveness)
            row("Humor", profile.humor)
            if profile.formatting != .unspecified {
                LabeledContent("Formatting", value: profile.formatting.rawValue.capitalized)
            }
            if !profile.phrasesToAvoid.isEmpty {
                Section("Phrases to avoid") {
                    ForEach(profile.phrasesToAvoid, id: \.self) { Text($0) }
                }
            }
        }
        .navigationTitle("Response Style")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: Double?) -> some View {
        if let value {
            LabeledContent(label, value: String(format: "%.0f%%", value * 100))
        }
    }
}
