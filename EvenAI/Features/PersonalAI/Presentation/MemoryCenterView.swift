import SwiftUI

/// Settings → Personal AI → Memory. Makes everything the Personal AI
/// remembers visible and controllable: browse, filter by category, search,
/// add, edit, correct, enable/disable, pin/confirm, delete — plus a Rules
/// section.
struct MemoryCenterView: View {
    @Environment(PersonalAIService.self) private var personalAI
    @State private var model = MemoryCenterViewModel()
    @State private var isAddingMemory = false
    @State private var isAddingRule = false

    var body: some View {
        @Bindable var model = model
        return List {
            Section {
                NavigationLink {
                    RuleListView(model: model)
                } label: {
                    LabeledContent("Rules", value: "\(model.rules.count)")
                }
                NavigationLink {
                    StyleProfileView(profile: model.styleProfile)
                } label: {
                    Text("Response Style")
                }
            }

            Section {
                Picker("Category", selection: $model.categoryFilter) {
                    Text("All").tag(MemoryCategory?.none)
                    ForEach(MemoryCategory.userFacing, id: \.self) { category in
                        Text(category.displayName).tag(MemoryCategory?.some(category))
                    }
                }
                .pickerStyle(.menu)
                Toggle("Show archived / superseded", isOn: $model.showInactive)
            }

            Section {
                if model.filteredMemories.isEmpty {
                    Text("No memories yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.filteredMemories) { record in
                        NavigationLink {
                            MemoryDetailView(record: record, model: model)
                        } label: {
                            MemoryRow(record: record)
                        }
                    }
                }
            } header: {
                Text("Memories (\(model.filteredMemories.count))")
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.searchText)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { isAddingMemory = true } label: { Label("Add Memory", systemImage: "note.text.badge.plus") }
                    Button { isAddingRule = true } label: { Label("Add Rule", systemImage: "text.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingMemory) {
            MemoryEditorView(mode: .add) { content, category in
                await personalAI.addManualMemory(content: content, category: category)
                await model.reload(personalAI)
            }
        }
        .sheet(isPresented: $isAddingRule) {
            RuleEditorView { text in
                await personalAI.addManualRule(text: text)
                await model.reload(personalAI)
            }
        }
        .task { await model.reload(personalAI) }
        .refreshable { await model.reload(personalAI) }
    }
}

@MainActor
@Observable
final class MemoryCenterViewModel {
    var memories: [MemoryRecord] = []
    var rules: [Rule] = []
    var styleProfile: PersonalAIStyleProfile = .empty
    var categoryFilter: MemoryCategory?
    var showInactive = false
    var searchText = ""

    var filteredMemories: [MemoryRecord] {
        memories
            .filter { showInactive || ($0.status == .active) }
            .filter { record in
                guard record.status != .deleted else { return false }
                if let categoryFilter, record.category != categoryFilter { return false }
                if !searchText.isEmpty {
                    let haystack = (record.canonicalContent + " " + record.entities.joined(separator: " ")).lowercased()
                    if !haystack.contains(searchText.lowercased()) { return false }
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func reload(_ service: PersonalAIService) async {
        memories = await service.loadMemories()
        rules = await service.loadRules()
        styleProfile = await service.loadStyleProfile()
    }
}

private struct MemoryRow: View {
    let record: MemoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.canonicalContent)
                .lineLimit(2)
                .foregroundStyle(record.enabled && record.status == .active ? .primary : .secondary)
            HStack(spacing: 6) {
                Text(record.category.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if record.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                if record.userConfirmed { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green) }
                if record.status == .superseded { Text("superseded").font(.caption2).foregroundStyle(.secondary) }
                if record.status == .archived { Text("archived").font(.caption2).foregroundStyle(.secondary) }
                if !record.enabled { Text("disabled").font(.caption2).foregroundStyle(.secondary) }
                if record.expiresAt != nil { Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}
