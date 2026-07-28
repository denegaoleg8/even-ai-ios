# Even AI — Roadmap

Milestones are implemented and verified strictly one at a time. Each requires explicit approval before the next begins.

**Current version: `0.2.0`** — Milestone 2, frozen 2026-07-28. Tagged `v0.2.0` in both repos.

## ✅ Milestone 1 — Conversations Feature (Mock)
- SwiftUI skeleton: `App/Core/Infrastructure/Features` architecture, XcodeGen-managed project.
- Chat list: create, rename, delete, auto-title from first message.
- Chat screen: ChatGPT-style bubbles, timestamps, multiline input, typing indicator, smooth auto-scroll.
- SwiftData persistence (`ChatEntity`/`MessageEntity`), restored automatically after relaunch.
- `MockChatService` with simulated word-by-word streaming replies.

## ✅ Milestone 2 — Production Backend Integration (frozen)
- Backend: new additive `src/chat/` module on `even-ai-assistant-asr` — REST endpoints for conversations + SSE streaming endpoint, real OpenAI integration, JSON-file persistence. `/session` (ASR) verified byte-for-byte unchanged.
- iOS: `NetworkChatService` (REST + SSE, retry-with-backoff, actor-isolated) replaces `MockChatService` as the live implementation; `AppContainer` is the only file that changed to make the swap, per the original design intent.
- End-to-end verification pass: found and fixed a startup crash (env-var load order), an information-disclosure bug (raw stack trace on malformed JSON), a Swift 6 concurrency violation, a Sendable warning, and three distinct silent-failure paths in message sending.
- Full production readiness review (whole-codebase, not just the diff): found and fixed a second backend crash risk (SSE heartbeat writing after client disconnect), two iOS error-handling correctness bugs (a failed delete corrupting local state, a missing reentrancy guard on chat creation), a retry-idempotency gap (create was being retried), and two stale doc comments. Two further findings were reviewed and explicitly deferred as documented, non-blocking limitations (see below) rather than fixed, to avoid scope creep into new feature work.
- All fixes covered by automated tests where the underlying logic is unit-testable (view-model layer); confirmed via live curl-based end-to-end testing for everything backend-observable, including a deliberately-timed mid-generation client disconnect.
- **Final freeze pass**: full re-verification (all 10 end-to-end backend checks re-run live, including a repeat of the mid-stream-disconnect crash regression check) and a project-wide cleanup scan (TODO/FIXME comments, dead code, duplicate files, unused imports) — nothing further found to fix or remove; both repos build clean with zero warnings. Tagged `v0.2.0`.
- See `CHANGELOG.md` for the itemized list and `ARCHITECTURE.md` for the current implementation and engineering decisions in detail.

## 🚧 Milestone 3 — Authentication (in progress)

Full design approved 2026-07-28 — anonymous-by-default accounts (never a forced gate), claimed in place on sign-up (zero data migration), explicit merge-on-sign-in for a second device's local chats, ecosystem-wide from day one (platform-agnostic REST/JWT design, ready for Android/Web/Voice/Vision/Glasses without another auth rewrite). Implemented one small phase at a time, verified before each next phase begins.

- ✅ **Phase 3.1 — Backend: accounts, sessions, tokens (data model only, no endpoints yet)**. `src/auth/{db,store,tokens}.js`. Accounts (with subscription/settings/profile fields ready for future use), devices (platform-agnostic, one row per device per login), sessions (refresh tokens, hashed, revocable individually or all-at-once for "logout everywhere"). SQLite (`better-sqlite3`) chosen over the chat store's JSON-file pattern — see `ARCHITECTURE.md`. 17 new unit tests (Node's built-in test runner, zero new test-framework dependency), all passing. `/session` and existing chat endpoints re-verified live, unaffected; no new HTTP routes exposed yet.
- 🔜 Phase 3.2 — Backend: auth endpoints (`/api/auth/{device,signup,login,refresh,logout,merge}`)
- 🔜 Phase 3.3 — Backend: scope chat routes by account
- 🔜 Phase 3.4 — iOS: Core/Infrastructure auth foundation
- 🔜 Phase 3.5 — iOS: wire chat + app state to auth
- 🔜 Phase 3.6 — iOS: Auth UI
- 🔜 Phase 3.7 — Chat migration/merge UX
- 🔜 Phase 3.8 (optional) — Backend persistence hardening (unify chat storage onto SQLite too)
- 🔜 Phase 3.9 (optional) — SwiftData local cache (`CachingChatService` decorator)

Each phase requires explicit approval before the next begins.

## 🔜 Milestone 4 — Even G2 Integration (not started — awaiting approval)
- **`GlassesTransport` abstraction only** — no BLE implementation. Must be swappable later for an Even Hub bridge or `MentraBluetoothSDK` without touching Chat or backend code.
- Chat messages mirrored to glasses via this abstraction, once a concrete transport exists.

## 🔜 Milestone 5 — Voice (not started — awaiting approval)
- Microphone capture, streaming transcription, streaming assistant responses, built on the existing architecture (new `Features/Voice` implementation, `Core`/`Infrastructure` extended as needed — not restructured).

## 🔜 Milestone 6 — Vision (not started — awaiting approval)
- Image upload, multimodal prompts, backend integration.

## Known gaps carried forward (tracked, not blocking)

- No local offline cache for the production (`NetworkChatService`) path — the app is fully backend-dependent today. SwiftData persistence exists but is currently only exercised by `MockChatService`.
- No retry on a broken SSE stream, or on chat creation (both non-idempotent risks — see `ARCHITECTURE.md`); failures are surfaced as `.failed` messages instead.
- Backend persistence is a JSON file, not a database — fine for current scale; also has no per-chat write locking (unreachable today, see `ARCHITECTURE.md`'s production-readiness-review section), worth revisiting together before real multi-user/multi-device load.
- No tap-to-retry on a failed message, and auto-scroll doesn't pause when the user has manually scrolled away from the bottom during streaming — both minor UX gaps, not correctness bugs.
- No AppIcon artwork yet.
- **Live Simulator verification has not been possible in this development environment** across two separate review sessions (confirmed environmental — a fresh device shows the same instability). All fixes in both milestones are verified via clean builds under Swift 6 strict concurrency, live backend testing via curl (including real OpenAI streaming and a deliberately mid-stream client disconnect), and automated unit tests where the logic is testable outside the Simulator. A real on-device/Simulator run — visual streaming smoothness, actual memory profiling via Instruments, UI responsiveness under load — is still outstanding and should be the first thing done on a working Simulator setup before Milestone 3.
