# Phase 3 — Personal AI → G2 Integration · Implementation Report

**Local implementation + software tests only.** No infrastructure, no cloud, no
billing, no credentials, no commit, no push. Physical G2 testing is **not** run
and its results are **not** claimed.

- **Baseline:** `HEAD == origin/main == 9ba4d9919f7022731b927f02faab9b8525e52b0a`.
- **Approved plan:** `PHASE3_PERSONAL_AI_G2_PLAN.md`, **Option C**, starting
  tuning `~700` tokens / `~4 s`.
- **Result:** `LOCAL READY`. Full `EvenAITests` **857 / 857**; build +
  build-for-testing SUCCEEDED. `LOCAL READY` does **not** mean the G2
  behaviour is verified on hardware.

---

## 1. IMPLEMENTATION SUMMARY

Personal AI now enriches G2 suggested replies through **one new decorator**
that wraps the existing local reply generator behind the **unchanged**
`SuggestedReplyGenerating` protocol. `AIConversationEngine` is **not touched**
(`git diff` on it is empty). Every Personal AI failure mode — no memory,
memory disabled, retrieval slow/hung past the budget, account switch mid-build
— falls straight through to the existing local reply behaviour. Caller
cancellation (a newer utterance ending the turn) is surfaced, never converted
into a stale "successful" result.

**Net production change: 1 new file + 3 modified (+56 / −2 lines).**

---

## 2. FINAL ARCHITECTURE

```
finalized foreign-language ConversationTurn
        │
AIConversationEngine.generateSuggestedReplies(for:sequence:turnStartTime:)   ← UNCHANGED
        │  builds SuggestedReplyContext(recentTurns, contextItems)
        │  runs it in withThrowingTaskGroup racing repliesTimeout (15 s)
        ▼
   replyGenerator : SuggestedReplyGenerating          ← the only injection point
        │
   ┌────┴──────────────────────────────────────────────────────────────────────┐
   │ PersonalAIContextEnrichingSuggestedReplyGenerator            (NEW, struct) │
   │   try Task.checkCancellation()                                             │
   │   ownerAtStart = ownerID()                                                 │
   │   block = try? withEnrichmentTimeout(config.enrichmentTimeout) {           │
   │              await contextBuilder.buildContext(                            │
   │                 PersonalAIContextRequest(surface: .g2Replies,              │
   │                    userMessage: turn.originalText,                         │
   │                    recentConversation: recentTurns.suffix(4).originalText, │
   │                    conversationID: nil,                                    │
   │                    tokenBudget: config.contextTokenBudget)) }              │
   │   try Task.checkCancellation()                                             │
   │   guard ownerID() == ownerAtStart          else → base(plain)             │
   │   guard !ctx.memoryDisabled, ctx.hasPersonalization  else → base(plain)   │
   │   block = PersonalAIReplyContextRenderer.replyBlock(ctx, profile())        │
   │   guard !block.isEmpty                     else → base(plain)             │
   │   enriched = context ; enriched.personalAIContext = block                 │
   │   return try await base.generateReplies(for: turn, context: enriched)      │
   │                                                                           │
   │   catch is CancellationError → rethrow CancellationError (NO base call)    │
   │   catch (timeout / anything) → base.generateReplies(plain context)         │
   └────┬──────────────────────────────────────────────────────────────────────┘
        ▼
   LocalSuggestedReplyGenerator  (router struct — UNCHANGED)
      ├─ FoundationModelsReplyGenerator.prompt(for:context:)     +7 lines:
      │      if let p = context.personalAIContext, !p.isEmpty { lines = [p, ""] + lines }
      └─ LightweightLocalReplyGenerator  (UNCHANGED — ignores context.personalAIContext)
        ▼
   [SuggestedReply]  →  engine caps prefix(3)  →  engine `sequence` stale-gate  →  G2 pages
```

