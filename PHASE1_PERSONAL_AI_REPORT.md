# EvenAI Personal AI — Phase 1 Report

**Goal of Phase 1:** prove, with tests, that a single reusable memory +
personalization architecture produces a materially better AI — *before*
building any cloud infrastructure around it. No production cloud, no
Railway, no changes to the proven AI Conversation / G2 system, no commits.

**Result:** built and green. 70 new tests, full existing suite still
passing, zero backend changes, zero AI Conversation core changes. A
pre-commit architecture/data-safety audit (§ "Audit", end of this document)
found 4 minor defects — all fixed, no redesign.

---

## Phase 1 architecture

One memory model, one retrieval pipeline, one context builder — shared by
Personal AI Chat now and the future G2 personalization surface, chosen by a
single `surface` parameter.

```
Core/Domain/PersonalAI/          pure value types + protocols (Foundation only)
  MemoryRecord, Rule, MemoryCategory, MemoryScope, MemoryStatus,
  PersonalAIStyleProfile, PersonalAIExchange, PersonalAIContext(+Request),
  RetrievalQuery/ScoredMemory, MemoryCommand/Candidate/MergeDecision,
  PersonalMemoryDocument
  protocols: PersonalMemoryStore, MemoryExtracting, PersonalAIContextBuilding,
  PersonalAIModelProviding, PersonalAIConversationStore
  Phase-2 seams (declared, not implemented): CloudMemoryStore,
  PersonalMemoryAPI, PersonalAIAPI

Infrastructure/PersonalAI/       concrete Phase-1 implementations
  TextSimilarity, SecretDetector, CommandInterpreter,
  HeuristicMemoryExtractor, MemoryMerger, MemoryRetriever, MemoryMaintenance,
  StyleProfileLearner, DefaultPersonalAIContextBuilder,
  PersonalAIContextRenderer, MemoryCommandProcessor,
  OnDevicePersonalAIModelProvider (+ FoundationModels tier),
  HeuristicPersonalAIModelProvider,
  LocalPersonalMemoryStore / InMemoryPersonalMemoryStore,
  LocalPersonalAIConversationStore / InMemory…

App/
  PersonalAIService              @MainActor @Observable orchestrator
  DI/PersonalAIContainer         composition root (separate from AppContainer)

Features/PersonalAI/Presentation/
  PersonalAIView (Settings landing), PersonalAIChatView,
  MemoryCenterView (+ VM), MemoryDetailView, MemoryEditorView,
  RuleListView, RuleEditorView, StyleProfileView
```

Layering obeys `ARCHITECTURE.md`'s Dependency Rule: `Core` imports nothing,
`Infrastructure → Core`, `App` composes, `Features` gets everything via the
injected `PersonalAIService`.

---

## Personal AI memory model

`MemoryRecord` — the single unit of long-term memory. Fields:

- **Identity / sync:** `id` (client UUID, stable forever), `remoteID`,
  `revision` (monotonic), `syncState`, `deletedAt` (tombstone), `ownerID`.
- **Classification:** `category` (10 categories: rules, profile, style,
  preferences, projects, people, knowledge, episodes, workingContext,
  conversationArchive), `scope` (global / personalChat / g2Replies /
  project(id)).
- **Content:** `canonicalContent` (self-contained statement), `structured`
  (`[String:String]`), `entities` (retrieval tags).
- **Ranking signals:** `createdAt`, `updatedAt`, `lastUsedAt`, `confidence`,
  `importance`, `userConfirmed`, `pinned`, `enabled`, `status`
  (active / superseded / archived / deleted).
- **Temporal:** `expiresAt`.
- **Provenance:** `sourceConversationIDs`, `sourceMessageIDs`,
  `supersedesID`, `supersededByID`.

`Rule` is a sibling record type (same identity/sync/provenance fields) —
first-class memory, stored in the same document, but *always evaluated*
rather than retrieval-gated.

