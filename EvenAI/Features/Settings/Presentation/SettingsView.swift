import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AuthState.self) private var authState
    @State private var viewModel = SettingsViewModel()
    @State private var isAuthSheetPresented = false
    @State private var isSignOutConfirmationPresented = false
    @State private var isMergeSheetPresented = false
    @State private var isDeleteAccountPresented = false

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
            .sheet(isPresented: $isMergeSheetPresented) {
                if let mergeAvailableFrom = authState.mergeAvailableFrom {
                    MergeAccountView(fromAccountID: mergeAvailableFrom, onFinished: { isMergeSheetPresented = false })
                }
            }
            .sheet(isPresented: $isDeleteAccountPresented) {
                DeleteAccountView()
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
                HStack(spacing: AppMetrics.Spacing.md) {
                    AccountAvatarView(user: user)
                    VStack(alignment: .leading, spacing: AppMetrics.Spacing.xs) {
                        if let displayName = user.displayName, !displayName.isEmpty {
                            Text(displayName)
                                .font(AppTypography.chatTitle)
                        }
                        Text(user.email ?? "")
                            .font(AppTypography.chatPreview)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.accountSignedIn")

                LabeledContent("Subscription", value: viewModel.subscriptionTier)
                deviceIDRow

                if authState.mergeAvailableFrom != nil {
                    Button {
                        isMergeSheetPresented = true
                    } label: {
                        Label("Merge Conversations from This Device", systemImage: "arrow.triangle.merge")
                    }
                    .accessibilityIdentifier("settings.mergeButton")
                }

                Button("Sign Out", role: .destructive) {
                    isSignOutConfirmationPresented = true
                }
                .accessibilityIdentifier("settings.signOutButton")

                Button("Delete Account", role: .destructive) {
                    isDeleteAccountPresented = true
                }
                .accessibilityIdentifier("settings.deleteAccountButton")
            } else {
                Button {
                    isAuthSheetPresented = true
                } label: {
                    Label("Sign In or Create Account", systemImage: "person.crop.circle.badge.plus")
                }
                .accessibilityIdentifier("settings.signInButton")

                deviceIDRow
            }
        } header: {
            SectionHeader(title: "Account")
        }
    }

    private var deviceIDRow: some View {
        LabeledContent("Device ID") {
            Text(viewModel.deviceID)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(AppColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("settings.deviceID")
    }
}

/// Initials-on-a-circle placeholder — there's no profile photo system in
/// this app, so this is what "avatar placeholder" (Phase 3.7) means:
/// real derived data (the account's own name/email), not a static
/// silhouette icon standing in for nothing.
private struct AccountAvatarView: View {
    let user: User

    private var initial: String {
        let source = user.displayName?.trimmingCharacters(in: .whitespaces).first
            ?? user.email?.first
        guard let source else { return "?" }
        return String(source).uppercased()
    }

    var body: some View {
        Circle()
            .fill(AppColor.accent.opacity(0.2))
            .overlay(
                Text(initial)
                    .font(AppTypography.chatTitle)
                    .foregroundStyle(AppColor.accent)
            )
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}

#Preview {
    SettingsView()
        .environment(AuthState())
        .environment(AppState())
}
