import SwiftUI

/// Future module — glasses transport (Even Hub bridge vs. native BLE SDK)
/// is an open architectural decision; see the Even AI architecture spec.
/// No BLE code is implemented here yet.
struct GlassesPlaceholderView: View {
    var body: some View {
        EmptyStateView(
            systemImage: "eyeglasses",
            title: "Glasses",
            subtitle: "Pair with your Even G2 glasses. Coming in a future update."
        )
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { GlassesPlaceholderView() }
}
