# Changelog

All notable changes to the Even AI product (both `even-ai-ios` and the chat portion of `even-ai-assistant-asr`) are recorded here, grouped by milestone.

## [0.2.0] — Milestone 2 — Production Backend Integration — 2026-07-28 (frozen)

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

### Production readiness review — 2026-07-28

A full senior-engineering pass over the entire codebase (not just the Milestone 2 diff), covering architecture consistency, thread safety, retry/error-handling correctness, SwiftData usage, memory management, and security. Six real issues found and fixed:

**Backend**
- **Crash risk**: the SSE stream's 15-second heartbeat kept writing to the response after the client disconnected (only a flag was set on close; the interval itself wasn't cleared until the whole request finished, which could be much later if OpenAI was still generating). Writing to a closed Node response can emit an unhandled `error` event and crash the process. Fixed: every write now checks a `clientClosed` guard, the heartbeat is cleared immediately on `close`, and an `error` listener on the response is a second line of defense. Verified against a real disconnect timed to land mid-generation — server survived with zero errors logged.
- Removed an unused exported constant (`defaultTitle`) left over from `store.js` — dead code, nothing imported it.

**iOS**
- `ChatListViewModel.deleteChat` removed the chat from local state even when the backend delete call failed (`try?` swallowed the error unconditionally). The chat would then reappear on the next reload, looking like a bug to the user. Fixed to only remove locally on confirmed success.
- `ChatListViewModel.createChat` had no reentrancy guard — a rapid double-tap on "New Chat" could dispatch two overlapping calls, both succeeding, creating two chats from one tap. Fixed with the same `isCreating`-style guard pattern already used by `ChatViewModel.sendDraft`. Covered by a new concurrency test using a call-counting test double.
- `NetworkChatService` retried `POST /api/chats` (create) using the same retry-with-backoff as safely-idempotent calls (GET/PATCH/DELETE). Creating a chat is *not* idempotent — retrying risks a duplicate chat if the first attempt reached the server but the client timed out before seeing the response. Fixed: create is no longer retried; GET/PATCH/DELETE still are.
- Two stale doc comments (`ChatServicing.swift`, `MockChatService.swift`) still described `NetworkChatService` as a future, not-yet-built thing. Updated to reflect current reality.
- Added `DeleteFailingChatService` and `CountingCreateChatService` test doubles, plus tests for both fixes above.

**Explicitly reviewed and left as-is** (documented, not bugs):
- The backend's in-memory store has no per-chat locking — two truly concurrent writes to the *same* chat could theoretically interleave. Not reachable through the current app (a single iOS client, UI-guarded to one in-flight send per chat), and a real fix belongs with the eventual database migration rather than a hand-rolled lock over a `Map`. See `ARCHITECTURE.md`.
- Title-derivation logic (first-message → chat title) is implemented twice, once in Swift (`MockChatService`) and once in JS (`store.js`/`routes.js`), because there's no way to share it across runtimes without disproportionate tooling. Kept in sync by inspection; noted for future maintainers.
- Auto-scroll-to-bottom fires on every streamed token regardless of whether the user has manually scrolled up to read earlier messages — a UX nicety (matching how most chat apps suppress it once the user scrolls away), not a correctness bug; not implemented here to avoid scope creep into new feature work during a review pass.

### Final freeze verification — 2026-07-28

Re-ran the full end-to-end backend checklist live (session/ASR, create, send+stream, history restore, list/auto-title, rename, 404, malformed-JSON 400, the mid-stream-disconnect crash regression check, delete) — all pass, zero errors logged. Ran a project-wide cleanup scan across both repos (TODO/FIXME comments, dead code, unused imports, duplicate files) — nothing further found. Both repos rebuild clean with zero warnings. Bumped `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml` to `0.2.0`/`2`. Tagged `v0.2.0` in both repos.

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
