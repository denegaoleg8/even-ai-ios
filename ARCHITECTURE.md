# Even AI — Architecture

This document reflects the implementation as of **Milestone 2 (Production Backend Integration)**. Two repositories make up the product:

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
│   ├── Domain/               Chat, Message, MessageRole, MessageStatus, ChatStreamEvent, ChatServicing (protocol)
│   ├── DesignSystem/         PrimaryButton, EmptyStateView, LoadingView, SectionHeader, TypingIndicatorView
│   └── Theme/                 AppColor, AppTypography, AppMetrics
├── Infrastructure/
│   ├── Chat/
│   │   ├── MockChatService.swift       SwiftData-backed, canned/simulated streaming replies — used by tests & previews
│   │   ├── NetworkChatService.swift    Real backend client — REST + SSE — this is what the running app uses
│   │   ├── ChatAPIDTOs.swift           Wire-format DTOs + ISO8601 date coding, separate from domain structs
│   │   └── BackendConfiguration.swift  Base URL (Info.plist override → localhost fallback)
│   ├── Persistence/           PersistenceController, ChatEntity, MessageEntity (SwiftData)
│   └── Security/              DeviceIdentityStore (Keychain-backed UUID; not yet wired to auth — see Roadmap)
└── Features/
    ├── Conversations/Presentation/{List,Detail,Components}    Chat list + chat screen + their view-specific components
    ├── Settings/Presentation/
    ├── Voice/Presentation/         Placeholder only
    ├── Vision/Presentation/        Placeholder only
    └── Glasses/Presentation/       Placeholder only
```

Project is generated via **XcodeGen** (`project.yml` is the source of truth; `xcodegen generate` produces `EvenAI.xcodeproj`, which is not checked in).

## Backend structure (`even-ai-assistant-asr`)

```
server.js                Entry point. Untouched ASR route (/session) + two additive lines mounting the chat router.
src/
├── asr/, audio/, debug/, main.ts, ui.ts     Pre-existing G2 WebView ASR app — not touched by any chat work
└── chat/
    ├── store.js          Dependency-free persistence: in-memory Map + write-through JSON file (data/chats.json)
    └── routes.js         Express router: REST (/api/chats*) + SSE streaming (/api/chat/stream)
```

`/session` and the chat module share the same Express process and port but nothing in code — verified repeatedly during Milestone 2 that ASR behavior is byte-for-byte unchanged.

## Data flow: sending a message (production path)

1. `ChatView` → `ChatViewModel.sendDraft()` → `NetworkChatService.streamReply(chatID:content:)`.
2. `NetworkChatService` opens `POST /api/chat/stream` via `URLSession.bytes(for:)`, hand-parses the response as SSE (`event:`/`data:` lines, blank-line-delimited, `:`-prefixed heartbeat comments ignored).
3. Backend (`src/chat/routes.js`) persists the user message to `store.js`, derives an auto-title if this is the chat's first message, then calls OpenAI's `chat.completions.create({ stream: true })` and forwards each token as an SSE `delta` event, finishing with a `done` event containing the persisted assistant message.
4. `NetworkChatService` decodes each SSE payload into a `ChatStreamEvent` (`.userMessageSaved` / `.assistantDelta` / `.assistantMessageSaved`) and yields it through an `AsyncThrowingStream`.
5. `ChatViewModel` consumes the stream, appending/growing a `.streaming`-status placeholder message as deltas arrive, replacing it with the final message on completion — or marking it `.failed` (see below) if the stream breaks.

## Key engineering decisions

- **DTOs are separate from domain structs.** `ChatDTO`/`MessageDTO` (Infrastructure) map to/from `Chat`/`Message` (Core.Domain) rather than making the domain structs `Codable` against the wire format directly — the backend's `chatId` JSON key doesn't match the domain's `chatID` property, and this keeps JSON-key concerns out of Core entirely. The same separation exists for SwiftData (`ChatEntity`/`MessageEntity` → `.toDomain()`).
- **`MockChatService` is an `actor`; the backend it talks to (SwiftData) is accessed via a fresh `ModelContext(container)` per call** rather than a stored context, so the actor itself stays trivially `Sendable` without needing the `@ModelActor` macro.
- **`NetworkChatService` retries REST calls (2 attempts, backoff) but never retries an in-flight or partially-consumed SSE stream.** Retrying a stream risks duplicate sends/replies with no idempotency key in place yet; a broken stream is instead surfaced to the user as a `.failed` message (see below), not silently retried.
- **Load failures are tracked separately from empty results** (`loadFailed: Bool` on both view models). `try?`-swallowing errors made "backend unreachable" indistinguishable from "you have no chats yet" / "this is a new conversation" — found and fixed during Milestone 2 verification.
- **Every stream-send failure mode ends in a visible `.failed`-status message, never a silent drop:** never-connected preserves the typed text as a failed local message; a mid-stream drop marks the partial reply failed instead of leaving it looking like a complete answer; a connected-but-empty-reply case is also surfaced. Covered by `ChatViewModelTests`.
- **Backend persistence is a dependency-free JSON file (`data/chats.json`), not a database**, matching the existing repo's minimal, framework-free style and requiring no new npm dependency or Railway addon. Documented as an intentional MVP choice, swappable later.
- **`NSAllowsLocalNetworking` ATS exception** (not a blanket ATS disable) lets the Simulator reach `http://localhost:3001` during development without weakening transport security for any real remote domain.
- **iOS-side SwiftData (`ChatEntity`/`MessageEntity`) is currently only exercised by `MockChatService`**, not by `NetworkChatService`. The running app has no local offline cache — it is fully dependent on the backend being reachable. This was an explicit scope decision for Milestone 2 (adding a network+cache merge layer was treated as a separate concern from "replace the mock with a real network client"), not an oversight — flagged here so it's a visible, revisitable decision rather than a silent gap.

## What is *not* yet implemented

- Authentication (device identity exists in `Infrastructure/Security/DeviceIdentityStore` but isn't wired to any backend auth flow yet).
- Any glasses/BLE transport (`Features/Glasses` is a placeholder screen only).
- Voice and Vision modules (placeholder screens only).
- An offline/local cache for the production (network) chat path.

See `ROADMAP.md` for what's planned next and in what order.
