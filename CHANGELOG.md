# Changelog

All notable changes to the Even AI product (both `even-ai-ios` and the chat portion of `even-ai-assistant-asr`) are recorded here, grouped by milestone.

## Milestone 2 — Production Backend Integration — 2026-07-28

### Backend (`even-ai-assistant-asr`)

**Added**
- `src/chat/store.js` — dependency-free chat persistence (in-memory `Map` + write-through JSON file at `data/chats.json`).
- `src/chat/routes.js` — `GET/POST /api/chats`, `GET/PATCH/DELETE /api/chats/:id`, `GET /api/chats/:id/messages`, `POST /api/chat/stream` (SSE: `start`/`delta`/`done`/`error`, 15s heartbeat).
- `OPENAI_CHAT_MODEL`, `CHAT_DATA_DIR` environment variables (both optional, documented in `.env.example`).

**Changed**
- `server.js` — two additive lines: `app.use(express.json())` and `app.use("/api", chatRouter)`. `/session` is unmodified.

**Fixed**
- Startup crash: the chat module's OpenAI client was constructed at module-import time, which runs before `server.js`'s `dotenv.config()` call — `OPENAI_API_KEY` was read while still unset. Fixed with lazy client construction on first request.
- Information disclosure: a malformed JSON request body fell through to Express's default HTML error page, including a full stack trace with local file paths. Added a scoped error-handling middleware returning the same JSON error envelope used everywhere else; verified it cannot affect `/session`, which never reads `req.body`.

### iOS (`even-ai-ios`)

**Added**
- `Infrastructure/Chat/NetworkChatService.swift` — `ChatServicing` implementation backed by the real API (REST via `URLSession.data(for:)` with 2-attempt retry/backoff, streaming via `URLSession.bytes(for:)` hand-parsed as SSE).
- `Infrastructure/Chat/ChatAPIDTOs.swift` — wire DTOs and ISO8601 (fractional-seconds-aware) date coding.
- `Infrastructure/Chat/BackendConfiguration.swift` — base URL from Info.plist, defaulting to `http://localhost:3001/api`.
- `EvenAITests/TestDoubles/FakeChatServices.swift`, `ChatListViewModelTests.swift`, `ChatViewModelTests.swift` — automated coverage of every failure path described below.

**Changed**
- `App/DI/AppContainer.swift` — `.live` now constructs `NetworkChatService()` instead of `MockChatService()`. `MockChatService` is unchanged and still backs `EvenAITests`/previews.
- `project.yml` — added `NSAllowsLocalNetworking` (ATS exception scoped to local networking only) and the `EVEN_AI_API_BASE_URL` Info.plist key.

**Fixed** (all found during Milestone 2 end-to-end verification)
- Swift 6 strict concurrency error: a mutable `var request` was captured inside a `@Sendable` retry closure. Fixed by binding to a `let` before capture.
- Sendable warning: `ISO8601DateFormatter` (not `Sendable`) was captured inside a `@Sendable` JSON date-decoding closure. Fixed by constructing formatters fresh inside the closure instead of capturing shared instances.
- `ChatListViewModel`/`ChatViewModel` used `try?` to swallow load errors, making "backend unreachable" indistinguishable from "genuinely no chats yet" / "new, empty conversation" — both rendered the same empty state. Added a `loadFailed` flag to each, surfaced via the existing `EmptyStateView` component with a distinct message and a Retry action.
- Three silent message-send failure modes, none previously surfaced to the user:
  - Connection never established: the user's typed message was cleared from the input field and then discarded entirely with no trace. Now preserved as a locally-visible `.failed`-status message.
  - Mid-stream drop: a partial reply was left with `status: .streaming` forever, rendering as an apparently complete (if short) answer. Now marked `.failed`.
  - Connected but no reply arrived: previously invisible. Now surfaced as a `.failed` assistant message ("No response received").
- `MessageBubbleView` — failed-message label text now differs by role/case ("Couldn't send" / "Response incomplete" / "No response received") instead of a single generic "Failed to send," and no longer renders an empty content line for an empty failed assistant message.

## Milestone 1 — Conversations Feature (Mock) — 2026-07-28

**Added**
- SwiftUI project skeleton (`App/Core/Infrastructure/Features`, XcodeGen-managed).
- Chat list: create, rename, delete, auto-title derived from the first message.
- Chat screen: message bubbles (user right / assistant left), timestamps, multiline input with Send button, animated typing indicator, `ScrollViewReader`-driven auto-scroll.
- SwiftData persistence (`ChatEntity`, `MessageEntity`, `PersistenceController`) — conversations and messages restored automatically after relaunch.
- `MockChatService` — SwiftData-backed, simulates word-by-word streaming assistant replies.

**Fixed**
- `RootView` was missing `.id(chatID)` on `ChatView`, which would have made SwiftUI reuse the same `ChatViewModel` (pinned to the first-opened chat) when switching conversations in the sidebar.
- `project.yml`: `DEVELOPMENT_ASSET_PATHS` path containing a space (`Preview Content`) was being split into two invalid paths by Xcode's build-setting parser; renamed the folder instead of escaping it.
- `EvenAIApp.swift` was missing `import SwiftData`, needed for the `.modelContainer(_:)` scene modifier (an extension declared in SwiftData, not visible via `import SwiftUI` alone).
- Test targets (`EvenAITests`, `EvenAIUITests`) were missing `GENERATE_INFOPLIST_FILE: YES`, required for code signing during `xcodebuild test`.
- App target's custom `PRODUCT_NAME: "Even AI"` (with a space) broke the auto-computed `TEST_HOST` path for `EvenAITests`; removed (display name is already handled separately via `INFOPLIST_KEY_CFBundleDisplayName`).