- `personalAI` (the `PersonalAIService`) and `liveTranslation` (the engine)
  still **never reference each other**. The decorator depends only on
  `any PersonalAIContextBuilding` + two `@Sendable` closures.
- **Single pass:** `base.generateReplies` is called **exactly once** per call
  (0 times only when the caller cancelled).

---

## 3. CALL / DATA FLOW

| Step | Input | Output | Owner | Concurrency |
|---|---|---|---|---|
| translation | turn | G2 pages | engine | independent task, first, never awaits anything below |
| base reply context | `agentContextStore.session` | `SuggestedReplyContext` | engine | sync at task start |
| **enrichment build** | `turn.originalText`, `recentTurns[-4]` text | `PersonalAIContext` \| timeout \| cancel | **decorator → `DefaultPersonalAIContextBuilder`** | one `await`, inside `withEnrichmentTimeout(4 s)`, inside the engine's 15 s `repliesTimeout` |
| context → block | `PersonalAIContext` + `ConversationProfile` | `String?` (≤ ~config budget + 2 sentences) | `PersonalAIReplyContextRenderer` | pure |
| generation | `turn`, `SuggestedReplyContext(+block?)` | `[SuggestedReply]` | base generator (FM → lightweight) | unchanged |
| cap + stale gate + publish | replies, `sequence` | G2 send / history-only | **engine (existing)** | `prefix(3)`, then `sequence >= highestDisplayedTurnSequence` |

Input types: `ConversationTurn`, `SuggestedReplyContext`. Output type:
`[SuggestedReply]` (unchanged). The decorator returns nothing the engine does
not already handle.

---

## 4. FALLBACK MODEL (Personal AI failure matrix)

Every row → the wrapped **base generator is called once with the un-enriched
`SuggestedReplyContext`** — behaviour byte-for-byte identical to before Phase 3
— except caller cancellation, which is re-thrown with **no** base call.

| # | Condition | Detected by | Result |
|---|---|---|---|
| 1 | relevant memory exists | `ctx.hasPersonalization` | **enriched** — block passed to the base prompt |
| 2 | no relevant memory | `!ctx.hasPersonalization` | base, plain |
| 3 | memory disabled | `ctx.memoryDisabled` (builder pre-checks `isMemoryEnabledGlobally`; no retrieval performed) | base, plain |
| 4 | Personal AI store unavailable / throws internally | `buildContext` is non-throwing → `.empty`-ish; also `withEnrichmentTimeout` | base, plain |
| 5 | retrieval failure | same | base, plain |
| 6 | context-builder failure | same / timeout | base, plain |
| 7 | enrichment timeout (`> config.enrichmentTimeout`) | `EnrichmentTimedOut` | base, plain |
| 8 | **caller cancellation** (newer utterance ends the turn / `stop()`) | `CancellationError` from `Task.checkCancellation()` or the timeout race's `Task.sleep` | **re-thrown** — engine treats as "cancelled", not "no replies", no publish, **0 base calls** |
| 9 | a newer utterance arrives (turn not itself cancelled) | — | enrichment for the old turn completes, replies generated + recorded in history, but the engine's `sequence` gate discards the **display** |
| 10 | account changes mid-build | `ownerID() != ownerAtStart` after the build | base, plain (cross-account enrichment discarded) |
| 11 | deleted / tombstoned memory | `DefaultPersonalAIContextBuilder` archives expired + reads the live store; a deleted record is not returned | not used; enriched-without-it or plain |
| 12 | malformed memory | retrieval reads whatever is in the store; nothing crashes | as 11 |
| 13 | cloud not configured | N/A — no cloud is consulted (`PersonalAIContainer.live` is `.notConfigured`) | normal |
| 14 | cloud offline | N/A | normal |
| 15 | R2 absent | N/A — the decorator has no R2 reference | normal |
| 16 | CloudKit absent | N/A — the decorator has no CloudKit reference | normal |

