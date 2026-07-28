# Even AI — Roadmap

Milestones are implemented and verified strictly one at a time. Each requires explicit approval before the next begins.

## ✅ Milestone 1 — Conversations Feature (Mock)
- SwiftUI skeleton: `App/Core/Infrastructure/Features` architecture, XcodeGen-managed project.
- Chat list: create, rename, delete, auto-title from first message.
- Chat screen: ChatGPT-style bubbles, timestamps, multiline input, typing indicator, smooth auto-scroll.
- SwiftData persistence (`ChatEntity`/`MessageEntity`), restored automatically after relaunch.
- `MockChatService` with simulated word-by-word streaming replies.

## ✅ Milestone 2 — Production Backend Integration
- Backend: new additive `src/chat/` module on `even-ai-assistant-asr` — REST endpoints for conversations + SSE streaming endpoint, real OpenAI integration, JSON-file persistence. `/session` (ASR) verified byte-for-byte unchanged.
- iOS: `NetworkChatService` (REST + SSE, retry-with-backoff, actor-isolated) replaces `MockChatService` as the live implementation; `AppContainer` is the only file that changed to make the swap, per the original design intent.
- Verification pass: found and fixed a startup crash (env-var load order), an information-disclosure bug (raw stack trace on malformed JSON), a Swift 6 concurrency violation, a Sendable warning, and three distinct silent-failure paths in message sending — all confirmed fixed, with automated regression tests for the view-model-level failure paths.
- See `CHANGELOG.md` for the full list and `ARCHITECTURE.md` for the current implementation in detail.

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
- No retry on a broken SSE stream (by design, for now — see `ARCHITECTURE.md`'s idempotency note); failures are surfaced as `.failed` messages instead.
- Backend persistence is a JSON file, not a database — fine for current scale, worth revisiting before real multi-user load.
- No AppIcon artwork yet.