All records are `Codable`/`Sendable`/`Hashable` pure values. The full state
is one `PersonalMemoryDocument` (schema-versioned) — which is simultaneously
the on-disk format, the export/backup unit, and the Phase 2 sync payload.

---

## Rules / command system

`CommandInterpreter` detects memory-affecting intent with **no slash
commands and no exact wording** — case-insensitive, multi-phrase,
comma-tolerant ("From now on," == "From now on"):

| Intent | Triggers (examples) |
|---|---|
| remember | "remember (that)…", "keep in mind…", "note that…", "don't forget…", "fyi…" |
| rule | "from now on…", "going forward…", "always…", "never…", "whenever…", "don't…", "stop …" |
| forget | "forget (about/that)…", "stop remembering…", "delete/remove the memory about…" |
| style | "keep replies short", "be direct", "use Ukrainian with me", "reply in English", "never say '…'", "no bullet points" |

`MemoryCommandProcessor` applies them immediately (the
`explicitCurrentInstruction` priority tier), routing through
`SecretDetector`, `MemoryMerger`, and `StyleProfileLearner`.

**Priority ladder** (`PersonalAIPriority`, enforced structurally by
`PersonalAIContextRenderer` section order + budget-trim-from-bottom):

```
explicit current instruction  >  active rule  >  retrieved memory
    >  learned style  >  default behavior
```

Rule fields: `id, text, createdAt, updatedAt, enabled, priority, scope,
source, expiresAt` + sync/provenance. Scopes: `global`, `personalChat`,
`g2Replies`, `project:<id>`.

---

## Memory extraction

`MemoryExtracting` protocol; Phase 1 conformer `HeuristicMemoryExtractor`
(deterministic, testable):

- **Captures:** explicit remember commands (high trust, `userConfirmed`),
  durable self-facts ("I live in…", "I work as…"), project statements
  ("we decided to…", "the launch is…"), stated preferences, person context.
- **Never captures:** filler / greetings, secrets, plain questions,
  unsupported inference (only what the user actually said), and — crucially
  — temporary phrasing is *not* promoted to a permanent fact ("in Berlin
  **this week**" → `workingContext` with a 7-day `expiresAt`, never
  `profile`).
- No-ops when memory is globally disabled or the conversation is excluded.

---

## Memory merging

`MemoryMerger.reconcile(candidate:, against:)` → one of:

- `.create` — no related memory.
- `.duplicate` — same fact restated: refresh the existing record, union
  provenance, bump confidence — **do not insert twice**.
- `.supersede` — same subject, disagreeing detail (different month /
  quarter / number, or strong subject overlap without duplication): insert
  the new record with `supersedesID`, mark the old `.superseded` with
  `supersededByID`, union provenance. **Never two active contradictory
  facts.**
- `.mergeInto` — one statement strictly contains the other: keep the richer
  text on the same record.
- `.reject` — secret / too short.

Example proven by test: "launch planned for September" then "launch moved to
October" ⇒ exactly one active record ("October"), one `.superseded` record
("September") with the supersede chain intact and provenance from both
conversations.

---

## Temporal memory

