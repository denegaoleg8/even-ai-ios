# Phase 3 — Personal AI → G2 Integration · Plan

Baseline for the plan: `HEAD == origin/main == 9ba4d99`
(`Complete Phase 2 local backup recovery hardening`).

> **STATUS — 2026-09-02: IMPLEMENTED (Option C).** All 5 slices are complete
> and verified locally (uncommitted). See
> [Implementation record](#implementation-record) at the end, and the full
> report in `PHASE3_PERSONAL_AI_G2_IMPLEMENTATION.md`. `LOCAL READY` — physical
> G2 testing (§14) is still pending.

---

## 1. GOAL

Use the **local** Personal AI memory/context to improve the **suggested
replies** shown for G2 conversations — without putting Personal AI, CloudKit,
R2, or any network on the critical translation / listening path.

```
speech
  → transcription
  → translation displayed immediately              (unchanged, higher priority)
  → suggested-reply generation runs (as today)      (unchanged pipeline slot)
      · optionally enriched by local Personal AI context
      · enriched replies shown only if still relevant to the current turn
  → G2 renders only the final reply strings          (unchanged)
```

Personal AI is an **optional advisory context source**. It is never a hard
dependency and its failure is indistinguishable, to the user, from "no
personalisation was available this turn".

---

## 2. CURRENT ARCHITECTURE — EXACT CALL FLOW (from source)

### 2.1 The suggested-reply pipeline slot

```
AIConversationEngine.processTurn(...)                              [App/AIConversationEngine.swift]
  │  translation task  ──►  translateWithTimeout  ──►  G2 display   (independent, first)
  │
  └─ Task: generateSuggestedReplies(for: turn, sequence:, turnStartTime:)
        │  context = SuggestedReplyContext(
        │      recentTurns: agentContextStore.session.turns.filter{≠turnID}.suffix(6),
        │      contextItems: agentContextStore.session.contextItems)
        │
        ├─ generateRepliesWithTimeout(for: turn, context:)
        │     withThrowingTaskGroup:
        │        task A: replyGenerator.generateReplies(for: turn, context:)   ← INJECTION POINT
        │        task B: Task.sleep(repliesTimeout = .seconds(15)); throw RepliesTimeoutError
        │        → first to finish wins; defer group.cancelAll()
        │
        ├─ catch CancellationError | RepliesTimeoutError | LocalReplyUnavailableError | (any)
        │     → DiagnosticTrace + `return`   (no replies this turn — NEVER a session error)
        │
        ├─ guard !Task.isCancelled                                 → return
        ├─ updatedTurn.suggestedReplies = Array(replies.prefix(3)) (cap enforced HERE, one chokepoint)
        ├─ agentContextStore.updateTurn(updatedTurn)               (history — always, even if not shown)
        ├─ guard sequence >= highestDisplayedTurnSequence          → return  (STALE-DISPLAY GATE)
        ├─ guard !updatedTurn.suggestedReplies.isEmpty             → return
        ├─ glassesChatProvider?.appendReplies(...)                 (fire-and-forget Task, local-first)
        └─ GlassesPresentationLayer.{conversation|meeting}ConversationPages(...) → G2 send (if followLive)
```

### 2.2 The reply generator stack (`replyGenerator`, wired in `EvenAIApp.init`)

```
SuggestedReplyGenerating  (protocol — provider-agnostic)           [Core/Domain/SuggestedReplyGenerating.swift]
   generateReplies(for turn: ConversationTurn, context: SuggestedReplyContext) async throws -> [SuggestedReply]

SuggestedReplyContext { recentTurns: [ConversationTurn], contextItems: [ContextItem] }
   ‑ doc: "kept as its own type … so the protocol can grow what it passes without changing its signature"

LocalSuggestedReplyGenerator : SuggestedReplyGenerating   (struct, the production wiring)
   ├─ tier 1: FoundationModelsReplyGenerator (iOS 26+, Apple Intelligence ON)  [same file]
   │            builds instructions + prompt(for:context:) from context.recentTurns only
   │            → LanguageModelSession.respond(generating: ReplySuggestionSet)
   ├─ tier 2: LightweightLocalReplyGenerator   (pure intent-classification → hand-written templates; EN/DE/PL)
   └─ any tier-1 throw → falls to tier 2; tier 2 only "fails" on empty utterance
NoOpSuggestedReplyGenerator : SuggestedReplyGenerating  (returns []) — the engine's default, not wired live
```

### 2.3 Personal AI context (local, already surface-parameterised)

```
PersonalAIContextBuilding  (protocol)                              [Core/Domain/PersonalAI/PersonalAIProtocols.swift]
   buildContext(_ request: PersonalAIContextRequest) async -> PersonalAIContext      (async, NON-throwing)

PersonalAIContextRequest { surface: PersonalAISurface, userMessage, recentConversation: [String],
                           conversationID: UUID?, projectHints, personHints,
                           tokenBudget: Int = 1200, now: Date }
PersonalAISurface = .personalChat | .g2Replies | .voiceAssistant     ← .g2Replies already exists

DefaultPersonalAIContextBuilder : PersonalAIContextBuilding          [Infrastructure/PersonalAI/…]
   1. isMemoryEnabledGlobally() → `disabled`  → NO retrieval, memoryDisabled:true
   2. isConversationExcluded(conversationID) → NO retrieval for that conversation
   3. archive expired records (so tombstoned/expired can NEVER be retrieved)
   4. rules = allRules().filter { isActive(now:, surface:) }.sorted { $0.priority < $1.priority }   ← surface-aware
   5. currentInstruction (interpreter) — highest priority tier
   6. retrieval: MemoryRetriever.retrieve(RetrievalQuery(text:, recentContext:, surface:, hints:, now:), from: liveRecords)
   7. style: styleProfile() → renderStyle(...)
   8. PersonalAIContextRenderer.render(...) → token-budgeted `systemPromptText` + content-free `trace`
      · priority ordering: current instruction > active rules > projects/people > other memories > excerpts > style
      · drops lowest-priority sections to fit `tokenBudget` (approxTokens = count/4)

PersonalAIContext { activeRules, relevantMemories, relevantProjects, relevantPeople,
                    historicalExcerpts, styleInstructions, systemPromptText,
                    memoryDisabled: Bool, buildTrace: [String] (safe to log), hasPersonalization: Bool }

MemoryScope.appliesTo(surface:)   — .g2Replies scope gated to surface == .g2Replies
Rule.isActive(now:, surface:)     — surface-parameterised
PersonalAIContainer.live          — cloudService = nil, cloudEnvironment = .notConfigured
   exposes (plain Sendable): memoryStore, contextBuilder, ownerBox (PersonalOwnerBox.ownerID)
PersonalAIService.personalContext(for:message:recentTurns:projectHints:now:) async -> PersonalAIContext
   — nonisolated, "pure, cancellable read … cannot delay translation, cannot stop listening"
```

### 2.4 Composition (`EvenAIApp.init`, 169 lines)

```
personalAI  = PersonalAIContainer.live.makeService()              (PersonalAIService, @MainActor)
liveTranslation = AIConversationEngine(
    glassesTransport:, transcriber: TranscriptionProviderRouter,
    translator: AppleLanguageTranslator, agentContextStore:,
    replyGenerator: LocalSuggestedReplyGenerator(),               ← THE ONE LINE PHASE 3 CHANGES
    glassesChatProvider:)
```

`personalAI` and `liveTranslation` **never reference each other** — an explicit
documented invariant ("a Personal AI failure cannot reach the proven AI
Conversation core").

---

## 3. SELECTED INTEGRATION SEAM

### Recommended: a decorator around `SuggestedReplyGenerating`, plus one additive field

```
                       AIConversationEngine  (UNCHANGED)
                                │  replyGenerator: SuggestedReplyGenerating
                                ▼
   ┌──────────────────────────────────────────────────────────────────────────┐
   │  NEW  PersonalAIContextEnrichingSuggestedReplyGenerator : SuggestedReplyGenerating
   │       wrapping base: SuggestedReplyGenerating   (= LocalSuggestedReplyGenerator())
   │       + contextBuilder: any PersonalAIContextBuilding   (= PersonalAIContainer.live.contextBuilder)
   │       + ownerID:  @Sendable () -> String?               (= { PersonalAIContainer.live.ownerBox.ownerID })
   │       + profile:  @Sendable () -> ConversationProfile   (reads the SAME UserDefaults key the engine owns)
   │       + budgetTokens: Int = 700,  enrichmentTimeout: Duration = .seconds(4)
   │
   │   generateReplies(for turn, context):
   │     ownerAtStart = ownerID()
   │     ctx = try? await withTimeout(enrichmentTimeout) {
   │             await contextBuilder.buildContext(
   │               PersonalAIContextRequest(surface: .g2Replies,
   │                 userMessage: turn.originalText,
   │                 recentConversation: context.recentTurns.map(\.originalText),
   │                 conversationID: nil, tokenBudget: budgetTokens, now: .now)) }
   │     guard let ctx, !ctx.memoryDisabled, ctx.hasPersonalization,
   │           ownerID() == ownerAtStart, !Task.isCancelled
   │       else { return try await base.generateReplies(for: turn, context: context) }   // plain fallback
   │     enriched = context  ;  enriched.personalAIContext = ctx.forGeneration(profile: profile())
   │     return try await base.generateReplies(for: turn, context: enriched)
   └──────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
   LocalSuggestedReplyGenerator  (router struct — UNCHANGED)
      ├─ FoundationModelsReplyGenerator.prompt(for:context:)   +≈4 lines: if let p = context.personalAIContext,
      │                                                          !p.isEmpty { append "Personalisation:\n\(p)" }
      └─ LightweightLocalReplyGenerator   (Slice 1: UNCHANGED — enrichment is a no-op on this tier;
                                           Slice 2 optional: style-biased template *selection*, additive)
```

- **`AIConversationEngine`: NO change.** The decorator is injected exactly where
  `LocalSuggestedReplyGenerator()` is today.
- **`LocalSuggestedReplyGenerator` (the router struct): NO change.**
- **`SuggestedReplyContext`: one additive optional field** —
  `var personalAIContext: String?` (a pre-rendered, pre-bounded block, default
  `nil`). Sanctioned by the type's own doc comment. Every existing call site is
  source-compatible.
- **`FoundationModelsReplyGenerator` (same file as the router):** ~4 additive
  lines in `prompt(for:context:)` to fold the block into the prompt when
  present.
- All new logic (retrieval, budget, timeout, owner check, memory-disabled
  check, profile shaping, provenance) lives in **one new file**, the decorator.

### Alternatives considered

| Option | What | Verdict |
|---|---|---|
| **A. Engine coordinates Personal AI** | `AIConversationEngine` builds the context and passes it down | **Rejected.** Turns the engine into a Personal AI coordinator; violates the "never reference each other" invariant; large diff in the proven core. |
| **B. Two-stage in the engine** (base replies now, replace with enriched later) | engine publishes base replies, then a second enriched publish | **Rejected.** Requires engine changes; adds a second stale-write path + flicker; the engine's single stale-display gate already handles one-shot publish cleanly. |
| **C. Recommended** (decorator + additive `personalAIContext` field, consumed by the FM tier) | above | **Selected.** Smallest change that actually delivers enrichment; single prompt-assembly point; every invariant preserved. |
| **G. Pure decorator, zero generator-stack change** | decorator runs its **own** `LanguageModelSession` with personalised instructions when FM is available; otherwise delegates unchanged | **Fallback if the reviewer wants literally zero change to `LocalSuggestedReplyGenerator.swift`.** Cost: ~20 lines duplicating the FM session/schema usage; no enrichment on the lightweight tier ever. Still fully invariant-safe. |
| **D. Abuse `contextItems`** to smuggle memory in | inject a synthetic `ContextItem` | **Rejected.** `ContextItem` is user-authored notes/pasted-text; the FM prompt doesn't read `contextItems` anyway; semantically wrong. |

**Decision: Option C.** If review prefers absolute non-modification of the
generator file, fall back to Option G — Slice 1 is structured so the two are
interchangeable without touching Slices 2–5.

---

## 4. DATA FLOW (proposed, local only)

| Stage | Input | Output | Owner | Concurrency / cancellation |
|---|---|---|---|---|
| finalized turn | `ConversationTurn` | — | `AIConversationEngine` | its turn-pipeline task; cancelled when a newer turn supersedes |
| translation | `ConversationTurn` | rendered pages → G2 | engine | **independent task**, runs and displays first; never awaits anything below |
| base reply context | `agentContextStore.session` | `SuggestedReplyContext` | engine | built synchronously at task start |
| **enrichment** | turn text + `recentTurns` text | `PersonalAIContext` (or none) | **decorator** | `await contextBuilder.buildContext(...)` inside `withTimeout(enrichmentTimeout ≈ 4 s)`, itself inside the engine's `repliesTimeout` (15 s); cooperatively cancelled with the reply task |
| context → block | `PersonalAIContext` | `String?` (≤ `budgetTokens`) | decorator (`forGeneration`) | pure |
| generation | turn + `SuggestedReplyContext(+block)` | `[SuggestedReply]` | base generator (FM → lightweight) | unchanged |
| validity gate | `sequence`, `highestDisplayedTurnSequence`, `Task.isCancelled` | show / discard | **engine (existing)** | a stale enriched result is recorded in history, never displayed |
| publish | `[SuggestedReply].prefix(3)` | G2 pages (if `followLive`) | engine (existing) | unchanged |

- **Input types:** `ConversationTurn`, `SuggestedReplyContext` (in); `PersonalAIContextRequest` (decorator→builder).
- **Output types:** `[SuggestedReply]` (unchanged). The decorator never returns anything the engine doesn't already handle.
- **Concurrency boundary:** the decorator does exactly one `await` (the context build); everything else is synchronous mapping. It spawns **no** long-lived task, holds **no** state between calls.
- **Cancellation boundary:** the engine's reply task. The decorator's `buildContext` is cooperatively cancellable; its inner `withTimeout` guarantees it returns within `enrichmentTimeout` regardless.
- **Turn/version strategy:** **reuse** the engine's existing `sequence` /
  `highestDisplayedTurnSequence`. The decorator does not invent a turn id — it
  is stateless and the engine already binds the whole reply task to the turn.
- **Fallback behavior:** any of {timeout, throw, `memoryDisabled`,
  `!hasPersonalization`, owner changed, cancelled} → `base.generateReplies(for:
  turn, context:)` with the **un-enriched** context → identical to today.
- **Memory-disabled behavior:** `DefaultPersonalAIContextBuilder` returns
  `memoryDisabled: true` with no retrieved memory; the decorator sees that and
  takes the plain-fallback path (it does not even pass a block).
- **Account-switch behavior:** `ownerID()` is snapshotted at entry and
  re-checked after the build; a change → plain fallback. (The local memory
  store is per-device/per-user; a Slice-4 test pins that a switch cannot leak
  the previous owner's memory into an in-flight enrichment.)

---

## 5. CONTEXT BUDGET

Personal AI context handed to generation is **small, deterministic, relevant**.
The existing `PersonalAIContextRenderer` already does priority-ordered,
token-budgeted assembly with lowest-priority-first trimming — Phase 3
**reuses it unchanged**, only with a smaller budget.

| Category | Source | Priority | Trimming |
|---|---|---|---|
| current-message instruction | `interpreter.interpret(turn.originalText)` | 1 (highest) | never dropped |
| active rules | `allRules().filter(isActive(surface: .g2Replies)).sorted(by: priority)` | 2 | lowest-priority rule dropped first |
| relevant person / project memory | `MemoryRetriever` top hits, `category ∈ {people, projects}` | 3 | capped at a small N; lowest-score dropped |
| other relevant preferences / facts | retriever hits, other categories | 4 | lowest-score dropped |
| learned style | `styleProfile()` → `renderStyle(...)` | 5 | dropped whole before any rule |
| immediately relevant conversation excerpts | retriever hits, `category == conversationArchive`, `≠` current conversation | 6 (lowest) | `.prefix(3)`, dropped first |

- **Budget: `tokenBudget = 700`** for `.g2Replies` (vs `1200` for Chat) — a G2
  reply prompt does not need a long context; the latest phrase dominates
  relevance. Exact value is tunable and covered by a Slice-2 test that pins the
  rendered block never exceeds the budget.
- Ordering = `PersonalAIContextRenderer`'s existing order (invariant 14:
  current instruction > active rule > retrieved memory/preference > learned
  style > default). **No re-ranking is added.**
- The decorator passes only `PersonalAIContext.systemPromptText` (already
  rendered + bounded) — it does **not** assemble its own text from the
  structured fields, so there is exactly one place the budget/priority logic
  lives.

---

## 6. CONVERSATION PROFILE BEHAVIOR

Current profiles (`ConversationProfile`, `rawValue` in parens):

| Profile | Today (presentation only — same pipeline) |
|---|---|
| `.conversation` ("standard") | 1-to-1; first reply merged onto G2 page 0, auto-shown |
| `.meeting` | longer/group; replies generated + recorded + reach G2 as **extra swipeable pages**, never displace the active transcript |
| `.auto` | engine's `effectiveDisplayProfile` heuristic picks `.conversation` or `.meeting` presentation from turn cadence / length / is-a-question — never a third shape |

**Phase 3 does not redesign profiles.** The decorator reads the *effective*
intent and appends one line to the personalisation block:

| Effective profile | Appended guidance (in the personalisation block only) |
|---|---|
| `.conversation` (incl. `.auto`→conversation) | *"This is a 1-to-1 conversation. Give 2–3 concise, natural replies in the speaker's language, personalised to the context above. No generic filler."* |
| `.meeting` (incl. `.auto`→meeting) | *"This is a meeting / group setting. Prefer concise, professional replies and useful follow-up questions; phrase them so they read well projected on a small display."* |

- The decorator reads the profile from `UserDefaults`
  (`com.evenai.liveTranslation.conversationProfile`) — the **same key
  `AIConversationEngine` persists** — so it never references the engine.
- For `.auto`, Slice 1 uses the stored value; a later slice may expose the
  engine's `effectiveDisplayProfile` read-only if the difference matters in
  physical testing. Not a v1 requirement.
- Output shape is unchanged: **2–3** `SuggestedReply` (the engine's
  `prefix(3)` cap still governs).

---

## 7. LATENCY ARCHITECTURE

**Translation display never depends on Personal AI.** It already runs as an
independent, higher-priority task that displays before reply generation even
starts — Phase 3 adds nothing to that path.

Choice **A** (base replies now, replace with enriched later) **vs B** (single-stage
with a strict local context budget):

**Selected: B — single-stage, strict budget, inside the existing reply slot.**

- Rationale: the engine already publishes replies **once** per turn, gated by a
  single stale-display check. Option A would introduce a *second* publish per
  turn → visible flicker (base replies pop, then swap), a second stale-write
  path to reason about, and engine changes. Option B keeps exactly one publish,
  one stale gate, zero flicker.
- The cost of B — the reply *may* wait up to `enrichmentTimeout` (~4 s) longer
  than today when Personal AI is slow — is bounded, is strictly less than the
  engine's existing `repliesTimeout` (15 s), and never affects translation.
  If enrichment exceeds its budget, the decorator abandons it and calls the
  base generator immediately, so the worst case ≈ today + a few ms.
- No arbitrary millisecond target is asserted. **Measurement plan (later):**
  the engine already emits `LATENCY_TRACE REPLIES_LATENCY_MS` per turn; Slice 5
  adds two trace points in the decorator (`ENRICH_START` / `ENRICH_DONE`
  ms, content-free) so real-hardware runs can compare enriched vs
  plain-fallback turns. `enrichmentTimeout` and `budgetTokens` are then tuned
  from those numbers, not guessed.

---

## 8. STALE-RESULT / CANCELLATION MODEL

**Reuse the engine's existing mechanism — do not add a second one.**

| Concern | Existing mechanism (reused) | Decorator's added part |
|---|---|---|
| bind work to the current turn | the whole `generateSuggestedReplies` task is per-turn; a newer turn cancels the older task | none — the decorator is stateless, inside that task |
| cancellation token | Swift structured concurrency: `Task.isCancelled` + cooperative `await` | the decorator's `buildContext` is a cooperative `await`; the inner `withTimeout` also bounds it |
| generation/version check | `guard sequence >= highestDisplayedTurnSequence` **after** generation, **before** G2 display | none |
| account identity check | — (new) | `ownerID()` snapshot at entry, re-checked after the build → mismatch = plain fallback |
| memory-state check | — (new) | `PersonalAIContext.memoryDisabled` → plain fallback |
| discard a stale result | the engine records it in history (`agentContextStore.updateTurn`) but **skips the G2 display** silently | none — same path, whether the replies were enriched or not |

- An enriched result for turn N that completes after turn N+1 has displayed:
  generated → `updateTurn` (history) → `sequence < highestDisplayedTurnSequence`
  → **silently discarded from the display**. Exactly today's behavior for a
  late plain reply (`AIConversationEngineG2DisplayTests` line 111).
- The decorator introduces **no** new publish, **no** new task, **no** new
  timer that outlives the call — so there is no second stale-write surface.

---

## 9. PERSONAL AI FAILURE MATRIX

Every row → **the existing local reply path stays fully usable** (the decorator
calls `base.generateReplies(for: turn, context:)` with the un-enriched
context).

| Failure | Detected by | Result |
|---|---|---|
| no relevant memories | `!ctx.hasPersonalization` | plain fallback (no block passed) |
| memory disabled globally / this conversation | `ctx.memoryDisabled` (builder handles it) | plain fallback |
| retrieval error inside the builder | `buildContext` is non-throwing; it returns `.empty`-ish with a trace note | plain fallback |
| local store unavailable / throws | wrapped in `try?`; also the inner `withTimeout` | plain fallback |
| cloud not configured | N/A — no cloud is consulted; `PersonalAIContainer.live` is `.notConfigured` | plain fallback / normal |
| cloud offline | N/A — same | normal |
| account changed mid-build | `ownerID()` re-check | plain fallback |
| retrieval cancelled (newer turn) | `Task.isCancelled` / cancellation propagates | reply task returns "no replies" (engine handles) |
| malformed / deleted / tombstoned memory | builder archives expired + retrieval reads the live store; a deleted record is simply not returned | not used; plain or enriched-without-it |
| context builder itself hangs | inner `withTimeout(enrichmentTimeout)` | plain fallback after the budget |
| Personal AI timeout / budget exceeded | inner `withTimeout` | plain fallback |
| decorator itself throws (bug) | it does not — but if it did, the engine's outer catch treats it as "no replies this turn" | translation unaffected; no session error |

---

## 10. PRIVACY BOUNDARY

**Allowed into the generation prompt:** only
`PersonalAIContext.systemPromptText` — the renderer's compact, budgeted,
natural-language block: active rules, retrieved *relevant* memories/preferences,
person/project facts judged relevant to *this* utterance, learned style,
≤3 short conversation excerpts. Plus one profile-guidance line.

**Never:**

- tokens, passwords, API keys, private keys, recovery keys, cloud credentials —
  Personal AI memory structurally does not store these
  (`BackupHardeningTests.noSecretsInBackup`), and the renderer emits only the
  retrieved subset regardless.
- the raw full memory archive — only the retrieved, budgeted subset.
- memories not judged relevant to the current utterance — retrieval-gated.
- another user's data — the local store is per-owner; `ownerID()` re-check.
- **any Personal AI text into the G2 transport** — the decorator passes context
  only to the reply generator; the engine renders **only the final
  `SuggestedReply` strings** (which the user already sees). The transport never
  receives a `PersonalAIContext`.
- **any Personal AI content into production logs** — the decorator logs only
  `PersonalAIContext.buildTrace` (documented "safe to log": counts, "dropped
  for budget", `surface=g2Replies`) plus its own two content-free latency marks.
  Never `systemPromptText`, never a memory string.

Provenance for debugging stays local: `buildTrace` is attached to the
`DiagnosticTrace` stream only, and is already content-free by construction.

---

## 11. FILE-LEVEL IMPLEMENTATION PLAN

| File | New / Modified | Purpose | Why required |
|---|---|---|---|
| `EvenAI/Infrastructure/PersonalAI/PersonalAIContextEnrichingSuggestedReplyGenerator.swift` | **NEW** | the decorator: build `.g2Replies` context (bounded, timed, cancellable), owner + memory-disabled guards, profile shaping, delegate to a wrapped `SuggestedReplyGenerating` | the one place all Phase-3 logic lives; keeps the engine and generator stack out of it |
| `EvenAI/Core/Domain/SuggestedReplyGenerating.swift` | **MODIFIED** (additive) | `SuggestedReplyContext` gains `var personalAIContext: String? = nil` | the base generator needs a channel to receive the block; the type's own doc sanctions growing it; `nil` default = every call site source-compatible |
| `EvenAI/Infrastructure/Voice/LocalSuggestedReplyGenerator.swift` | **MODIFIED** (≈4 lines, additive, in `FoundationModelsReplyGenerator.prompt`) | when `context.personalAIContext` is present, prepend a `Personalisation:` block to the prompt | otherwise enrichment has no effect on tier 1. `LocalSuggestedReplyGenerator` (the router struct) itself is untouched. |
| `EvenAI/Infrastructure/Voice/LightweightLocalReplyGenerator.swift` | **Slice 2, OPTIONAL** (≈6 lines, additive) | style-biased template *selection* (prefer shortest / follow-up variant per style + active rules) | tier 2 has no prompt; this is the only way personalisation reaches it. Deferrable — Slice 1 leaves tier 2 unchanged (enrichment simply no-ops there). |
| `EvenAI/App/EvenAIApp.swift` | **MODIFIED** (1 expression) | wrap `LocalSuggestedReplyGenerator()` in the decorator, injecting `PersonalAIContainer.live.contextBuilder` + `ownerBox` + a `UserDefaults`-reading profile closure | the composition change; no behavioral code |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentTests.swift` | **NEW** | decorator behavior vs a fake context builder + fake base generator (§13 tests 1–13, 15–20) | slice 1–4 verification |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentContextBudgetTests.swift` | **NEW** | priority order + budget bound + profile guidance (§13 tests 14, 17–19) | slice 2 verification |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentCompositionTests.swift` | **NEW** | wiring: `.notConfigured` container still instantiates the decorator; falls back safely (§13 tests 5–6) | slice 3 verification |

**If Option G is chosen instead:** drop the `SuggestedReplyGenerating.swift` and
`LocalSuggestedReplyGenerator.swift` modifications; the decorator gains its own
`@available(iOS 26.0)` `LanguageModelSession` path reusing `ReplySuggestionSet`.
Same test files.

Net **production** change (Option C, Slice 1): **1 new file + 3 modified**
(1 additive Core field, ~4 additive Infra lines, 1 composition expression).
`AIConversationEngine`, `LocalSuggestedReplyGenerator` (router), the
translation/transcription/mic/G2-transport code: **0**.

---

## 12. COMPOSITION / DEPENDENCY INJECTION

```
Base:    LocalSuggestedReplyGenerator()                        (unchanged)
Wrapped: PersonalAIContextEnrichingSuggestedReplyGenerator(
             wrapping: LocalSuggestedReplyGenerator(),
             contextBuilder: PersonalAIContainer.live.contextBuilder,
             ownerID: { PersonalAIContainer.live.ownerBox.ownerID },
             profile:  { EvenAIApp.resolveConversationProfile(defaults: .standard) })
Injected as: SuggestedReplyGenerating  →  AIConversationEngine(replyGenerator:)
```

- **No CloudKit / R2 dependency to instantiate.** `PersonalAIContainer.live` is
  `.notConfigured`; `contextBuilder` (`DefaultPersonalAIContextBuilder`) reads
  only the local, on-device `memoryStore`. The decorator constructs and runs
  with zero network.
- **Fallback if Personal AI is unavailable at composition time:** the decorator
  always holds a real `base`; if `contextBuilder` were ever `nil`/unavailable
  (it is not, in `.live`), the decorator is written to degrade to
  `base.generateReplies` unconditionally — so `EvenAIApp` can construct it
  unconditionally and shipping behavior stays local-first.
- `EvenAIApp` needs a small `static func resolveConversationProfile(defaults:)`
  helper mirroring the existing `resolveTranscriptionProviderMode` /
  `resolveOnDeviceLocale` pattern — reads the engine's own persisted key
  read-only. (Counts as part of the `EvenAIApp.swift` modification above.)
- Tests inject a `FakePersonalAIContextBuilder` + `FakeSuggestedReplyGenerator`
  + a static `ownerID` / `profile` — no container, no `PersonalAIService`.

---

## 13. TEST PLAN (software — written before implementation)

Target: **~24 new tests** across the three new files, plus 4 existing suites
asserted still green.

| # | Test | Asserts |
|---|---|---|
| 1 | relevant memory changes the enriched replies | with a "prefers terse yes/no" style + a relevant fact, the fake base generator receives a non-nil `personalAIContext` containing them |
| 2 | no relevant memory → base behavior | empty store → decorator calls base with `personalAIContext == nil`; output identical to base |
| 3 | memory disabled → retrieval not called | `isMemoryEnabledGlobally == false` → builder returns `memoryDisabled` → decorator passes `nil`; (fake builder records it was asked but returned disabled) |
| 4 | context builder throws / hangs → base replies still produced | fake builder throws / delays past `enrichmentTimeout` → decorator returns `base.generateReplies` result |
| 5 | cloud not configured → replies still work | decorator built from `PersonalAIContainer.live` (`.notConfigured`) produces replies |
| 6 | cloud outage → replies still work | no cloud is consulted; assert no network type is referenced (source scan) |
| 7 | translation path does not await Personal AI | existing `AIConversationEngineTests` "replies A never return — phrase B still processes, translation never blocked" stays green with the decorator wired |
| 8 | listening path stays active | existing continuous-listening / soak test stays green |
| 9 | newer utterance cancels enrichment | cancel the decorator's task mid-`buildContext` → it returns promptly via cancellation; no enriched result published |
| 10 | stale enriched result cannot overwrite newer suggestions | existing `AIConversationEngineG2DisplayTests` line 111 stays green (a late enriched reply for an old turn is recorded, not displayed) |
| 11 | account switch invalidates context | `ownerID()` returns X at entry, Y after the build → decorator discards the enrichment, uses base |
| 12 | no cross-user retrieval | fake builder asserts it only ever sees the current owner's request; a second owner's memory never appears in owner-1's enriched block |
| 13 | deleted / tombstoned memory not used | delete a record before the call → it is absent from the enriched block |
| 14 | current-instruction priority preserved | a current-message instruction + a conflicting stored rule → rendered block orders instruction first (delegates to `PersonalAIContextRenderer`'s existing order) |
| 15 | active rules influence replies | an `isActive(surface: .g2Replies)` rule appears in the block; an inactive / `.personalChat`-scoped rule does not |
| 16 | learned style influences phrasing at lower priority | style guidance present but after rules in the block; dropped first when the budget is tight |
| 17 | `.conversation` profile → concise personalised guidance line | block contains the conversation-profile guidance |
| 18 | `.meeting` profile → professional / follow-up guidance line | block contains the meeting-profile guidance |
| 19 | output stays 2–3 suggestions | fake base returns 5 → decorator does not change count; engine's `prefix(3)` still governs (asserted at engine level) |
| 20 | Personal AI context never leaves as anything but final suggestions | decorator passes context only to `base`; a spy transport never receives a `PersonalAIContext`; logs contain only `buildTrace` strings |
| 21 | existing `LocalSuggestedReplyGeneratorTests` unchanged & green | run as-is |
| 22 | existing `AIConversationEngine` stale-reply tests green | `AIConversationEngineG2DisplayTests` 111 / 337, `AIConversationEngineSoakTests` 264 |
| 23 | existing translation-before-replies test green | `AIConversationEngineTests` 750 / 783 |
| 24 | budget bound | rendered `personalAIContext` block never exceeds `budgetTokens` (`approxTokens`) for a large synthetic store |

Plus: full `EvenAITests` must stay green (currently **826/826**); Worker
**49/49** untouched (Phase 3 touches no Worker code).

---

## 14. PHYSICAL G2 TEST PLAN (after software tests pass — not run now)

| # | Scenario | Expected |
|---|---|---|
| A | Store a known preference ("I always decline meetings before 10am"), then have someone invite you to an early meeting | a suggested reply reflects the preference |
| B | Toggle memory OFF, repeat A | normal local suggestions; no personalisation |
| C | Speak 4–5 short utterances in rapid succession | each turn's translation appears immediately; no stale/older suggestion ever shown against a newer turn |
| D | Watch the display during one turn | translation renders before any reply; reply (enriched or not) appears after, without holding the translation |
| E | Keep speaking while suggestions are generating | transcription/listening never pauses or drops a word |
| F | Switch to Meeting profile, hold a mock meeting | suggestions read as professional / include useful follow-up questions |
| G | Disable Apple Intelligence (or use an ineligible device) | suggestions still appear (lightweight tier); Personal AI enrichment silently absent; nothing breaks |
| H | Sign out / switch account mid-session, keep talking | no memory from the previous account appears; suggestions continue |

---

## 15. RISK REVIEW

| Rank | Risk | Mitigation |
|---|---|---|
| **R1 (critical)** | **Latency regression on the reply path** — a slow local retrieval delays replies | inner `withTimeout(enrichmentTimeout ≈ 4 s)` strictly inside the engine's 15 s `repliesTimeout`; on timeout the decorator immediately calls the base generator; Slice-5 real-hardware measurement tunes the budget from `LATENCY_TRACE` numbers |
| **R1 (critical)** | **Wrong user/memory binding** — enriched replies from another account | `ownerID()` snapshot + re-check; local store is per-owner; test 11/12; account-switch physical test H |
| **R2 (high)** | **Stale enriched suggestion shown for a newer turn** | reuse the engine's existing `sequence`/`highestDisplayedTurnSequence` gate — no second publish path; test 10; existing G2DisplayTests 111 |
| **R2 (high)** | **Accidental cloud dependency** creeps in | decorator depends only on `any PersonalAIContextBuilding` + closures; source-scan test 6; `PersonalAIContainer.live` is `.notConfigured`; CI: no networking import in the new file |
| **R2 (high)** | **`AIConversationEngine` scope creep** | the seam is the injected `replyGenerator` only; engine diff must be exactly zero — enforced by review + `git diff --stat` on the engine file |
| **R3 (medium)** | **Over-personalisation** — replies become weird / off-topic | `PersonalAIContextRenderer`'s anti-generic guidance + small budget (700) + retrieval relevance gating; profile guidance keeps replies conversational; physical test A/F judgement |
| **R3 (medium)** | **Excessive context** dumped into the prompt | reuse the existing budgeted renderer; test 24 pins the bound |
| **R3 (medium)** | **Reply flicker / reordering** | single-stage generation (Option B), one publish, one stale gate — no base-then-enriched swap |
| **R3 (medium)** | **Continuous-listening regression** | decorator spawns no task, does no audio work; existing soak/listening tests must stay green (test 8) |
| **R4 (low)** | **Privacy leak into logs / transport** | only `buildTrace` (content-free) logged; transport never sees context; test 20 |
| **R4 (low)** | **Lightweight tier gets no personalisation** (Slice 1) | documented limitation; Slice 2 adds style-biased template selection; not an invariant violation |
| **R4 (low)** | **`.auto` profile nuance** (stored vs effective) | Slice 1 uses the stored value; revisit only if physical testing shows it matters |

---

## 16. IMPLEMENTATION SLICES (each independently reviewable, no commit without approval)

| Slice | Scope | Tests |
|---|---|---|
| **1** | `PersonalAIContextEnrichingSuggestedReplyGenerator` + the additive `SuggestedReplyContext.personalAIContext` field + the ~4-line `FoundationModelsReplyGenerator` consumption. Fakes only. **Not wired into `EvenAIApp` yet.** | decorator behavior vs fakes: §13 tests 1–6, 9, 11–13 |
| **2** | Context budget + priority + profile guidance via the real `DefaultPersonalAIContextBuilder` + `PersonalAIContextRenderer` (unchanged); optional lightweight-tier style-biased selection | §13 tests 14–19, 24 |
| **3** | Composition: wire the decorator in `EvenAIApp` behind the existing `SuggestedReplyGenerating` injection; `resolveConversationProfile` helper | §13 tests 5, 20; full `EvenAITests` green |
| **4** | Concurrency / cancellation / stale-turn hardening: prove the engine's existing gates cover the enriched path; account-switch invalidation | §13 tests 7–10, 22–23; existing engine suites green |
| **5** | Full regression + latency instrumentation (2 content-free trace marks) + the physical G2 test plan (§14), executed on real hardware | 826+ green; Worker 49/49; physical A–H |

If the reviewer selects **Option G**, Slice 1 swaps "additive field + FM
consumption" for "decorator-owned `LanguageModelSession`"; Slices 2–5 are
unchanged.

---

## 17. EXPLICIT NON-GOALS (Phase 3 v1 WILL NOT include)

- Enabling real CloudKit sync, real R2, or deploying the Worker.
- Any remote LLM / backend / Railway dependency for replies (the local stack
  stays the only path; `NetworkSuggestedReplyGenerator` remains unwired).
- G2 direct database / memory-store access.
- Any change to microphone capture, audio routing, transcription, or
  translation.
- Any change to `AIConversationEngine`'s translation/listening/staleness
  behavior, or to the G2 transport / rendering ownership.
- **Automatic memory extraction from G2 utterances** — Phase 3 only *reads*
  Personal AI for enrichment; it does not *write* memories from what is
  overheard in a live translation session. (That would be a separate,
  separately-approved feature with its own privacy review.)
- A new conversation-profile design; speaker diarization.
- Personalisation of the lightweight template tier beyond simple style-biased
  selection (Slice 2, optional).
- Persisting Personal AI context anywhere (it is rebuilt per turn, held only
  for the duration of one `generateReplies` call).

---

## 18. PHASE 3 GO CONDITIONS

**GO to implement Slice 1** when this plan is approved and:

- [ ] the selected seam is confirmed (Option C, or Option G).
- [ ] `enrichmentTimeout` (~4 s) and `budgetTokens` (~700) are accepted as
      *starting* values, to be tuned in Slice 5 from real measurements.
- [ ] it is accepted that Slice 1 does not wire the decorator into `EvenAIApp`
      (that is Slice 3, after fakes prove the behavior).

**Each slice** then requires its own review before the next, and before any
commit. **No slice** may:

- add a line to `AIConversationEngine`, the transcriber router, the translator,
  the G2 transport, or any audio code;
- introduce a network call, a CloudKit call, or an R2 call;
- make a suggested reply *depend* on Personal AI succeeding;
- send anything but final `SuggestedReply` strings to the glasses.

If any of those becomes necessary, **stop and re-review** — it means the seam
was wrong.

---

## IMPLEMENTATION RECORD

**Implemented 2026-09-02. Option C. Uncommitted; not pushed.** Full detail:
`PHASE3_PERSONAL_AI_G2_IMPLEMENTATION.md`.

### What was built (vs plan §11)

| File | New/Mod | Reality |
|---|---|---|
| `EvenAI/Infrastructure/PersonalAI/PersonalAIReplyEnrichment.swift` | **NEW** | `PersonalAIContextEnrichingSuggestedReplyGenerator` (decorator) + `PersonalAIReplyEnrichmentConfig` (the one tuning owner) + `PersonalAIReplyContextRenderer` (block framing + profile line) + `withEnrichmentTimeout` |
| `EvenAI/Core/Domain/SuggestedReplyGenerating.swift` | MOD (+21/−1) | `SuggestedReplyContext.personalAIContext: String? = nil` (additive, source-compatible) |
| `EvenAI/Infrastructure/Voice/LocalSuggestedReplyGenerator.swift` | MOD (+7) | `FoundationModelsReplyGenerator.prompt(for:context:)` prepends the block when present. `LocalSuggestedReplyGenerator` (router) **and** `LightweightLocalReplyGenerator` **unchanged**. |
| `EvenAI/App/EvenAIApp.swift` | MOD (+30/−1) | wraps `LocalSuggestedReplyGenerator()` in the decorator at the `replyGenerator:` arg; `+ resolveConversationProfile(defaults:)` helper (mirrors `resolveTranscriptionProviderMode`) |
| `EvenAI/App/AIConversationEngine.swift` | **UNCHANGED** — `git diff` empty |
| `EvenAITests/TestDoubles/FakePersonalAIProviders.swift` | MOD (+52) | `ScriptedContextBuilder` test double |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentTests.swift` | **NEW** | Slice 1 + 4 — decorator vs fakes (10 tests) |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentContextTests.swift` | **NEW** | Slice 2 — real `DefaultPersonalAIContextBuilder` (10 tests) |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentCompositionTests.swift` | **NEW** | Slice 3 — wiring / no-cloud (7 tests) |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentEngineIntegrationTests.swift` | **NEW** | Slice 4 — decorator through the real `AIConversationEngine` (4 tests) |

The Slice-1 additive-field choice was taken (Option C), **not** the
decorator-owned `LanguageModelSession` (Option G). `LightweightLocalReplyGenerator`
enrichment (plan §11 "Slice 2, OPTIONAL") was **not** done — on a device with
Apple Intelligence off the enrichment is a documented no-op (falls straight
through to the templates); the invariants are fully preserved either way.

### Slice status

| Slice | Status |
|---|---|
| 1 — enrichment decorator + fakes | ✅ done, green |
| 2 — real local `PersonalAIContextBuilding` + budget/priority/profile | ✅ done, green |
| 3 — production composition in `EvenAIApp` | ✅ done, wired, green |
| 4 — concurrency / cancellation / stale-turn / account-switch | ✅ done, green (reuses the engine's `sequence` gate; adds owner snapshot + `withEnrichmentTimeout`) |
| 5 — full regression + privacy review + physical G2 plan | ✅ software done; physical G2 tests **NOT run** (§14 plan ready) |

### Tuning owner

`PersonalAIReplyEnrichmentConfig` (`.default` = `contextTokenBudget: 700`,
`enrichmentTimeout: .seconds(4)`, `surface: .g2Replies`,
`maxRecentConversationLines: 4`). Injected into the decorator; the only place
these literals appear (pinned by `configIsCentral` test). To be re-tuned from
`PERSONAL_AI_ENRICH` / `LATENCY_TRACE` on real hardware.

### Verification

Full `EvenAITests` **857 / 857** (107 suites, 0 failed) — +31 Phase 3 tests, +4 suites vs the 826/103 baseline; `xcodebuild build` +
`build-for-testing` SUCCEEDED. Existing translation-before-replies /
stale-reply / continuous-listening suites green.