---

## 5. CONTEXT MODEL

- **What is retrieved:** `DefaultPersonalAIContextBuilder.buildContext(PersonalAIContextRequest(surface: .g2Replies, …))`
  — the **existing** Phase 1/2 pipeline: rules filtered by
  `Rule.isActive(now:surface:)`, memory via `MemoryRetriever` +
  `RetrievalQuery(surface: .g2Replies)`, style via `styleProfile()`, expired
  records archived first. **No second memory pipeline.**
- **What is passed to generation:** only `PersonalAIContext.systemPromptText`
  (already the retrieved, budgeted subset rendered by
  `PersonalAIContextRenderer`), wrapped by `PersonalAIReplyContextRenderer`
  with exactly two framing sentences + one `ConversationProfile` line. The
  decorator adds **no** memory content of its own.
- **Budget:** `PersonalAIContextRequest.tokenBudget = config.contextTokenBudget`
  (default **700**, vs 1200 for Chat). `PersonalAIContextRenderer` does the
  priority-aware, lowest-first trimming — reused unchanged.
  `budgetTrimsLowestFirst` pins the resulting block size; `configIsCentral`
  pins that `700` / `.seconds(4)` appear only in `PersonalAIReplyEnrichmentConfig.default`.

---

## 6. PRIORITY MODEL

Enforced entirely by the **existing** `PersonalAIContextRenderer` section
ordering — Phase 3 adds no re-ranking:

```
current-message instruction  >  active rules (by .priority)  >  relevant
project / people memory  >  other relevant preferences/facts  >  learned
style  >  (conversation excerpts, lowest)
```

`priorityOrderPreserved` asserts the rendered block places the
current-instruction section before the standing-rules section before the
style section.

---

## 7. CONCURRENCY / CANCELLATION / STALE PROTECTION

**Reuses the engine's existing mechanism. No parallel version system.**

| Concern | Mechanism |
|---|---|
| bind work to the current turn | the engine's per-turn `replyTask` (tracked in `turnTasks`); the decorator is stateless inside it |
| caller cancellation | `Task.checkCancellation()` at entry **and** after the build; `withEnrichmentTimeout` races `Task.sleep(timeout)` which throws `CancellationError` when the outer task is cancelled → propagated, never misread as a timeout. A cancelled call throws and makes **0** base calls. |
| enrichment budget | `withEnrichmentTimeout(config.enrichmentTimeout ≈ 4 s)` — strictly inside `repliesTimeout` (15 s); on timeout → `EnrichmentTimedOut` → base fallback. Never extends the reply budget, never touches translation. |
| stale display | the engine's `guard sequence >= highestDisplayedTurnSequence` in `generateSuggestedReplies` (unchanged). A superseded turn's enriched replies are generated + recorded in history but **not displayed**. Proven with the decorator wrapping `GatedSuggestedReplyGenerator` through the real engine (`staleEnrichedReplyNeverOverwrites`). |
| account switch | `ownerID()` snapshot at entry, re-checked after the build; a change → discard the enrichment, use the plain base. |
| memory-state change during a build | if `isMemoryEnabledGlobally` flips to `false` while a build runs, that build's result carries `memoryDisabled` iff the builder read it after the flip; the decorator's post-build `guard !ctx.memoryDisabled` then discards it. A build that already read `true` produces an enriched block — acceptable: it reflected the state at read time, is bounded, and is the same "was valid when computed" contract the rest of the pipeline uses. Documented; no stale *display* can result (engine gate). |

---

## 8. ACCOUNT ISOLATION

- The local Personal AI memory store is **single-instance-per-device** by the
  existing Phase 1/2 design — signing out keeps all local data, signing in
  resumes sync or triggers a restore; there is no per-account partition of
  local memory, and Phase 3 does **not** change that (`PersonalAIContainer` /
  `PersonalAIService` owner handling untouched).
