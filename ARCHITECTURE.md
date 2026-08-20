# Even AI — Architecture

This document reflects the implementation as of **Milestone 2 (Production Backend Integration), frozen at version `0.2.0`**. Two repositories make up the product:

| Repo | Role |
|---|---|
| `even-ai-ios` | Native SwiftUI iOS app (this repo) |
| `even-ai-assistant-asr` | Node/Express backend on Railway — pre-existing ASR (`/session`) plus the new chat module (`/api/*`) |

## Guiding principle: the Dependency Rule

```
App  →  can see Core, Infrastructure, Features (composition root)
Features  →  Core, Infrastructure (via DI only, never a concrete Infrastructure type directly)
Infrastructure  →  Core
Core  →  nothing
```

`Core` is the shared kernel every layer may depend on; it must never depend outward. This is why, for example, `AppContainer` (the composition root, which knows about concrete `NetworkChatService`/`MockChatService`) lives in `App/DI`, not `Core/DI` — `Core` importing a concrete Infrastructure type would invert the rule.

## iOS folder structure

```
EvenAI/
├── App/                    Entry point, root navigation, app-wide state, DI composition root
│   ├── EvenAIApp.swift
│   ├── RootView.swift          NavigationSplitView(sidebar: ChatListView, detail: ChatView)
│   ├── AppState.swift           selectedChatID, isSettingsPresented
│   └── DI/AppContainer.swift    static .live — the one place that picks the concrete ChatServicing
├── Core/
│   ├── Domain/               Chat, Message, MessageRole, MessageStatus, ChatStreamEvent, ChatServicing (protocol);
│   │                          GlassesTransport, GlassesTransportState, GlassesTransportError (protocol) — see "Glasses transport" below
│   ├── DesignSystem/         PrimaryButton, EmptyStateView, LoadingView, SectionHeader, TypingIndicatorView
│   └── Theme/                 AppColor, AppTypography, AppMetrics
├── Infrastructure/
│   ├── Chat/
│   │   ├── MockChatService.swift       SwiftData-backed, canned/simulated streaming replies — used by tests & previews
│   │   ├── NetworkChatService.swift    Real backend client — REST + SSE — this is what the running app uses
│   │   ├── ChatAPIDTOs.swift           Wire-format DTOs + ISO8601 date coding, separate from domain structs
│   │   └── BackendConfiguration.swift  Base URL (Info.plist override → localhost fallback)
│   ├── Persistence/           PersistenceController, ChatEntity, MessageEntity (SwiftData)
│   ├── Security/               DeviceIdentityStore (Keychain-backed UUID; not yet wired to auth — see Roadmap)
│   └── Glasses/
│       ├── MentraGlassesTransport.swift   GlassesTransport implementation — the only file that imports MentraBluetoothSDK
│       └── MockGlassesTransport.swift     In-memory stand-in for tests/previews, mirrors MockChatService/MockAuthService
└── Features/
    ├── Conversations/Presentation/{List,Detail,Components}    Chat list + chat screen + their view-specific components
    ├── Settings/Presentation/
    ├── Voice/Presentation/         Placeholder only
    ├── Vision/Presentation/        Placeholder only
    └── Glasses/Presentation/       GlassesView + GlassesViewModel — Connect/Disconnect + Send Test Text,
                                     verified end-to-end against physical Even G2 hardware (Milestone 4, phase 1);
                                     no Chat integration yet
```

Project is generated via **XcodeGen** (`project.yml` is the source of truth; `xcodegen generate` produces `EvenAI.xcodeproj`, which is not checked in).

## Backend structure (`even-ai-assistant-asr`)

```
server.js                Entry point. Untouched ASR route (/session) + two additive lines mounting the chat router.
src/
├── asr/, audio/, debug/, main.ts, ui.ts     Pre-existing G2 WebView ASR app — not touched by any chat work
├── chat/
│   ├── store.js          Dependency-free persistence: in-memory Map + write-through JSON file (data/chats.json)
│   └── routes.js         Express router: REST (/api/chats*) + SSE streaming (/api/chat/stream)
└── auth/  (Milestone 3, in progress)
    ├── db.js             SQLite connection + schema (accounts, devices, sessions) — see decision note below
    ├── store.js          Account/device/session data access
    └── tokens.js         JWT access tokens, opaque refresh tokens, password hashing
```

`/session`, the chat module, and the auth module share the same Express process and port but nothing in code — verified repeatedly during Milestone 2 (and again as each Milestone 3 phase lands) that ASR behavior is byte-for-byte unchanged.