`MemoryLifetime`-style resolution in the extractor: short horizons
("today", "right now") → 1-day expiry; week horizons ("this week", "this
sprint") → 7 days; "this month" → 30 days; otherwise permanent.

`MemoryMaintenance.archivingExpired` runs at the top of every context build:
expired `active` records → `.archived`. `MemoryRecord.isRetrievable(now:)`
is the single gate ("active + enabled + not expired + not tombstoned"), so
an expired working-context memory can never reach a prompt — proven at both
the retriever and the builder level.

---

## Retrieval

`MemoryRetriever` scores each eligible record as a weighted sum of
independent components:

`semantic relevance` (lexical: `TextSimilarity` coverage/Jaccard over the
current message + recent context + entity tags) · `category prior` for the
surface · `recency` (30-day half-life decay) · `importance` ·
`userConfirmed` boost · `pinned` boost · `project-hint match` (hard) ·
`person-hint match` (hard).

**Guards that keep prompts clean:**

- scope filter (`global` always eligible; `personalChat`/`g2Replies` gated
  by surface),
- `rules` category is never retrieved (rules are injected unconditionally),
- a record with genuinely zero topical connection is dropped even if its
  importance/recency are high — importance alone never carries an unrelated
  memory into an unrelated prompt,
- everything below `minScore` is dropped, then top-K within the token
  budget.

Proven: an EvenAI question retrieves the EvenAI project memory and the
relevant archived conversation; "in Berlin this week" and an unrelated
second project ("garden renovation") are excluded.

---

## Personal AI context builder

`PersonalAIContextBuilding` — **the single personalization contract.**
`DefaultPersonalAIContextBuilder` pipeline:

```
load store → archive expired (MemoryMaintenance) → retrieve (MemoryRetriever)
  → resolve active rules (scope + priority sort) → detect current-message
  instruction → project style (StyleProfileLearner output) →
  render token-budgeted block (PersonalAIContextRenderer)
```

Output `PersonalAIContext`: `activeRules`, `relevantMemories`,
`relevantProjects`, `relevantPeople`, `historicalExcerpts`,
`styleInstructions`, `systemPromptText` (the compact block a model
consumes), `memoryDisabled`, and a **content-free** `buildTrace`.

The rendered block explicitly instructs: *use memory naturally, connect the
message to context, draw implications, ask a useful follow-up, do not
narrate memory use, and never reply with empty acknowledgements like "thanks
for sharing".*

Both surfaces call this exact type: Personal AI Chat via
`PersonalAIService.send`, the G2 seam via
`PersonalAIService.personalContext(for: .g2Replies, …)`. A contract test
proves both produce one `PersonalAIContextRequest` differing only by
`surface`.

---

## Style profile

`PersonalAIStyleProfile` dimensions: preferred language, response length,
directness, formality, technical depth, proactiveness, humor, formatting,
preferred vocabulary, phrases to avoid. Each dimension carries
`StyleDimensionMeta` (source, confidence, observation count).

`StyleProfileLearner`:

- **explicit directives** ("keep replies short", "use Ukrainian with me")
  → applied at full weight immediately, also written as a visible STYLE
  rule, and never overridden by later inferred signals.
- **inferred signals** (message length, formality markers) → accumulated;
  only allowed to move a projected dimension after **3 corroborating
  observations**. Proven: one terse message does not make the AI terse.

---

## Personal AI Chat

`PersonalAIChatView` + `PersonalAIService`. Always opens, retains history
(`LocalPersonalAIConversationStore`, its own store — separate from Glasses
Chat and AI Chat). Per turn:

1. apply memory commands in this message (explicit-instruction tier),
2. build context (`PersonalAIContextBuilding`),
3. generate (`PersonalAIModelProviding` — `OnDevicePersonalAIModelProvider`:
   Apple FoundationModels on-device, else the deterministic
   `HeuristicPersonalAIModelProvider` which still connects the message to
   retrieved project/person context and asks a real follow-up),
4. persist, then passively extract + merge durable memory (skipped when
   memory is off or the conversation is "do not remember").

Failure states are explicit and useful ("Personal AI model isn't available
— your memory is still being recorded"), never a crash, and the user's
message is never lost.

Text input only for Phase 1; the message/`PersonalAIChatMessage` shape and
the surface enum leave voice as an additive future change.

---

## Memory Center

`Settings → Personal AI → Memory`. Users can:

- browse all memories, filter by category, full-text search,
- see per-row category / confidence / pinned / confirmed / superseded /
  archived / expiring badges,
- open a memory to view provenance (source conversation & message counts,
  supersede chain, sync state, revision), edit its text/category,
  enable/disable, pin, confirm, or delete,
- view & add & enable/disable & delete **Rules** (with priority + scope),
- view the learned **Response Style** profile,
- manually add a memory or rule (both run `SecretDetector`),
- toggle **"Remember things from conversations"** globally,
- toggle **"Do Not Remember This Conversation"** from the chat.

---

## Local storage

`LocalPersonalMemoryStore` — an `actor` over one `PersonalMemoryDocument`
JSON file under Application Support (path injectable → tests use a temp
dir), same pattern as `LocalGlassesChatStore`. Atomic writes, best-effort,
never blocks a turn. `ownerID` namespaces the file.

**This is Phase 1 development storage, not the authoritative long-term
solution.** It is sync-ready by construction: every record already carries
`id` / `remoteID` / `revision` / `syncState` / `deletedAt`, deletes leave
tombstones, and `export()` / `replaceAll(with:)` already round-trip the
whole document — so the Phase 2 encrypted-cache + cloud-sync work is
additive, not a rewrite.

---

## Future G2 integration seam

- **The AI Conversation / G2 core is not modified at all.** No file under
  `App/AIConversationEngine.swift`, `Infrastructure/Voice`,
  `Infrastructure/Glasses`, `Features/Voice`, `Features/Glasses`, or
  `Features/Conversations` was touched. `AIConversationEngine` has zero
  reference to any Personal AI type (compile-time isolation).
- The seam is `PersonalAIService.personalContext(for: .g2Replies, message:,
  recentTurns:)` — a pure, cancellable read using the **same**
  `PersonalAIContextBuilding` contract as chat. It cannot delay
  translation, stop listening, or end a session, because nothing in the
  live pipeline calls it in Phase 1.
- Contract tests prove: (22) both surfaces use one builder/request type;
  (23) a fully-failing Personal AI running alongside a live
  `AIConversationEngine` session leaves translation and local suggested
  replies byte-for-byte unaffected; (24) the on-device model tier falls
  back to the heuristic tier and still returns a non-empty, context-using
  reply.
- The future pipeline (final turn → translate now → local reply now →
  `PersonalAIContextBuilder` → Personal AI model → improved replies if
  still relevant, newest-turn-wins) is documented; **activation is Phase
  2.**

---

## Security foundations

- `SecretDetector` gates every write path (extractor, command processor,
  manual add): OpenAI/Anthropic/GitHub/AWS/Google/Slack keys, bearer
  tokens, JWTs, PEM private-key blocks, SSH keys, "password is …"
  assignments, long hex blobs, card numbers → **rejected, never stored**.
- **No raw memory content in diagnostics.** All new `DiagnosticTrace` calls
  emit IDs / categories / counts / reason-labels only. Proven by a test
  that captures `stdout` during a full chat turn (including a secret) and
  asserts neither the memory content nor the secret appears.
- `ownerID` on every record + per-owner file namespacing — per-user
  isolation is an architecture fact now, not a retrofit.
- Personal AI memory storage shares no code, file, or key with
  `AuthTokenStore` / Keychain auth credentials.

---

## Phase 2 cloud design

See **`PHASE2_PERSONAL_AI_CLOUD.md`** — concrete design for: primary cloud
DB (Postgres or CloudKit private DB behind `CloudMemoryStore`), encrypted
local cache (SQLCipher / AES-GCM, key separate from auth), incremental sync
(push/pull on `revision` + `syncState`, tombstone precedence, conflict →
`MemoryMerger.reconcile`), version history, independent nightly snapshots,
export/restore, new-iPhone recovery, disaster recovery matrix, model
provider options (on-device / self-hosted / managed API — all behind
`PersonalAIModelProviding`), and hosting options (recommendation: CloudKit
private DB for Phase 2 v1). Every item maps to a seam that already exists.

---

## Phase 2 backup / restore design

Covered in `PHASE2_PERSONAL_AI_CLOUD.md` §5–§9: append-only
`memory_revisions` table for per-record undo; nightly server-side encrypted
snapshots to object storage (independent of the sync path); on-device
`export()` → encrypted `.pai` file via the share sheet; restore via
`replaceAll(with:)` or merge-import through `MemoryMerger`; new-iPhone
recovery from `CloudMemoryStore.snapshot()`; disaster-recovery matrix. All
expressible today against `PersonalMemoryDocument` / `PersonalMemoryStore`.

---

## Files changed

**Modified (2 existing files, minimal):**

- `EvenAI/App/EvenAIApp.swift` — construct + inject `PersonalAIService`
  (~6 lines; the `AIConversationEngine` construction block is untouched).
- `EvenAI/Features/Settings/Presentation/SettingsView.swift` — one new
  `Section` with a `NavigationLink` to `PersonalAIView`.

**New — Core (`EvenAI/Core/Domain/PersonalAI/`), 16 files:**
MemoryCategory, MemoryScope, PersonalAISurface, MemoryProvenance
(status/source/syncState/priority), MemoryRecord, Rule,
PersonalAIExchange, MemoryCommand, RetrievalQuery, PersonalAIStyleProfile,
PersonalAIContext, PersonalAIModelProviding, PersonalMemoryStore,
PersonalAIProtocols, PersonalMemoryDocument, PersonalAICloudSeams.

**New — Infrastructure (`EvenAI/Infrastructure/PersonalAI/`), 15 files:**
TextSimilarity, SecretDetector, CommandInterpreter,
HeuristicMemoryExtractor, MemoryMerger, MemoryRetriever (+ MemoryMaintenance),
StyleProfileLearner, DefaultPersonalAIContextBuilder,
PersonalAIContextRenderer, MemoryCommandProcessor,
OnDevicePersonalAIModelProvider, HeuristicPersonalAIModelProvider,
InMemoryPersonalMemoryStore, LocalPersonalMemoryStore,
LocalPersonalAIConversationStore.

**New — App, 2 files:** `App/PersonalAIService.swift`,
`App/DI/PersonalAIContainer.swift`.

**New — Features (`EvenAI/Features/PersonalAI/Presentation/`), 4 files:**
PersonalAIView, PersonalAIChatView, MemoryCenterView,
MemoryCenterDetailViews.

**New — Tests (`EvenAITests/PersonalAI/`), 13 suites + 1 test double:**
CommandInterpreterTests, HeuristicMemoryExtractorTests,
LocalPersonalMemoryStoreTests, MemoryMergerTests, MemoryRetrieverTests,
PersonalAIChatTests, PersonalAIContextBuilderTests,
PersonalAIG2SeamContractTests, PersonalAIProductionAuditTests,
PersonalAISecurityTests, RulePriorityTests, StyleProfileTests,
TemporalMemoryTests + `EvenAITests/TestDoubles/FakePersonalAIProviders.swift`.

**New — docs:** `PHASE1_PERSONAL_AI_REPORT.md`,
`PHASE2_PERSONAL_AI_CLOUD.md`.

`project.yml` unchanged (XcodeGen globs the directories).

---

## New test count

**70 new tests** across 13 suites (61 original + 9 added by the pre-commit
audit), covering all 26 required scenarios:

| # | Scenario | Suite |
|---|---|---|
| 1 | explicit remember → memory | CommandInterpreter |
| 2 | from-now-on → rule (+ update on repeat) | CommandInterpreter |
| 3 | forget → archives the right memory only | CommandInterpreter |
| 4 | rule outranks preference | RulePriority |
| 5 | current instruction overrides stored rule | RulePriority |
| 6 | duplicates merge | MemoryMerger |
| 7 | contradiction supersedes, one active fact | MemoryMerger |
| 8 | provenance preserved through merge | MemoryMerger |
| 9 | temporary memory expires | TemporalMemory |
| 10 | irrelevant memory excluded | MemoryRetriever |
| 11 | relevant project memory retrieved | MemoryRetriever |
| 12 | relevant person memory retrieved | MemoryRetriever |
| 13 | relevant historical conversation retrieved | MemoryRetriever |
| 14 | style influences context | StyleProfile |
| 15 | one message doesn't overfit style | StyleProfile |
| 16 | generic filler discouraged when context exists | PersonalAIContextBuilder |
| 17 | memory-disabled mode | PersonalAIChat |
| 18 | do-not-remember conversation | PersonalAIChat |
| 19 | secrets rejected from memory | PersonalAISecurity |
| 20 | raw memory absent from diagnostic logs | PersonalAISecurity |
| 21 | Personal AI Chat uses PersonalAIContextBuilding | PersonalAIChat |
| 22 | G2 seam uses the same contract | PersonalAIG2SeamContract |
| 23 | Personal AI failure cannot affect AI Conversation core | PersonalAIG2SeamContract |
| 24 | local fallback reply behavior intact | PersonalAIG2SeamContract |
| 25 | expired context never enters prompt | TemporalMemory + PersonalAIContextBuilder |
| 26 | unrelated project info doesn't pollute prompt | MemoryRetriever + PersonalAIContextBuilder |

Plus: local-store persistence / export-restore / owner namespacing /
tombstones / sync-field stability, extractor accept-reject matrix, token
budget trimming, priority-ladder totality.

---

## Full test result

_Updated after the pre-commit audit (see "Audit" section below): +9 audit
tests, +3 renderer/merger/extractor fixes._

- **New Personal AI suites:** **70/70 passing** (13 suites), covering all 26
  required scenarios plus production-storage and Phase-2-field audits.
- **Full unit suite excluding UI + soak** (`xcodebuild test`,
  `-skip-testing:EvenAIUITests -skip-testing:EvenAITests/AIConversationEngineSoakTests`):
  **552 tests in 76 suites passed, 0 failures** (53 s) — the 70 Personal AI
  tests plus every existing AI Conversation / G2 / Chat / Auth / translation
  / suggested-reply suite. **No regressions.**
- **`AIConversationEngineSoakTests`** run separately: **8/8 passed**
  (incl. the 100-turn deterministic soak test).
- **`EvenAIUITests`** run separately on a freshly-booted simulator:
  **3/3 passed.**
  → **combined total: 563 tests, 0 failures.**
- **Why the suites are run in separate `xcodebuild` invocations:** running
  the *entire* suite (unit + UI + soak) in one invocation crashes this
  machine's simulator mid-run with `Mach error -308 (server died)` —
  reproduced on the **pre-change baseline** too. It is a simulator-stability
  limit of this environment, not a regression or a test defect; every suite
  passes when the run is split (`build` → `build-for-testing` →
  `test-without-building` per suite).
- No Personal AI UI test was added to `EvenAIUITests`; the Personal AI views
  are covered by the app build, `PersonalAIChatTests`, the
  `PersonalAIProductionAuditTests`, and `MemoryCenterViewModel` logic.

---

## Backend changes: **NO**

No Railway, no `even-ai-assistant-asr` changes, no new endpoints, no deploy.
Phase 1 is entirely on-device.

## AI Conversation core changes: **NO**

`AIConversationEngine.swift`, `GlassesChatProvider.swift`,
`AgentContextStore.swift`, everything under `Infrastructure/Voice`,
`Infrastructure/Glasses`, `Features/Voice`, `Features/Glasses`,
`Features/Conversations` — **unchanged**. Translation stays local-first and
backend-independent. Local suggested-reply fallback is untouched. No
Personal AI code path can stop G2 audio capture, transcription,
translation, conversation history, or local replies.

---

## What works now

- A persistent single Personal AI identity with 10 memory categories +
  first-class rules, one store, one retrieval pipeline, one context builder.
- Personal AI Chat (Settings → Personal AI → Personal AI Chat): always
  opens, retains history, uses long-term memory, respects rules and style,
  connects a new message to relevant older context, avoids generic filler,
  degrades usefully when the on-device model is unavailable.
- Semantic commands ("remember…", "from now on…", "forget…", style
  directives) with no exact wording or slash commands.
- Memory extraction after each exchange with dedupe, contradiction-aware
  merging, provenance, and temporal expiry.
- Retrieval that pulls the right project/person/history and excludes
  unrelated material and expired working context.
- A style profile that respects explicit commands immediately and resists
  overfitting from a single message.
- Memory Center: full visibility and control (view / filter / search /
  edit / enable / disable / pin / confirm / delete / add / rules / style /
  global-disable / do-not-remember).
- Local sync-ready storage with working `export()` / `replaceAll(with:)`.
- An optional, contract-tested G2 personalization seam that cannot touch
  the proven pipeline.

## What still requires Phase 2 cloud

- Cross-device memory (sync engine, `CloudMemoryStore` conformer).
- Encryption at rest for the local store.
- Server-side snapshots / independent backups / disaster recovery
  execution.
- New-iPhone recovery from the cloud.
- Version-history / undo beyond the local `.superseded` chain.
- Activating Personal AI personalization in the live G2 reply pipeline.
- Voice input to Personal AI Chat.
- Any non-on-device model provider (self-hosted or managed API).
- Embedding-based semantic retrieval (Phase 1 is lexical; the seam is
  `TextSimilarity.semanticSimilarity`).

---

## Audit (pre-commit architecture / data-safety review)

**Verdict: PASS.** 4 minor defects found and fixed; no redesign; AI
Conversation core and backend untouched.

| # | Defect | Severity | Fix |
|---|---|---|---|
| 1 | On `.supersede`, the superseded record was written back without `.touched()` — `revision` / `updatedAt` / `syncState` didn't advance, so a Phase 2 revision-diff sync could miss the supersession of the *old* record. | Minor (Phase-2 compat) | `MemoryCommandProcessor.applyMerge` + `PersonalAIService.extractAndMerge` now `.touched()` the superseded record. New test `supersedeBumpsOldRecordRevision`. |
| 2 | The anti-generic-reply guidance was a trimmable prompt section — under a tight `tokenBudget` it could be dropped from `systemPromptText`, weakening the §6 guarantee. | Minor (§6) | `PersonalAIContextRenderer` now appends the guidance **after** the budget trim; it is never dropped. New test `guidanceSurvivesExtremeBudget`. |
| 3 | With global memory OFF, the renderer's early-return dropped active **rules** and the current-message **instruction** from the prompt — contradicting the builder's own comment and silently removing priority tiers 1–2. | Minor (§7 / §11) | Renderer keeps `currentInstruction` + rules + guidance when `memoryDisabled`; only *recalled* facts/style/excerpts are suppressed. New test `memoryOffKeepsRulesDropsRecall`. |
| 4 | After a `forget` / `from now on` / style command, the passive extractor could re-capture the command sentence itself as a memory (e.g. *"forget that I prefer espresso"* matched the *"I prefer …"* preference pattern). | Minor (data hygiene) | `HeuristicMemoryExtractor` now skips passive capture entirely when the message contains **any** recognised command. Caught by new test `commandFormsMapToStoreOps`. |

Also removed one unused private var (`PersonalAIService.generationTask`).

**Code changed during audit: YES** — 4 production files
(`PersonalAIContextRenderer.swift`, `MemoryCommandProcessor.swift`,
`HeuristicMemoryExtractor.swift`, `PersonalAIService.swift`), all localized
bug fixes, no interface changes. **AIConversationEngine / Voice / Glasses /
backend: still zero changes.**

Full audit findings are in the terminal audit report.

---

*Not committed. Not pushed. Nothing deployed.*