- Phase 3 introduces **no cross-user retrieval surface:** the decorator holds
  no cache, reads only its injected `contextBuilder` (the one local store),
  and its `ownerID()` re-check prevents an in-flight enrichment from being
  applied across an owner change. `ownerIsolation` / `accountSwitchDiscardsEnrichment`.
- `.g2Replies`-surface scoping is real: `surfaceScopedRulesIsolated` proves a
  `.personalChat`-scoped rule never reaches the G2 enrichment while a
  `.g2Replies`-scoped and a `.global` one do.

---

## 9. PRIVACY BOUNDARY

**Allowed into the reply prompt:** only `PersonalAIContext.systemPromptText`
(the rendered, retrieved, budgeted subset) + two framing sentences + one
profile line.

**Never:** passwords / API tokens / private keys / auth credentials / cloud
secrets (Personal AI memory structurally does not store these), the full
memory archive (retrieval-gated + 700-token budget), unrelated memories,
cross-user data, raw `MemoryRecord`s, raw CloudKit records, raw R2 objects.

**G2 transport:** receives only the final `SuggestedReply` strings the engine
already renders. The decorator never touches the transport;
`outputIsOnlyFinalStrings` proves a memory string does not appear in the
returned replies; `transportUntouched` proves the Glasses code references no
Personal AI type.

