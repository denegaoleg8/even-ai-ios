import Foundation

/// Base URL for the Even AI backend's chat API. Reads `EVEN_AI_API_BASE_URL`
/// from Info.plist (set in `project.yml`) so the deployed Railway URL can be
/// swapped in without a code change; falls back to the local dev server
/// (matches `even-ai-assistant-asr`'s default `PORT=3001`) for Simulator
/// testing against `npm run dev:server` / `node server.js`.
enum BackendConfiguration {
    static let baseURL: URL = {
        if let override = Bundle.main.object(forInfoDictionaryKey: "EVEN_AI_API_BASE_URL") as? String,
           !override.isEmpty,
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:3001/api")!
    }()
}
