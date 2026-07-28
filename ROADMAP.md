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

## 🔜 Milestone 3 — Authentication (not started — awaiting approval)
- Device identity (already scaffolded in `Infrastructure/Security/DeviceIdentityStore`, not yet wired up).
- Backend device-auth endpoint issuing a bearer token.
- Session restoration on relaunch.
- Settings screen: account section.

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
