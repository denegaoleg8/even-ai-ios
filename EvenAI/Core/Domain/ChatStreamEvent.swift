import Foundation

/// Events emitted while an assistant reply streams in, mirroring the
/// `start` / `delta` / `done` shape of the Even AI API specification's SSE
/// format.
enum ChatStreamEvent: Sendable {
    case userMessageSaved(Message)
    case assistantDelta(String)
    case assistantMessageSaved(Message)
}
