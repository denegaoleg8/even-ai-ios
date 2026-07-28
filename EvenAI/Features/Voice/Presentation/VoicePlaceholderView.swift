import SwiftUI

/// Future module — see the Even AI architecture spec's `/session/voice`
/// endpoint. No audio capture or networking is implemented here yet.
struct VoicePlaceholderView: View {
    var body: some View {
        EmptyStateView(
            systemImage: "waveform",
            title: "Voice",
            subtitle: "Talk to Even AI hands-free. Coming in a future update."
        )
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { VoicePlaceholderView() }
}
