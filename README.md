# Even AI (iOS)

Native SwiftUI companion app skeleton for Even AI. This is architecture only —
no networking, no LLM calls, and no BLE/glasses integration are implemented
yet. See the Even AI API specification (backend repo) for the contract this
app will eventually consume.

## Requirements

- Xcode 16+ (iOS 18 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Generate and open the project

```
xcodegen generate
open EvenAI.xcodeproj
```

`EvenAI.xcodeproj` is not checked into git — `project.yml` is the source of
truth; regenerate after pulling changes that touch target/scheme
configuration.

## What's here

| Folder | Purpose |
|---|---|
| `EvenAI/App` | App entry point, root navigation, app-wide state |
| `EvenAI/Core/DI` | Composition root wiring services together |
| `EvenAI/Models` | Domain models shared across the app (`Sendable` value types) |
| `EvenAI/Services` | Protocols for backend-facing operations, plus in-memory mock implementations |
| `EvenAI/Storage` | SwiftData persistence layer and device identity (Keychain) |
| `EvenAI/Theme` | Design tokens — color, typography, spacing |
| `EvenAI/DesignSystem` | Reusable SwiftUI components built on the theme tokens |
| `EvenAI/Features` | One folder per screen/feature, each with its own Views + ViewModels |

## Known gaps (by design, for this phase)

- `MockChatService` returns static in-memory data — no real persistence or
  network calls are wired up.
- `AppIcon` has no image asset yet — add a 1024×1024 icon before submission.
- Voice, Vision, and Glasses are placeholder screens only.
