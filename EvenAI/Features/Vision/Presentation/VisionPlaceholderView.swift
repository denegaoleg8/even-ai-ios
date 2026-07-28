import SwiftUI

/// Future module — see the Even AI architecture spec's proposed
/// `/api/vision` endpoint. No camera capture or networking is implemented
/// here yet.
struct VisionPlaceholderView: View {
    var body: some View {
        EmptyStateView(
            systemImage: "eye",
            title: "Vision",
            subtitle: "Ask Even AI about what's in front of you. Coming in a future update."
        )
        .navigationTitle("Vision")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { VisionPlaceholderView() }
}
