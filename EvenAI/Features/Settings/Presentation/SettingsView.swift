import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthState.self) private var authState
    @State private var viewModel = SettingsViewModel()
    @State private var isAuthSheetPresented = false
    @State private var isSignOutConfirmationPresented = false

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            List {
                accountSection

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
            .sheet(isPresented: $isAuthSheetPresented) {
                AuthWelcomeView(onAuthenticated: { isAuthSheetPresented = false })
            }
            .confirmationDialog(
                "Sign Out",
                isPresented: $isSignOutConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    Task { await authState.signOut() }
                }
                Button("Sign Out on All Devices", role: .destructive) {
                    Task { await authState.signOutEverywhere() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can sign back in at any time. Conversations already synced to this account stay on the server.")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if authState.isRestoringSession && authState.currentUser == nil {
                HStack(spacing: AppMetrics.Spacing.sm) {
                    ProgressView()
                    Text("Loading account...")
                        .foregroundStyle(AppColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.accountLoading")
            } else if let user = authState.currentUser, user.email != nil {
                VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                    if let displayName = user.displayName, !displayName.isEmpty {
                        Text(displayName)
                            .font(AppTypography.chatTitle)
                    }
                    Text(user.email ?? "")
                        .font(AppTypography.chatPreview)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.accountSignedIn")

                Button("Sign Out", role: .destructive) {
                    isSignOutConfirmationPresented = true
                }
                .accessibilityIdentifier("settings.signOutButton")
            } else {
                Button {
                    isAuthSheetPresented = true
                } label: {
                    Label("Sign In or Create Account", systemImage: "person.crop.circle.badge.plus")
                }
                .accessibilityIdentifier("settings.signInButton")
            }
        } header: {
            SectionHeader(title: "Account")
        }
    }
}

#Preview {
    SettingsView()
        .environment(AuthState())
}