**Why auth uses SQLite (`better-sqlite3`) instead of `src/chat/store.js`'s JSON-file pattern**: accounts/devices/sessions are genuinely relational (foreign keys, one-to-many), and this data is security-sensitive (password hashes, token hashes) in a way chat text isn't. A hand-rolled JSON `Map` store doesn't give real constraints, atomic multi-table writes, or the write-locking `better-sqlite3` provides — and unlike the chat store's decision (revisit later, optional Phase 3.8), auth's correctness bar justifies making that choice from its first line of code. `better-sqlite3` ships prebuilt binaries for all common platforms (including this environment's darwin-arm64) and required no source compilation once its install script was approved through npm 11's script-approval gate (`npm approve-scripts better-sqlite3` — a legitimate supply-chain security feature, not bypassed). Chat storage and auth storage are two separate SQLite/JSON files with no shared code; unifying them is still the optional, deferred Phase 3.8.

`src/auth/db.js`'s connection is a lazy singleton (`getDb()`), reading `AUTH_DB_PATH` only on first actual use rather than at module-import time — the same fix already applied to `src/chat/routes.js`'s OpenAI client after that exact bug was found in the Milestone 2 review (ES module imports fully evaluate before the importing file's own top-level code runs, so reading an env var at import time can see it still unset).

## Data flow: sending a message (production path)

1. `ChatView` → `ChatViewModel.sendDraft()` → `NetworkChatService.streamReply(chatID:content:)`.
2. `NetworkChatService` opens `POST /api/chat/stream` via `URLSession.bytes(for:)`, hand-parses the response as SSE (`event:`/`data:` lines, blank-line-delimited, `:`-prefixed heartbeat comments ignored).
3. Backend (`src/chat/routes.js`) persists the user message to `store.js`, derives an auto-title if this is the chat's first message, then calls OpenAI's `chat.completions.create({ stream: true })` and forwards each token as an SSE `delta` event, finishing with a `done` event containing the persisted assistant message.
4. `NetworkChatService` decodes each SSE payload into a `ChatStreamEvent` (`.userMessageSaved` / `.assistantDelta` / `.assistantMessageSaved`) and yields it through an `AsyncThrowingStream`.
5. `ChatViewModel` consumes the stream, appending/growing a `.streaming`-status placeholder message as deltas arrive, replacing it with the final message on completion — or marking it `.failed` (see below) if the stream breaks.

## Glasses transport (Milestone 4, phase 1)

`GlassesTransport` (`Core/Domain/GlassesTransport.swift`) is the vendor-neutral abstraction over the glasses BLE link — `connectionStateUpdates()`, `connect()`, `disconnect()`, `sendText(_:)` — mirroring `ChatServicing`'s role for chat. Same Dependency Rule as everywhere else: `Core/Domain/{GlassesTransport,GlassesTransportState,GlassesTransportError}.swift` have zero knowledge of any vendor SDK.

`MentraGlassesTransport` (`Infrastructure/Glasses/`) is the concrete implementation, talking to Even Realities G2 glasses via the third-party `MentraBluetoothSDK` (Mentra-Community, pinned to `0.1.21-beta.5` in `project.yml`'s `packages:`). **`MentraBluetoothSDK` is imported by exactly one file in this codebase** — `MentraGlassesTransport.swift` — the same isolation principle already applied to `ChatAPIDTOs`/wire formats: nothing above this file, including `GlassesTransport` itself, ever sees a MentraBluetoothSDK type. This is what keeps the transport swappable later (a different SDK, a future Even Hub bridge, direct CoreBluetooth) without touching `Features/Glasses`, Chat, or the backend — the explicit requirement behind choosing this SDK in the first place (see `ROADMAP.md` Milestone 4).

`MockGlassesTransport` (`Infrastructure/Glasses/`) is the in-memory stand-in for tests/previews, mirroring `MockChatService`/`MockAuthService`'s role. DI follows the pattern already established for `chatService`: `AppContainer.live.glassesTransport`, threaded through `EnvironmentValues.glassesTransport` (default `MockGlassesTransport()`), overridden with the real instance in `EvenAIApp`.

**Glasses currently operates entirely independently of Chat, Voice, and Vision.** `GlassesView`/`GlassesViewModel` (`Features/Glasses/Presentation/`) depend only on `GlassesTransport`; nothing in `Features/Conversations`, `Infrastructure/Chat`, or `Infrastructure/Networking` references `GlassesTransport`, and nothing in `Features/Glasses` references `ChatServicing`. Chat messages are not sent to the glasses — that integration is deliberately not yet built (see `ROADMAP.md`).

**Bluetooth permission and connection behavior.** `MentraBluetoothSDK` is constructed lazily inside `MentraGlassesTransport` — merely opening the Glasses screen does not construct it and does not trigger iOS's Bluetooth permission prompt; only pressing Connect does, since `MentraBluetoothSDK.init()` is what first touches `CBCentralManager`. `NSBluetoothAlwaysUsageDescription` is declared via `project.yml`'s Info.plist properties. Once Connect is pressed, `connect()` waits for CoreBluetooth's central-manager state to genuinely settle (`.poweredOn`) before calling `startScan` — via `BluetoothReadinessWatcher`, a small helper using Apple's own `CoreBluetooth` API directly (a second, independent `CBCentralManager`, since MentraBluetoothSDK exposes no public way to observe this internally) that waits for the real `centralManagerDidUpdateState` event rather than guessing an interval, bounded by a 10-second timeout as a safety net. A real `.unauthorized`/`.poweredOff`/`.unsupported` condition surfaces immediately instead of being retried. No background Bluetooth mode is declared — the app does not maintain a glasses connection while backgrounded.

## Key engineering decisions

- **DTOs are separate from domain structs.** `ChatDTO`/`MessageDTO` (Infrastructure) map to/from `Chat`/`Message` (Core.Domain) rather than making the domain structs `Codable` against the wire format directly — the backend's `chatId` JSON key doesn't match the domain's `chatID` property, and this keeps JSON-key concerns out of Core entirely. The same separation exists for SwiftData (`ChatEntity`/`MessageEntity` → `.toDomain()`).
- **`MockChatService` is an `actor`; the backend it talks to (SwiftData) is accessed via a fresh `ModelContext(container)` per call** rather than a stored context, so the actor itself stays trivially `Sendable` without needing the `@ModelActor` macro.
- **`NetworkChatService` retries idempotent REST calls (GET/PATCH/DELETE, 2 attempts, backoff) but not `POST /api/chats` (create) or an in-flight/partially-consumed SSE stream.** Create isn't idempotent — retrying it risks a duplicate chat if the first attempt reached the server but the client timed out before seeing the response (found and fixed in the Milestone 2 production readiness review). A broken stream is surfaced to the user as a `.failed` message (see below) rather than retried, for the same reason.
- **Load failures are tracked separately from empty results** (`loadFailed: Bool` on both view models). `try?`-swallowing errors made "backend unreachable" indistinguishable from "you have no chats yet" / "this is a new conversation" — found and fixed during Milestone 2 verification.
- **Every stream-send failure mode ends in a visible `.failed`-status message, never a silent drop:** never-connected preserves the typed text as a failed local message; a mid-stream drop marks the partial reply failed instead of leaving it looking like a complete answer; a connected-but-empty-reply case is also surfaced. Covered by `ChatViewModelTests`.
- **Backend persistence is a dependency-free JSON file (`data/chats.json`), not a database**, matching the existing repo's minimal, framework-free style and requiring no new npm dependency or Railway addon. Documented as an intentional MVP choice, swappable later.
- **`NSAllowsLocalNetworking` ATS exception** (not a blanket ATS disable) lets the Simulator reach `http://localhost:3001` during development without weakening transport security for any real remote domain.
- **iOS-side SwiftData (`ChatEntity`/`MessageEntity`) is currently only exercised by `MockChatService`**, not by `NetworkChatService`. The running app has no local offline cache — it is fully dependent on the backend being reachable. This was an explicit scope decision for Milestone 2 (adding a network+cache merge layer was treated as a separate concern from "replace the mock with a real network client"), not an oversight — flagged here so it's a visible, revisitable decision rather than a silent gap.

## Production readiness review findings (2026-07-28)

A full read-through of every file in both repos (not just the Milestone 2 diff), against: architecture consistency, duplication, thread safety, actor isolation, SwiftData correctness, memory management, DI, error handling, retry logic, the SSE implementation, security, race conditions. Six real issues were found and fixed (see `CHANGELOG.md` for the itemized list — a backend crash risk in the SSE heartbeat, two iOS error-handling correctness bugs, an idempotency gap in retry logic, and two stale doc comments).

Two things were found, considered, and deliberately **not** changed:

- **Backend store has no per-chat locking.** `store.js`'s functions are `async` but do all their actual Map mutation synchronously between `await` points; two genuinely concurrent writes to the *same* chat could theoretically interleave (e.g. `appendMessage`'s `list.push` / `messagesByChat.set` sequence isn't atomic across the `await load()` yield point). This is unreachable through the app today — one iOS client, and `ChatViewModel.sendDraft()` is guarded so only one send can be in flight per chat at a time — but would become reachable with multi-device sync (Milestone 3+). The right fix is a real database's transactional guarantees when `data/chats.json` is eventually replaced, not a hand-rolled lock over a `Map`.
- **Auto-scroll-to-bottom doesn't respect manual scroll position.** `ChatView` scrolls to bottom on every token during streaming, even if the user has scrolled up to read earlier messages. This is a UX nicety most chat apps implement (suppress auto-scroll once the user scrolls away, resume once they scroll back to bottom) but is not a correctness bug, and implementing it would be new feature work, out of scope for a review pass.

## What is *not* yet implemented

- Authentication (device identity exists in `Infrastructure/Security/DeviceIdentityStore` but isn't wired to any backend auth flow yet).
- Chat → Glasses mirroring: chat messages are not sent to the glasses. The transport (`GlassesTransport`/`MentraGlassesTransport`) and a working Connect/Disconnect + "Send Test Text" screen exist and are verified against physical Even G2 hardware — see "Glasses transport" above and `ROADMAP.md` Milestone 4.
- Voice and Vision modules (placeholder screens only).
- An offline/local cache for the production (network) chat path.

See `ROADMAP.md` for what's planned next and in what order.
