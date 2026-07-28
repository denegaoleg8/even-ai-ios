import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            List {
                Section {
                    Picker("Appearance", selection: $viewModel.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } header: {
                    SectionHeader(title: "Appearance")
                }

                Section {
                    NavigationLink {
                        VoicePlaceholderView()
                    } label: {
                        Label("Voice", systemImage: "waveform")
                    }
                    NavigationLink {
                        VisionPlaceholderView()
                    } label: {
                        Label("Vision", systemImage: "eye")
                    }
                    NavigationLink {
                        GlassesPlaceholderView()
                    } label: {
                        Label("Glasses", systemImage: "eyeglasses")
                    }
                } header: {
                    SectionHeader(title: "Preview Features")
                }

                Section {
                    LabeledContent("Version", value: viewModel.appVersion)
                } header: {
                    SectionHeader(title: "About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