**Logs:** the decorator emits `DiagnosticTrace.log("PERSONAL_AI_ENRICH", …)`
with **only** `turnID=<UUID>`, `reason=<errorTypeName>`, `blockTokens≈<int>`,
`reason=ownerChanged` — **no** memory text, **no** utterance text, **no**
owner id, **no** block content. (`DiagnosticTrace` is the codebase's existing
`print`-based anomaly trace; these additions match its established
content-free convention.) `PersonalAIContext.buildTrace` (documented "safe to
log") is the only Personal-AI-derived thing that could ever be logged, and the
decorator does not even log that.

---

## 10. LATENCY INVARIANTS

| Invariant | How it holds |
|---|---|
| translation never waits for Personal AI | translation runs in its own engine task, displayed before reply generation begins; the decorator is only reached from `generateSuggestedReplies`. `translationNeverWaitsForEnrichment` (base + builder both hung 10 s → translation still shown). |
| listening never waits for Personal AI | the transcriber pipeline is untouched; `listeningContinuesDuringEnrichment` (3 utterances finalized while enrichment lags 200 ms each). |
| the reply path cannot hang on Personal AI | `withEnrichmentTimeout(≈4 s)` bounds the build; `hungBuilderFallsBackToBaseReplies` (builder hung 30 s, 40 ms timeout → base replies reach G2). |
| the reply budget is not extended | `enrichmentTimeout (4 s) ≪ repliesTimeout (15 s)`, both centralised. |
| no measured-latency claims | none made. The decorator emits `PERSONAL_AI_ENRICH applied … blockTokens≈N`; combined with the engine's existing `LATENCY_TRACE REPLIES_LATENCY_MS`, a real-hardware run can compare enriched vs plain-fallback turns and re-tune `PersonalAIReplyEnrichmentConfig`. |

---

## 11. FILES CHANGED

### New production (1)

| File | Contents |
|---|---|
| `EvenAI/Infrastructure/PersonalAI/PersonalAIReplyEnrichment.swift` | `PersonalAIContextEnrichingSuggestedReplyGenerator` (decorator) · `PersonalAIReplyEnrichmentConfig` (the one tuning owner) · `PersonalAIReplyContextRenderer` (block framing + `ConversationProfile` guidance) · `withEnrichmentTimeout` + `EnrichmentTimedOut` |

### Modified production (3, +56 / −2)

| File | Change | Why unavoidable |
|---|---|---|
| `EvenAI/Core/Domain/SuggestedReplyGenerating.swift` | `+ SuggestedReplyContext.personalAIContext: String? = nil` + init param + doc | a generator needs a channel to receive the block; the type's own doc sanctions growing it; `nil` default keeps every call site source-compatible |
| `EvenAI/Infrastructure/Voice/LocalSuggestedReplyGenerator.swift` | `FoundationModelsReplyGenerator.prompt(for:context:)` prepends the block when present (+7 lines) | without it, enrichment has no effect on tier 1. **The `LocalSuggestedReplyGenerator` router struct is unchanged; `LightweightLocalReplyGenerator` is unchanged.** |
| `EvenAI/App/EvenAIApp.swift` | wraps `LocalSuggestedReplyGenerator()` in the decorator at the `replyGenerator:` argument; `+ resolveConversationProfile(defaults:)` helper | the composition change (Slice 3). The helper mirrors `resolveTranscriptionProviderMode` exactly — reads the engine's own persisted profile key read-only. |

### NOT modified

`AIConversationEngine.swift` (**empty diff**), `MentraGlassesTransport.swift`,
`GlassesChatProvider.swift`, translation (`AppleLanguageTranslator`),
transcription (`TranscriptionProviderRouter`, `GlassesSpeechTranscriber`,
`OpenAIRealtimeTranscriber`), microphone/audio, `NetworkSuggestedReplyGenerator`,
`NoOpSuggestedReplyGenerator`, `PersonalAIContainer`, `PersonalAIService`,
`project.yml`, signing, entitlements, backend, Railway, CloudKit, R2/Worker.

### Test (1 modified + 4 new — 31 new tests)

| File | Tests | Slice |
|---|---|---|
| `EvenAITests/TestDoubles/FakePersonalAIProviders.swift` | `+ ScriptedContextBuilder` | infra |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentTests.swift` | 10 | 1 + 4 |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentContextTests.swift` | 10 | 2 |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentCompositionTests.swift` | 7 | 3 |
| `EvenAITests/PersonalAI/PersonalAIG2ReplyEnrichmentEngineIntegrationTests.swift` | 4 | 4 |

---

## 12. SOFTWARE TEST EVIDENCE

| Scope | Result |
|---|---|
| `PersonalAIG2ReplyEnrichmentTests` (Slice 1/4 — decorator vs fakes) | **10 / 10** |
| `PersonalAIG2ReplyEnrichmentContextTests` (Slice 2 — real builder) | **10 / 10** |
| `PersonalAIG2ReplyEnrichmentCompositionTests` (Slice 3 — wiring) | **7 / 7** |
| `PersonalAIG2ReplyEnrichmentEngineIntegrationTests` (Slice 4 — through the engine) | **4 / 4** |
| `AIConversationEngineTests` + `…G2DisplayTests` + `…SuggestedRepliesTests` + `…SoakTests` | **green** (translation-before-replies 750/783, stale-reply G2Display 111/337, soak 264 all pass) |
| `LocalSuggestedReplyGeneratorTests` + `NetworkSuggestedReplyGeneratorTests` + `SuggestedRepliesLocalFirstTests` | **green** (127 combined with the above) |
| Personal AI suites (`PersonalAI/` + `PersonalAICloud/`) | **green** |
| **Full `EvenAITests`** | **107 suites / 857 tests / 857 passed / 0 failed / 0 skipped** |
| `xcodebuild build` | `** BUILD SUCCEEDED **` |
| `xcodebuild build-for-testing` | `** TEST BUILD SUCCEEDED **` |
| Worker vitest | **not run** — Phase 3 touches no Worker code (49/49 from Phase 2 stands) |

Baseline was 826 / 103; +31 Phase 3 tests, +4 suites. One transient
simulator "Failed to load test bundle" error occurred on a run overlapped
with a concurrent `xcodebuild build`; a clean isolated re-run passed
857 / 857 — the known environmental flakiness, not a code failure.

---

## 13. BUILD EVIDENCE

```
xcodebuild build            -scheme EvenAI -destination 'iOS Simulator, iPhone 17'  → ** BUILD SUCCEEDED **
xcodebuild build-for-testing -scheme EvenAI -destination 'iOS Simulator, iPhone 17'  → ** TEST BUILD SUCCEEDED **
```

No signing / entitlement change. `EvenAI.xcodeproj` regenerated by `xcodegen`
(gitignored).

---

## 14. PHYSICAL G2 TEST PLAN  (NOT RUN — for after software review)

| # | Scenario | Expected |
|---|---|---|
| 1 | Store `Remember I always decline meetings before 10am`. Have someone (via G2 live translation) invite you to an early meeting. | a suggested reply reflects the preference (e.g. offers a later time) |
| 2 | Toggle Personal AI memory OFF in the Memory Center; repeat 1. | ordinary local suggestions; the stored preference does not influence them |
| 3 | Speak phrase A, then phrase B within ~1 s. | each translation appears immediately; no A-derived suggestion is ever shown against B |
| 4 | Speak one sentence and watch the display. | translation renders before any reply; the reply (enriched or not) appears after, without holding the translation |
| 5 | Keep speaking while suggestions are being generated. | transcription/listening never pauses or drops a word |
| 6 | Set the Conversation profile; hold a 1-to-1 chat. | 2–3 concise, natural, personalised replies |
| 7 | Set the Meeting profile; hold a mock meeting. | concise professional replies / useful follow-up questions |
| 8 | With Apple Intelligence OFF (or an ineligible device). | suggestions still appear (lightweight templates); enrichment silently absent; nothing breaks |
| 9 | Sign out / switch account mid-session; keep talking. | no memory from the previous account appears; suggestions continue |
| 10 | Delete a previously-relevant memory in the Memory Center; speak the related phrase again. | it no longer influences suggestions |

**Also record for tuning:** filter the device console for `PERSONAL_AI_ENRICH`
and `LATENCY_TRACE`; compare `REPLIES_LATENCY_MS` on `applied` vs `fallback`
turns; adjust `PersonalAIReplyEnrichmentConfig` if enrichment adds meaningful
latency on real hardware.

---

## 15. KNOWN LIMITATIONS

1. **Lightweight tier gets no personalisation.** `LightweightLocalReplyGenerator`
   is a pure template lookup with no prompt; `context.personalAIContext` is
   ignored there. On a device with Apple Intelligence **off** (the current
   physical test device), enrichment is a **no-op** and the user sees the
   same templates as today. This preserves every invariant; a future slice
   could add style-biased template *selection* (plan §11 "Slice 2, optional").
2. **`.auto` conversation profile** uses the *stored* value, mapped to the
   conversation guidance; it does not consult the engine's runtime
   `effectiveDisplayProfile`. Revisit only if physical testing shows the
   difference matters (would require exposing a read-only accessor on the
   engine).
3. **Tuning values are unmeasured.** `700` / `4 s` are the plan's starting
   points; real numbers come from Slice-5 hardware traces.
4. **Physical G2 behaviour is not verified** — §14 is a plan, not evidence.
5. **Memory-state flip mid-build** can still produce one enriched block that
   reflected `memoryEnabled == true` at read time (bounded, never displayed
   stale). Documented in §7.

---

## 16. INVARIANT CHECKLIST (all 27 from the task)

| # | Invariant | Status |
|---|---|---|
| 1 | Translation never waits for Personal AI | ✅ separate task; `translationNeverWaitsForEnrichment` |
| 2 | Continuous listening never waits for Personal AI | ✅ transcriber untouched; `listeningContinuesDuringEnrichment` |
| 3 | Microphone path unchanged | ✅ zero audio-code diff |
| 4 | G2 transport unchanged | ✅ zero transport diff |
| 5 | Existing local replies remain a fallback | ✅ every failure → `base.generateReplies(plain)` |
| 6 | Personal AI failure cannot suppress replies | ✅ failure matrix §4 |
| 7 | Cloud-not-configured cannot suppress replies | ✅ `constructsFromLiveContainer` (`.notConfigured`) |
| 8 | Cloud-offline cannot suppress replies | ✅ no cloud consulted |
| 9 | No live CloudKit dependency | ✅ `decoratorHasNoCloudDependency` |
| 10 | No live R2 dependency | ✅ same |
| 11 | No backend / Railway dependency | ✅ same (`NetworkSuggestedReplyGenerator` not referenced) |
| 12 | Memory disabled → no retrieval | ✅ builder pre-checks; `memoryDisabledNoRetrieval` |
| 13 | Newer utterances invalidate/cancel older enrichment | ✅ engine cancels on `stop()`; on a newer turn the engine's `sequence` gate discards the stale display (unchanged design) |
| 14 | Stale result can NEVER overwrite a newer turn's replies | ✅ `staleEnrichedReplyNeverOverwrites` through the real engine |
| 15 | Account switch invalidates old Personal AI context | ✅ `ownerID()` re-check; `accountSwitchDiscardsEnrichment` |
| 16 | Deleted/tombstoned memories cannot be reused | ✅ `deletedMemoryExcluded` |
| 17 | No cross-user Personal AI retrieval | ✅ single local store + no cache + owner re-check; §8 |
| 18 | Priority: instruction > rule > memory > style > default | ✅ existing `PersonalAIContextRenderer`; `priorityOrderPreserved` |
| 19 | Do not dump the full memory store | ✅ retrieval-gated + 700-token budget |
| 20 | Only relevant, budgeted context influences replies | ✅ `budgetTrimsLowestFirst` |
| 21 | G2 receives only final suggestion strings | ✅ engine renders `[SuggestedReply]` only |
| 22 | Raw Personal AI memory blobs not sent to G2 | ✅ decorator never touches the transport; `outputIsOnlyFinalStrings` |
| 23 | Personal AI content not printed in unsafe production logs | ✅ decorator logs are content-free (turnID + reason + count) |
| 24 | Translation-before-replies tests remain green | ✅ `AIConversationEngineTests` 750/783 pass |
| 25 | Stale-reply protection tests remain green | ✅ `AIConversationEngineG2DisplayTests` 111/337 pass |
| 26 | Continuous-listening behaviour remains green | ✅ soak + integration tests pass |
| 27 | Shipping behaviour remains local-first | ✅ `PersonalAIContainer.live` `.notConfigured`; decorator has no cloud |

---

## 17. IS PHASE 3 SAFE TO COMMIT?

**YES** — additive, minimal (1 new file + 3 modified, +56/−2 production),
`AIConversationEngine` untouched, full suite 857/857 green, build + build-for-testing
succeed, no infrastructure / cloud / billing / credential, shipping default
local-first, protected state intact.

Caveat for the reviewer: this commits **Option C** in full (Slices 1–5) as one
workstream, not slice-by-slice. If the reviewer wants slice-by-slice commits,
the diff cleanly separates (`PersonalAIReplyEnrichment.swift` +
`SuggestedReplyGenerating.swift` = Slices 1–2; `LocalSuggestedReplyGenerator.swift`
+ `EvenAIApp.swift` = Slice 3; the 4 test files map to their slices).

## 18. IS PHYSICAL G2 TESTING NOW APPROPRIATE?

**YES** — the software layer is complete and green. §14 is the plan. Physical
testing should be done on a real iPhone + Even G2, ideally with Apple
Intelligence **on** for at least some scenarios (so enrichment actually
reaches tier 1), and the console filtered for `PERSONAL_AI_ENRICH` /
`LATENCY_TRACE` to gather the numbers that re-tune
`PersonalAIReplyEnrichmentConfig`.

**`LOCAL READY` — the G2 behaviour is NOT verified on hardware.**
