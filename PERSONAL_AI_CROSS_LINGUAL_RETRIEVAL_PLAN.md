# Personal AI — Cross‑Lingual Memory Retrieval Plan

**Status:** Prompt 1 / Slice 1 **shipped inert** in `9a3e125`. Prompt 2A (model-selection audit) done — see §21. Prompt 2B (benchmark) + integration not started; production still `NoSemanticScorer`.
**Baseline:** Prompt 1 committed as `9a3e125` on top of `53d9afa`. Prompt 2A audit performed against `HEAD == origin/main == 9a3e1251d401817313fb3adccf7da3cc579522ea` (no code change).
**Scope of this document:** read‑only architecture audit + implementation plan for making a memory stored in one language retrievable from a semantically equivalent query in another language (uk ↔ en ↔ de ↔ pl ↔ …).

---

## 0. Prompt 1 / Slice 1 — implementation status (uncommitted)

**Done — the additive, inert-by-default seam (plan §18 steps 1–5, §19):**

| Component | File | Notes |
|---|---|---|
| `SemanticMemoryScoring` protocol + `NoSemanticScorer` + `SemanticRelevance` (pure cosine + `blend = max(lexical, weight·semantic)`) | **new** `EvenAI/Core/Domain/PersonalAI/SemanticMemoryScoring.swift` | distinct protocol, not a reuse of `EmbeddingProviding` (deviation 1) |
| `EmbeddingVectorIndex` actor — derived, file-backed, per-owner, encrypted via the injected `DocumentFileStoring`; `vector(for:)`, `vectors(for:)`, `staleIDs(model:records:)`, `upsert`, `remove`, `pruneMissing(keeping:)`, `refreshStale(among:using:limit:)`, `rebuild(from:using:)` | **new** `EvenAI/Infrastructure/PersonalAI/EmbeddingVectorIndex.swift` | corrupt/missing file → treated empty; canonical memory never at risk |
| Hybrid blend in the retriever — additive optional `semantic: SemanticContext?` param (default `nil` ⇒ byte-identical to before); `Weights.semanticCrossLingual = 0.85` | **mod** `EvenAI/Infrastructure/PersonalAI/MemoryRetriever.swift` | `retrieve` stays synchronous & pure |
| Builder pre-step — additive optional `semanticScorer` / `vectorIndex` init params (default `nil`); guarded by the existing `!disabled && !conversationExcluded`; embeds the query, opportunistically re-embeds ≤32 stale candidates + prunes (the "lazy re-embed" — deviation 2); a 2 s internal budget so a hung/slow scorer can't stall Personal AI Chat | **mod** `EvenAI/Infrastructure/PersonalAI/DefaultPersonalAIContextBuilder.swift` | non-throwing preserved |
| Container wiring — constructs `EmbeddingVectorIndex(fileStore:)` + injects `NoSemanticScorer()` | **mod** `EvenAI/App/DI/PersonalAIContainer.swift` | **inert**: `modelIdentifier == "none"` ⇒ builder never embeds; Prompt 2 = one-line swap |

**Tests (all deterministic; scripted scorer stands in for the real model):**
`EvenAITests/PersonalAI/SemanticRelevanceTests.swift` (8), `EmbeddingVectorIndexTests.swift` (8), `CrossLingualRetrievalTests.swift` (18, **architectural**), `EvenAITests/TestDoubles/ScriptedSemanticScorer.swift`; +4 in `MemoryRetrieverTests`, +2 in `PersonalAIContextBuilderTests`. Focused 44/44, Personal AI group 113/113, full `EvenAITests` **929/929** (115 suites), `xcodebuild build` + `build-for-testing` green.

**Deviations from the written plan:**
1. Kept `SemanticMemoryScoring` a **separate** protocol (the plan allowed "or extend `EmbeddingProviding`"). Same method shape; avoids retrieval depending on the cloud/sync-flavoured `EmbeddingProviding`. A later consolidation is possible.
2. The "re-embed hook" is **lazy on the read path** (bounded `refreshStale` + `pruneMissing` inside `buildContext`), per plan §14's "lazy re-embed on retrieval touch," instead of touching `MemoryCommandProcessor` / `PersonalAIService`. No write-path file changed — smaller blast radius.
3. Added a **2 s internal semantic budget** in the builder (not in the written plan) so a slow/hung scorer falls back to lexical on the Personal AI Chat path too, not only the Phase 3 G2 path.

**NOT done — deferred to Prompt 2+ (unchanged from §18 step 6 / §19):**
- The real `MultilingualEmbeddingProvider` (Core ML multilingual sentence encoder + tokenizer + bundled asset + licensing + on-device validation).
- Flipping the container default from `NoSemanticScorer` to the real provider.
- Any real EN↔UK↔DE↔PL acceptance test (the `CrossLingualRetrievalTests` prove the *pipeline*, not a real model).
- Optional `QueryEmbeddingCache`.
- **The shipping app still does lexical-only retrieval** — cross-lingual is architecture-only at this point.

---

---

## 1. Current retrieval architecture

### 1.1 The production path (traced)

```
PersonalAIService.send(_:)                         ← Personal AI Chat
  └─ commandProcessor.process(...)                 (explicit commands, pre‑generation)
  └─ contextBuilder.buildContext(PersonalAIContextRequest(surface: .personalChat, …))
        │
PersonalAIContextEnrichingSuggestedReplyGenerator  ← G2 suggested replies (Phase 3)
  └─ withEnrichmentTimeout(.seconds(4)) {
        contextBuilder.buildContext(PersonalAIContextRequest(surface: .g2Replies, …))
     }  → on ANY failure/timeout/cancel: base.generateReplies(un‑enriched), exactly once
        │
        ▼
DefaultPersonalAIContextBuilder.buildContext(_:)   ← the ONLY PersonalAIContextBuilding impl
  1. isMemoryEnabledGlobally()      → disabled flag
  2. isConversationExcluded(id)     → conversationExcluded flag
  3. MemoryMaintenance.archivingExpired(...)         (expiry sweep)
  4. store.allRules().filter { isActive(now:surface:) }.sorted { $0.priority < $1.priority }
  5. currentInstruction  = CommandInterpreter.interpret(userMessage) → first rule/style
  6. RETRIEVAL  (only if !disabled && !conversationExcluded):
        RetrievalQuery(text:, recentContext:, surface:, projectHints:, personHints:, now:)
        MemoryRetriever().retrieve(query, from: liveRecords) -> [ScoredMemory]
        (retrieved records get lastUsedAt = now)
  7. profile = store.styleProfile()   →  renderStyle(profile)
  8. PersonalAIContextRenderer.render(...)  → token‑budgeted systemPromptText
        (sections emitted in priority order 0..3, trimmed lowest‑priority‑first)
  └─ returns PersonalAIContext { activeRules, relevantMemories, relevantProjects,
       relevantPeople, historicalExcerpts, styleInstructions, systemPromptText,
       memoryDisabled, buildTrace }
```

### 1.2 Retrieval / similarity ownership

| Concern | Owner | Shape |
|---|---|---|
| Ranking, `minScore` cut, `limit`, category priors, recency/importance/pinned, project/person hint boosts | `MemoryRetriever` (struct, `Sendable`) | **synchronous, pure**: `retrieve(_ q: RetrievalQuery, from: [MemoryRecord]) -> [ScoredMemory]` |
| Textual relevance signal | `TextSimilarity` (enum) | `semanticSimilarity`, `jaccard`, `coverage`, `tokens`, `stem`, `tokenSet` |
| Assembling the query, gating on enabled/excluded, expiry, rules, style, render | `DefaultPersonalAIContextBuilder` (struct) | `async`, **non‑throwing** |
| Section order + budget trim (priority enforcement) | `PersonalAIContextRenderer` (enum) | pure |

`DefaultPersonalAIContextBuilder.init(store:retriever:interpreter:)` already **accepts an injected `MemoryRetriever`**, but `PersonalAIContainer.make` constructs `DefaultPersonalAIContextBuilder(store: memoryStore)` with the default retriever. The Phase 3 decorator receives `PersonalAIContainer.live.contextBuilder` — the *same instance* — so any builder‑level change benefits G2 automatically.

### 1.3 What `TextSimilarity` actually does

`tokens(_:)` = `text.lowercased()` → split on `CharacterSet.alphanumerics.inverted` → drop a small **EN + UK** stopword set → `stem` (**ASCII‑only**; "Ukrainian tokens pass through unchanged") → keep tokens with `count > 1`.
`semanticSimilarity(a,b)` = `max(jaccard(a,b), 0.5·(coverage(a→b)+coverage(b→a))·0.9)` — i.e. **token‑set overlap**. Zero shared surface tokens ⇒ score `0`.

In `MemoryRetriever.retrieve`:
```swift
let semantic = max(semMain, 0.4 * semContext, semEntities)   // all TextSimilarity‑based
...
let hasTopicalConnection = semantic > 0.05 || projectHit || personHit
guard hasTopicalConnection else { return nil }               // record dropped
```

---

## 2. Root cause of language dependence

Relevance is **surface‑form token identity**. `"coffee"`, `"каву"`, `"Kaffee"`, `"kawę"` share **no tokens**, so:

- `semMain = TextSimilarity.semanticSimilarity("Яку каву мені замовити?", "Я віддаю перевагу еспресо без цукру.")` → `0`
- `semEntities` → `0` (entities are lowercased surface tokens too)
- `hasTopicalConnection == false` → the record is **filtered out before scoring completes** (`return nil`).

There is **no semantic vector layer and no translation layer** in the retrieval path. `EmbeddingProviding` exists as a *documented seam* with a single `NoEmbeddingProvider` (returns `[[]]`), wired **nowhere**. `MemoryRecord.embeddingModelVersion: String?` exists as staleness metadata; there is **no vector field and no vector index** anywhere in the codebase. `stem` deliberately never touches Cyrillic, so even morphological variants within Ukrainian (каву/кава/кавою) don't unify.

**This is a `MemoryRetriever` + `TextSimilarity` limitation. It is not a Phase 3 / cloud / engine issue.**

### Existing infrastructure — verified

| Question | Answer | Evidence |
|---|---|---|
| Embedding infrastructure exists? | **NO** | `EmbeddingProviding` protocol + `NoEmbeddingProvider` no‑op only; not referenced by the container, builder, retriever, or store. No vector storage. No index. |
| Local **multilingual** embedding capability verified? | **NO** | `FoundationModels` is used only for text generation (`LanguageModelSession.respond`) — no public embedding API. `NaturalLanguage` is imported but only `NLLanguageRecognizer` (detection) is used. `NLEmbedding` is per‑language (`sentenceEmbedding(for: NLLanguage)`), ships for a limited language set, and Apple does **not** provide a shared cross‑lingual space — unsuitable / unverified for uk↔en↔de↔pl matching. |
| Translation service reusable for retrieval? | **NO (not safely as‑is)** | `LanguageTranslating` / `AppleLanguageTranslator` is `@MainActor`, translates **only into Ukrainian** (`translateToUkrainian`), and needs a live `TranslationSession` vended **only** by SwiftUI `.translationTask` in `RootView`. It cannot run headless from a background retrieval path. `NLLanguageRecognizer`‑based **detection** *is* reusable headless. |
| Model/provider abstractions exist? | **YES (partial)** | `PersonalAIModelProviding` (generation, `OnDevicePersonalAIModelProvider` → FoundationModels → heuristic fallback). `EmbeddingProviding` (seam). `MemoryRetriever` is injectable into the builder. |
| Retrieval assumes synchronous/local deterministic scoring? | **YES** | `MemoryRetriever.retrieve` is a sync pure function. `buildContext` is already `async`, so an async *pre‑step* can be added at the builder without changing `PersonalAIContextBuilding`. |
| Embeddings treated as derived/rebuildable in Phase 2? | **YES** | `PersonalCloudProtocols.swift` "Embeddings (derived data only) … if the index or the vendor is lost, canonical memories are untouched and the index can be rebuilt". `PersonalCloudResilienceTests.embeddingLossIsHarmless` already asserts this. `PHASE1_PERSONAL_AI_REPORT.md` lists "Embedding‑based semantic retrieval" as deferred, seam = `TextSimilarity.semanticSimilarity`. |

---

## 3. Option A — Multilingual embedding retrieval

Memory → sentence embedding; query → sentence embedding; **cosine similarity** in a shared multilingual vector space (e.g. a distilled LaBSE / multilingual‑E5 / multilingual‑MiniLM converted to Core ML); rank memories by cosine, feed the existing `minScore`/`limit`/budget pipeline.

| Dimension | Assessment |
|---|---|
| Offline feasibility on iPhone | **Feasible, but requires bundling a 3rd‑party model asset** (Core ML `.mlmodelc` + tokenizer vocab). Int8‑quantised sentence encoders run ~30–120 MB. No first‑party multilingual sentence embedding exists. **No network at inference.** |
| Model / provider dependency | New **bundled ML asset + tokenizer** (not a service). Licensing must be checked (LaBSE/E5/MiniLM are typically Apache‑2.0/MIT — verify the exact checkpoint). |
| Privacy | **Excellent** — nothing leaves the device; `SecretDetector` still gates memory creation upstream. |
| Latency | One short‑text forward pass per **query** (ANE, tens of ms class — *not benchmarked here, validate in impl*). Cosine over N cached vectors is sub‑millisecond. Embedding every memory per query would be wasteful → **precompute + cache** per record. |
| Storage | 384–768 `float32`/record ≈ 1.5–3 KB; int8 ≈ 384–768 B. Hundreds–thousands of memories ⇒ negligible. **Separate derived index file**, not on `MemoryRecord`. |
| Index / rebuild | Derived. Rebuild on model‑version bump, on restore, on first launch post‑upgrade. `embeddingModelVersion` already exists for staleness. |
| New‑device restore | Vectors **excluded** from bundle/cloud → rebuilt locally. Canonical memory unaffected (already tested). |
| Deterministic testing | The real model is **not** unit‑test‑friendly → test against a **scripted `EmbeddingProviding`**; one gated integration test exercises the real model. Same pattern as `FakePersonalAIModelProvider`. |
| Language coverage | Whatever the checkpoint supports — LaBSE ≈ 109 languages; multilingual‑E5 ≈ 100. uk/en/de/pl trivially covered. |
| FoundationModels / existing seam can produce suitable embeddings? | **Not verified / not available.** Must bundle an external model. |

**Feasible: YES. Local‑first: YES (with a bundled asset).**

**Pros:** true any‑to‑any cross‑lingual matching; no per‑request network; no view‑layer coupling; no coupling to Live Translation; matches the codebase's existing "embeddings = derived data" model; a remote embedding API can later be a drop‑in alternate `EmbeddingProviding` for opt‑in users.
**Cons:** app‑binary‑size increase; Core ML model selection/conversion/tokenizer is real work; first‑index‑build latency; quality bounded by the checkpoint; a second, non‑deterministic test lane.

---

## 4. Option B — Translation‑normalized lexical retrieval

Detect the query language (`NLLanguageRecognizer`); if it isn't the canonical language, translate the query into the canonical language (say English) and run the **existing** lexical retrieval. Optionally also store, at write time, a canonical‑language mirror of each memory and lexical‑match against both original + mirror.

| Dimension | Assessment |
|---|---|
| Local translation availability | Apple `Translation` runs on‑device, **but** is only exposed via SwiftUI `.translationTask` (view‑bound `TranslationSession`), and our `LanguageTranslating` abstraction only goes **to Ukrainian**. A headless any‑to‑any translation service **does not exist** and building one on `Translation` fights the SwiftUI‑session constraint (would need an always‑mounted hidden translation host, or a different engine). |
| Latency | A translation call per query (or per memory at write time). `Translation` **downloads a language pack on first use of a pair** (multi‑MB, network) — violates strict offline for the first run of a new language pair. |
| Translation failure fallback | Fall back to raw lexical (current behavior) — safe. |
| Language detection | `NLLanguageRecognizer` — documented as unreliable for short/common phrases (see `AppleLanguageTranslator`), tolerable with a fallback. |
| Storage duplication | Canonical‑language mirror ≈ doubles stored content text (small). |
| Privacy | On‑device translation is private; the language‑pack download is the only network touch. |
| Correctness | Translation drift on short phrases and idioms; "espresso"↔"еспресо" fine, nuanced statements less so — lossy. |
| Coupling to Live Translation | **HIGH and undesirable** unless a clean, non‑view‑bound reusable language service is built first — which the task explicitly cautions against. |

**Feasible: PARTIALLY. Local‑first: NO (first‑use language‑pack download; view‑bound session).**

**Pros:** reuses the mature lexical scorer unchanged; no ML asset; conceptually simple.
**Cons:** the only on‑device translator is Ukrainian‑only and SwiftUI‑session‑bound; making it headless couples Personal AI to the protected translation pipeline; first‑use network dependency; detection unreliability; N² language‑pair surface.

---

## 5. Option C — Hybrid

1. Run the **existing lexical score** (same‑language, cheap, deterministic).
2. If the best lexical signal is below a confidence threshold (or the query/record share no tokens at all), invoke a **semantic layer** (`SemanticMemoryScoring` — impl = embeddings [A], or translation‑normalized [B], or a remote service later) for a cross‑lingual score.
3. **Merge:** `score = max(lexicalScore, w · semanticScore)` (or a weighted sum), then feed the **unchanged** ranking / `minScore` / `limit` / budget‑trim pipeline.
4. Semantic layer **absent / not‑ready / errors / times out** → step 1's result stands — i.e. **exactly today's behavior**.

Deterministic priority (`currentInstruction > rules > memory/preferences > style > default`) is applied *after* retrieval by `PersonalAIContextRenderer` and is **untouched**.

| Dimension | Assessment |
|---|---|
| Feasible | **YES** |
| Local‑first | **YES** — the lexical floor never needs anything; the semantic impl (Option A) is local |
| Complexity vs benefit | Moderate extra code (a scoring‑strategy seam + a vector cache), but it is the **only** option that structurally guarantees "the zero‑dependency lexical path is always the floor" while letting the semantic impl be swapped (fake in tests, embeddings in prod, remote later) |

**Pros:** no regression possible when the semantic layer is off/failing; incremental rollout (ship dark, enable when the model + tests land); testable deterministically; keeps `TextSimilarity` and the renderer frozen.
**Cons:** two scoring paths to reason about; a blend weight to tune; still needs Option A's model asset to actually deliver cross‑lingual results.

---

## 6. Recommended architecture

**Option C (hybrid), with the semantic layer implemented as Option A** (bundled multilingual sentence‑embedding behind an `EmbeddingProviding`‑style protocol), plus a **`NoSemanticScorer` default** so the feature ships inert until the model asset and its tests are in place.

```
DefaultPersonalAIContextBuilder.buildContext (async, non‑throwing)
  └─ if !disabled && !conversationExcluded:
       ├─ queryVector = try? await semantic.embedQuery(userMessage)      // cached; nil on any failure
       ├─ candidateVectors = vectorIndex.vectors(for: liveRecords.map(\.id))   // local file read
       └─ MemoryRetriever().retrieve(
              query,
              from: liveRecords,
              semantic: queryVector.map { qv in SemanticLookup(queryVector: qv, vector: { candidateVectors[$0] }) }
          )
              // retrieve() stays SYNCHRONOUS & PURE:
              //   let lexical = max(semMain, 0.4*semContext, semEntities)
              //   let sem = semantic?.cosine(for: record.id) ?? 0
              //   let signal = max(lexical, weights.semanticCrossLingual * sem)
              //   hasTopicalConnection = signal > 0.05 || projectHit || personHit
```

- `retrieve` remains synchronous and deterministic — the builder does the one `async` embed and hands `retrieve` a **pure vector lookup closure** + the query vector.
- `buildContext` stays **non‑throwing**: `try?` around the embed; on nil, semantic contribution is `0` and behavior is identical to today.
- Memory **disabled** → the builder returns before step 6, so **no query embedding and no vector lookup happen** (assert in tests).

---

## 7. Why it is preferred

- **Lexical stays the guaranteed floor.** Every protected contract (memory‑disabled, user isolation, tombstones, priority order, G2 fallback, offline, no cloud) is satisfied by construction because the semantic layer is *additive and optional*.
- **True any‑to‑any cross‑lingual** (uk↔en↔de↔pl and beyond) with **no per‑request network**, **no MainActor/view coupling**, **no coupling to the translation pipeline** the constraints protect.
- **Matches the codebase's existing mental model** — `EmbeddingProviding`, `embeddingModelVersion`, `NoEmbeddingProvider`, and `embeddingLossIsHarmless` already say "vectors are derived, rebuildable, never authoritative."
- **Incremental & reversible** — ship the seam with `NoSemanticScorer` (zero behavior change, fully green), then enable the real model behind asset‑presence detection.
- Translation‑normalization (B) is rejected as primary: the only on‑device translator is Ukrainian‑only and SwiftUI‑session‑bound; a remote embedding API is rejected as default per the no‑mandatory‑cloud rule.

---

## 8. Exact seam / interfaces to change (implementation — NOT now)

### New (production)
| File | Purpose |
|---|---|
| `EvenAI/Core/Domain/PersonalAI/SemanticMemoryScoring.swift` | `protocol SemanticMemoryScoring: Sendable { var modelIdentifier: String { get }; func embed(_ texts: [String]) async throws -> [[Float]] }` (or extend `EmbeddingProviding`); a pure `SemanticBlend.score(lexical:semantic:weight:)` helper; `NoSemanticScorer` (returns empty vectors — behavior identical to today). |
| `EvenAI/Infrastructure/PersonalAI/EmbeddingVectorIndex.swift` | `actor` — derived, file‑backed (mirrors `LocalPersonalMemoryStore`'s pattern: injectable directory + `DocumentFileStoring`, per‑owner filename). `vector(for: UUID) -> [Float]?`, `upsert(id:vector:modelVersion:)`, `pruneMissing(keeping: Set<UUID>)`, `staleIDs(currentModel:records:) -> [UUID]`, `rebuild(from: [MemoryRecord], using: SemanticMemoryScoring)`. Never in the cloud/backup bundle. |
| `EvenAI/Infrastructure/PersonalAI/MultilingualEmbeddingProvider.swift` | Core ML sentence encoder + tokenizer; `modelIdentifier = "st-multilingual-<name>-int8-v1"`; only selected when the asset is present, else `NoSemanticScorer`. |
| `EvenAI/Infrastructure/PersonalAI/QueryEmbeddingCache.swift` (optional) | LRU by text hash so repeated identical queries within a session don't re‑embed. |
| App bundle asset | `.mlmodelc` + tokenizer vocab (Prompt 2). |

### Modify (production)
| File | Change | Risk |
|---|---|---|
| `MemoryRetriever.swift` | add optional `semantic: SemanticLookup?` param to `retrieve`; blend `max(lexical, w·cosine)`; add `Weights.semanticCrossLingual`. **Signature‑compatible default** (`semantic: nil`). | Low — all existing call sites/tests compile unchanged. |
| `DefaultPersonalAIContextBuilder.swift` | add `semanticScorer`/`vectorIndex` (both optional, default nil) to `init`; add the async embed pre‑step guarded by `!disabled && !conversationExcluded`; `try?` everything. | Low‑med — additive; non‑throwing preserved. |
| `RetrievalQuery.swift` | optional `queryEmbedding: [Float]?` (or pass via the closure — prefer the closure, no struct change). | None if closure. |
| `PersonalAIContainer.swift` | construct `EmbeddingVectorIndex` + pick `MultilingualEmbeddingProvider` if asset present else `NoSemanticScorer`; inject into the builder; add a best‑effort background "embed new/edited records" hook. | Low — one construction site; Phase 3 decorator picks it up for free. |
| `MemoryCommandProcessor.swift` **or** `PersonalAIService.swift` | after a memory write/edit, enqueue a fire‑and‑forget `vectorIndex.upsert(...)`; after forget/tombstone, `vectorIndex` drop. Pick whichever touches the fewest lines. | Low — best‑effort, mirrors existing `persist()` fire‑and‑forget style. |
| `PersonalCloudProtocols.swift` (maybe) | extend `EmbeddingProviding` or add the sibling protocol. | Trivial. |

### New (tests)
`EvenAITests/PersonalAI/CrossLingualRetrievalTests.swift`, `EmbeddingVectorIndexTests.swift`, `SemanticBlendTests.swift`, `EvenAITests/TestDoubles/ScriptedSemanticScorer.swift`; extend `MemoryRetrieverTests`, `PersonalAIContextBuilderTests`, and add one gated `MultilingualEmbeddingProviderIntegrationTests` (real model, not in the deterministic lane).

---

## 9. Data model implications

- **Vectors live in a separate derived index file** (`personal-embeddings-<owner>.json` or compact binary), keyed by `MemoryRecord.id`, tagged with `modelIdentifier`. **Never** on `MemoryRecord`, **never** in `PersonalMemoryDocument`, **never** in `PersonalDataBundle` / cloud / R2 / backup.
- `MemoryRecord.embeddingModelVersion` (already present) = the record's staleness marker; set when a vector is (re)computed, compared against the provider's current `modelIdentifier`.
- **Invalidation:** `canonicalContent` edits bump `revision` via `touch()`; the index stores the `revision` it embedded and re‑embeds on mismatch. Delete/tombstone (`status == .deleted` / `deletedAt != nil` / `enabled == false`) → vector dropped / ignored.
- **Migration:** model‑version bump → all vectors stale → lazy re‑embed on next retrieval touch + a background sweep; until then those records fall back to lexical.
- **Account isolation:** per‑owner index file, namespaced exactly like `LocalPersonalMemoryStore` (`ownerID`). A retrieval for owner B never reads owner A's index. Covered by a dedicated test.
- **Backup/export/restore:** vectors excluded (derived). `importBundle(.replaceAll)` on a new iPhone → index rebuilt locally in the background. `embeddingLossIsHarmless` already encodes this guarantee.

---

## 10. Offline / local‑first behavior

- All embedding inference on‑device; model asset **bundled in the app** (no download).
- No network at query time or write time. No CloudKit / R2 / Worker / Railway dependency anywhere in the path.
- First launch after the feature ships (and after a restore): index builds in the background; **retrieval is lexical‑only until it's ready** — correct, just not yet cross‑lingual.
- A future remote embedding service is an **opt‑in alternate `SemanticMemoryScoring`**, never the default.

---

## 11. Fallback behavior

| Situation | Result |
|---|---|
| No semantic scorer wired (default until Prompt 2) | Identical to today — pure lexical. |
| Model asset absent on device | `NoSemanticScorer` selected → pure lexical. |
| Query embed throws / times out | `try?` → nil → semantic contribution 0 → pure lexical for that request. |
| Vector index missing/corrupt for a record | that record scored lexically only. |
| G2 path: whole `buildContext` slow | existing `withEnrichmentTimeout(.seconds(4))` → base replies, once (unchanged). |
| Personal AI Chat: builder slow | `buildContext` is already async and off the render path; no user‑visible stall beyond today's. |

**No semantic‑retrieval failure can break** Personal AI Chat, G2 suggested replies, translation, or listening — the lexical retriever and every downstream stage are untouched.

---

## 12. Privacy / security

- Strictly ≥ today: nothing leaves the device.
- `SecretDetector` still gates memory creation *before* anything is embedded — secrets never reach the index.
- **Memory disabled** → builder returns before retrieval → **query is not embedded, index is not read** (explicit test).
- Do‑Not‑Remember conversations already excluded upstream; their memories are never created, so never embedded.
- Index file encrypted at rest via the same `EncryptedDocumentFile` / `SymmetricKeyStore` the memory store uses (inject the same `fileStore`).
- Per‑owner isolation enforced at the file boundary.

---

## 13. Latency considerations

- **Per request:** embed the **query only** (one short‑text forward pass) + cosine over the candidate vectors already in RAM/file. Never embed all memories per query.
- **Caching / precomputation:** per‑record vectors precomputed at write time and on a background sweep; optional per‑session query‑text cache.
- **G2 budget:** bounded by the existing 4 s enrichment timeout; if the embed + lookup can't fit, the decorator already falls back to base replies. Validate the real budget during impl — **no invented numbers here.**
- **Index build:** amortised in the background; worst case is "cross‑lingual not available yet," never a stall.

---

## 14. Migration / rebuild

1. Ship seam with `NoSemanticScorer` — no index, no migration, no behavior change.
2. Enable `MultilingualEmbeddingProvider` (asset present) → on next launch a background task embeds all active records, writing the index + stamping `embeddingModelVersion`.
3. Model upgrade → `modelIdentifier` changes → stale detection → background re‑embed; lexical fallback in the meantime.
4. Restore / new device → index absent → rebuilt locally; canonical memory intact throughout.
5. Record edit → `revision` bump → single‑record re‑embed. Delete → vector dropped.

---

## 15. Test strategy

Deterministic lane uses `ScriptedSemanticScorer`: maps known strings to fixed vectors so that coffee‑domain phrases in uk/en/de/pl are near‑parallel and unrelated phrases orthogonal. Real model gets one **gated** integration test.

| # | Case | Layer / how |
|---|---|---|
| 1 | Ukrainian memory → Ukrainian query | `CrossLingualRetrievalTests` (also already covered lexically) |
| 2 | Ukrainian memory → English query | scripted scorer, builder‑level assert `relevantMemories` contains it |
| 3 | Ukrainian memory → German query | scripted scorer |
| 4 | Ukrainian memory → Polish query | scripted scorer |
| 5 | English memory → Ukrainian query | scripted scorer |
| 6 | German memory → English query | scripted scorer |
| 7 | Polish memory → Ukrainian query | scripted scorer |
| 8 | Unrelated cross‑language memory NOT selected | orthogonal scripted vector → below `minScore` |
| 9 | Multiple memories → correct one ranks first | scripted vectors with graded closeness |
| 10 | Active rule priority stays above retrieved memory | `PersonalAIContextRenderer` order unchanged — assert section order in `systemPromptText` |
| 11 | Memory disabled → NO semantic retrieval | spy scorer: `embed` call count == 0; `relevantMemories` empty; `memoryDisabled` true |
| 12 | Deleted / tombstoned memory excluded | forget via `MemoryCommandProcessor`, assert absent from retrieval + index drop |
| 13 | User A memory cannot surface for user B | two owners, two index files; retrieve as B → A's record absent |
| 14 | Semantic layer unavailable → lexical fallback | scorer = `NoSemanticScorer`; existing lexical expectations hold |
| 15 | Semantic layer timeout / failure → safe fallback | scorer throws / delays; `try?` path; pure lexical result |
| 16 | Query in an unsupported language → safe behavior | scorer returns low‑norm/zero vector → lexical only, no crash |
| 17 | Derived embedding rebuild / version behavior | `EmbeddingVectorIndexTests`: stale on `modelIdentifier` change, re‑embed, prune missing, drop on delete |
| 18 | G2 context builder receives correct cross‑lingual memory | `PersonalAIContextBuilderTests` with `surface: .g2Replies` + scripted scorer |
| 19 | Stale‑turn / Phase 3 behavior unchanged | run existing `PersonalAIG2ReplyEnrichment*Tests` unmodified — must stay green |
| 20 | Full existing EN/UK memory tests remain green | `CommandInterpreterTests`, `HeuristicMemoryExtractorTests`, `UkrainianMemoryCommandTests`, `PersonalAIContextBuilderTests`, full `EvenAITests` |

Plus: `xcodebuild build` + `build-for-testing` (production Swift changes).

---

## 16. Expected files to modify / add

**Modify (production):** `MemoryRetriever.swift`, `DefaultPersonalAIContextBuilder.swift`, `PersonalAIContainer.swift`, one of {`MemoryCommandProcessor.swift`, `PersonalAIService.swift`} for the re‑embed hook, optionally `RetrievalQuery.swift` + `PersonalCloudProtocols.swift`.
**Add (production):** `SemanticMemoryScoring.swift`, `EmbeddingVectorIndex.swift`, `MultilingualEmbeddingProvider.swift` (+ optional `QueryEmbeddingCache.swift`), Core ML asset + tokenizer (Prompt 2).
**Add (tests):** `CrossLingualRetrievalTests.swift`, `EmbeddingVectorIndexTests.swift`, `SemanticBlendTests.swift`, `TestDoubles/ScriptedSemanticScorer.swift`, extensions to `MemoryRetrieverTests` / `PersonalAIContextBuilderTests`, gated `MultilingualEmbeddingProviderIntegrationTests.swift`.
**Regenerate:** `xcodegen generate` (project file is gitignored).

---

## 17. Protected components — MUST NOT change

`TextSimilarity` · `PersonalAIContextRenderer` · priority ordering (`currentInstruction > rules > memory > style > default`) · `PersonalAIContextBuilding` / `PersonalAIContext` public shape · Phase 3 `PersonalAIReplyEnrichment*` · `AIConversationEngine` · translation pipeline / `AppleLanguageTranslator` / `LanguageTranslating` · G2 transport · glasses rendering · transcription · microphone / audio · CloudKit · R2 / Worker · backend / Railway · signing / entitlements · UI / navigation / localization / design · `MemoryMerger` (cross‑lingual dedupe explicitly out of scope) · `EvenAITests/ProductionEndpointContractTests.swift` · CloudKit Step 2 stash · `~/Desktop/cloudkit-step2.patch`.

---

## 18. Implementation sequence

1. `SemanticMemoryScoring` protocol + `NoSemanticScorer` + `SemanticBlend` helper + unit tests. **Zero behavior change** (scorer nil everywhere).
2. `ScriptedSemanticScorer` test double + `EmbeddingVectorIndex` actor + `EmbeddingVectorIndexTests`.
3. Wire optional `semantic` into `MemoryRetriever.retrieve` (guarded, default nil) + the builder's async embed pre‑step. Existing suites stay green with scorer nil.
4. `CrossLingualRetrievalTests` — the 20 cases against the scripted scorer.
5. Re‑embed hook (background best‑effort) + delete/tombstone drop + tests.
6. **(separate prompt)** `MultilingualEmbeddingProvider` — pick/convert a Core ML multilingual sentence encoder, bundle asset + tokenizer, verify licensing, real‑device validation, one gated integration test.
7. Container: default `NoSemanticScorer` until step 6 lands; then select the real provider when the asset is present.
8. Full regression: focused → Personal AI → full `EvenAITests` → `build` → `build-for-testing`. Diff review. Then commit.

---

## 19. Can this be implemented safely in one controlled prompt?

**NO — split into two.**

- **Prompt 1 (safe, single controlled session):** steps 1–5 — the `SemanticMemoryScoring` seam, `EmbeddingVectorIndex`, the hybrid blend in `MemoryRetriever`, the builder pre‑step, the re‑embed hook, and the full deterministic test suite (20 cases via `ScriptedSemanticScorer`). **Feature is inert by default** (`NoSemanticScorer`) — no model asset, no behavior change, fully deterministic, no regression risk. This is reviewable and commit‑ready on its own.
- **Prompt 2 (separate, its own review):** step 6 — real Core ML multilingual model selection/conversion, tokenizer, app‑size/licensing, on‑device validation, and flipping the container default. This carries model‑asset and binary‑size decisions that need explicit sign‑off and can't be validated purely deterministically.

---

## 20. Remaining limitations (after full implementation)

- Cross‑lingual quality is bounded by the chosen sentence‑encoder checkpoint; low‑resource languages and idioms weaker than uk/en/de/pl.
- `MemoryMerger` dedupe stays lexical — the *same fact* stated in two languages yields two records (acceptable; retrieval surfaces whichever matches the query).
- Very short queries (1–2 words) still carry little signal even with embeddings.
- First launch / post‑restore: a window where cross‑lingual retrieval is unavailable until the index builds.
- App binary size grows by the bundled model (tens–hundreds of MB depending on checkpoint/quantisation).
- `NLLanguageRecognizer` detection unreliability is avoided by the embedding approach (no routing on detection), but would resurface if Option B is ever added as an alternate scorer.
- On‑device compute: older eligible devices embed more slowly; the 4 s G2 budget may fall back to lexical on those until the query cache warms.

---

## 21. Prompt 2A — Multilingual Model Selection Audit

**Read‑only research, done against `9a3e125`. No model downloaded, no asset added, no Swift/project change.**

### 21.1 What a real `SemanticMemoryScoring` provider must supply (from the committed Prompt 1 code)

- `func embed(_ texts: [String]) async throws -> [[Float]]` — **batch**, order‑preserving, one vector per input. Empty array for an entry = "no vector" (caller stays lexical for it).
- `var modelIdentifier: String` — anything other than `"none"` activates the layer; it is stamped onto `EmbeddingVectorIndex.Entry.modelIdentifier`, and a change triggers a full derived‑index rebuild via `EmbeddingVectorIndex.rebuild(from:using:)`.
- **Dimension:** not fixed anywhere. `SemanticRelevance.cosine` only requires `a.count == b.count`, so every vector from one provider must share a dimension; the index stores whatever it is. Truncating a Matryoshka model is free.
- **Normalization:** **not required** — `SemanticRelevance.cosine` divides by both magnitudes itself. L2‑normalizing in the provider is still recommended (stable, and lets a future ANN index use dot‑product).
- **Symmetry:** the seam calls `embed([query])` and `embed([memoryContent])` on **separate** calls, so a provider *can* apply different prefixes/roles internally — but the current protocol carries no role flag. A prefix‑dependent model (E5) needs either a tiny protocol addition (`embed(_:role:)`) or a provider that assumes "memories = passage, single‑item query calls = query" (fragile). A prefix‑free model avoids this entirely.
- **Lazy init:** yes — the provider is only ever touched inside `DefaultPersonalAIContextBuilder.semanticContext(...)`, which is already `try?`‑guarded and wrapped in a 2 s budget; a slow first‑call model load just yields a lexical result that turn.
- **Caching / precompute:** `EmbeddingVectorIndex` already persists per‑record vectors (encrypted, per‑owner), re‑embeds lazily on `revision` change, prunes deleted records, and rebuilds on `modelIdentifier` change. Query‑only inference per request is the steady state.
- **Index/version:** `EmbeddingVectorIndex.Document.schemaVersion` (currently 1) + per‑entry `modelIdentifier` + `revision`. Changing the model can never corrupt `PersonalMemoryDocument` / canonical memory (proved by `PersonalCloudResilienceTests.embeddingLossIsHarmless` and `EmbeddingVectorIndexTests.corruptFileHarmless`).

### 21.2 Candidates evaluated

Legend: **[V]** verified this session with a cited source · **[K]** from model knowledge, confirm before integration · **[E]** estimated arithmetic (`vocab × dim × bytes` for embedding‑table‑dominated models; `params × bytes/param` otherwise), not measured.

| Model | Params | Emb dim | Tokenizer | Max len | Languages / UK | License | Prefixes | Notes |
|---|---|---|---|---|---|---|---|---|
| **`sentence-transformers/static-similarity-mrl-multilingual-v1`** | 0 "active" (token‑embedding averaging) **[V]** | 1024, MRL→512/256/128/64/32 (0.15–0.56% hit) **[V]** | BERT multilingual **uncased** WordPiece, 105 879 vocab **[V]** | n/a (bag of tokens) | 51 langs, **`uk` `de` `pl` `en` explicitly listed** **[V]** | **Apache‑2.0** **[V]** | none **[V]** | "**not intended for retrieval use cases**" (authors) **[V]**; ~92.3% STS / 86.5% classification *relative to* multilingual‑e5‑small **[V]** |
| **`intfloat/multilingual-e5-small`** | ~118M **[K]** | 384 **[V]** | XLM‑RoBERTa **SentencePiece** (`sentencepiece.bpe.model` ≈ 5 MB), 250 037 vocab **[V]** | 512 **[V]** | ~110, **`uk` `de` `pl` `en` explicitly listed** **[V]** | **MIT** **[V]** | **requires `query: ` / `passage: `** **[V]** (e5 technical report + community) | BertModel encoder, init from Multilingual‑MiniLM‑L12‑H384 **[V]**; e5 family is the multilingual STS/retrieval reference point |
| `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` | ~118M (0.1B) **[V]** | 384 **[V]** | XLM‑RoBERTa SentencePiece, 250 037 vocab **[K]** | 128 **[V]** | "50+" **[V]**; `uk` not listed in card, XLM‑R base covers it **[K]** | **Apache‑2.0** **[V]** | none **[V]** | mean pooling **[V]**; older (2021) sibling of e5‑small, same size, generally weaker multilingual retrieval **[K]** |
| `setu4993/LEALLA-small` (distilled LaBSE) | 69M **[V]** | 128 **[K]** | cased WordPiece, ~501k vocab (LaBSE vocab) **[K]** | 512 **[K]** | 109, `uk` via LaBSE set **[K]** | **Apache‑2.0** **[V]** | none | "**bi‑text retrieval**" oriented, L2‑norm recommended **[V]**; translation‑pair mining ≠ query↔fact relevance **[K]** |
| `sentence-transformers/LaBSE` | 500M **[V]** | 768 **[V]** | cased WordPiece, ~501k vocab **[K]** | 512 **[K]** | 109, `uk` **[V]** | **Apache‑2.0** **[V]** | none | general cross‑lingual semantic search **[V]**, but known‑weaker on monolingual STS vs e5/MiniLM **[K]**; size disqualifying |
| `google/embeddinggemma-300m` | 300M **[V]** | 768, MRL→512/256/128 **[V]** | Gemma **SentencePiece**, 262k vocab **[K]** | 2048 **[K]** | 100+, `uk` **[K]** | **Gemma Terms of Use** (open weights, commercial OK, prohibited‑use policy, must pass through terms + "Gemma" attribution) **[V]** | uses task prompts ("search result", "question answering", …) **[K]** | best‑in‑class small‑model quality **[V]**; community Core ML conversion exists **[V]**; heavy + license friction |

**Size estimates [E]** (asset added to the app bundle; embedding‑table‑dominated numbers assume the table is the whole cost):

| Model | fp16 | int8 | 4‑bit palettized / QAT‑int4 | + tokenizer file |
|---|---|---|---|---|
| static‑mrl‑ml **@1024** | ~217 MB | ~108 MB | ~54 MB | +~1.5 MB `vocab.txt` |
| static‑mrl‑ml **@256** (MRL slice) | **~54 MB** | **~27 MB** | ~14 MB | +~1.5 MB |
| static‑mrl‑ml **@128** (MRL slice) | ~27 MB | **~14 MB** | ~7 MB | +~1.5 MB |
| multilingual‑e5‑small | ~236 MB | ~118 MB | ~60 MB | +~5 MB `sentencepiece.bpe.model` |
| paraphrase‑multilingual‑MiniLM‑L12‑v2 | ~236 MB | ~118 MB | ~60 MB | +~5 MB |
| LEALLA‑small | ~138 MB | ~69 MB | ~35 MB | +~8 MB `vocab.txt` |
| LaBSE | ~940 MB | ~470 MB | ~240 MB | +~8 MB |
| embeddinggemma‑300m | ~600 MB | ~300 MB | ~150–200 MB (official QAT) | +~4 MB |

### 21.3 Rejected candidates + reason

- **LaBSE** — ~470 MB int8 asset for "rescue a cross‑language memory match" is indefensible against the product's size/RAM constraint; also optimised for translation‑pair mining, weaker on monolingual STS than e5/MiniLM.
- **EmbeddingGemma‑300m (as default)** — best quality, but even the official QAT build is ~150–200 MB, fp16 is ~600 MB, and the **Gemma Terms of Use** (not Apache/MIT) add redistribution obligations (pass‑through terms, prohibited‑use policy, "Gemma" naming). Keep as the *quality‑ceiling fallback* only if a small model measurably fails 2B acceptance.
- **paraphrase‑multilingual‑MiniLM‑L12‑v2 (as primary)** — same 118M size class as e5‑small with no size advantage, older, generally weaker multilingual retrieval, max‑len 128. Retain only as the *prefix‑free transformer* alternative if E5's `query:`/`passage:` handling proves annoying.
- **LEALLA‑small (as primary)** — attractive size (69M), but bi‑text‑mining objective (translation‑pair detection), not tuned for "is this fact relevant to this question", and a 500k cased WordPiece vocab. Secondary option if the static model underperforms and e5‑small is too big.

### 21.4 Shortlist

1. **`static-similarity-mrl-multilingual-v1` @ 256‑dim** — smallest by far, Apache‑2.0, prefix‑free, explicit uk/de/pl/en, **no Core ML needed**.
2. **`intfloat/multilingual-e5-small`** — the quality fallback; strongest small multilingual retriever, MIT, straightforward Core ML BERT‑encoder conversion; costs a `query:`/`passage:` handling wrinkle and ~60–120 MB.
3. `google/embeddinggemma-300m` (QAT) — only if 1 and 2 both fail acceptance.

### 21.5 Recommended model

> **`sentence-transformers/static-similarity-mrl-multilingual-v1`, Matryoshka‑truncated to 256 dimensions, shipped as an int8 (≈27 MB) or fp16 (≈54 MB) embedding matrix — pending the Prompt 2B quality gate.**
> If 2B shows it does not reliably rescue the acceptance queries, **fall back to `intfloat/multilingual-e5-small`** (Core ML, ~60 MB palettized, add `embed(_:role:)` to the seam).

**Why this model:**
- **Size/RAM** — the only candidate that fits comfortably inside a "don't grow the app for a retrieval nicety" budget (≤ ~55 MB, tunable down to ~14 MB at 128‑dim). RAM cost is a single memory‑mapped matrix, not a live transformer.
- **No Core ML, no attention ops, no conversion risk** — inference is: WordPiece‑tokenize → gather token rows → mean → L2‑norm. Implementable in ~200 lines of pure Swift over a `Data`/`mmap` Float16 blob. No `coremltools`, no unsupported‑op risk, no ANE eligibility questions, fully deterministic (helps testing).
- **License** — Apache‑2.0, clean for commercial redistribution inside the app bundle, no attribution string, no use‑policy pass‑through.
- **Coverage** — `uk`, `de`, `pl`, `en` are **explicitly** in the model's own language list; it was distilled with multilingual data into a shared space.
- **Task fit** — Personal AI memories are short declarative facts ("prefers espresso without sugar", "lives in Kyiv", "co‑founder is Andrii"). Cross‑lingual *concept overlap* on short sentences is what static multilingual embeddings do adequately, and the blend only needs the semantic layer to **rescue** matches the lexical layer missed (`max(lexical, 0.85·cosine)`) — it is not the primary ranker.
- **Deterministic** — a static lookup table gives identical vectors every run, so Prompt 2B's quality assertions and any future regression tests are stable.

**The real caveat (must be resolved in 2B):** the authors label this model *"not intended for retrieval use cases"* — it is tuned for symmetric STS, and there is a dedicated (English‑only) `static-retrieval-mrl-en-v1` sibling. Our use is closer to short‑sentence STS than classic passage retrieval, but this must be **measured** against the acceptance set before activation. If it fails, e5‑small is the proven retriever.

**Why not LaBSE:** ~470 MB int8, translation‑pair objective, weaker monolingual STS — fails the size constraint outright.
**Why not the other multilingual‑E5 sizes:** `multilingual-e5-base` (~278M) / `-large` (~560M) are far past budget; `-small` is the only one considered, and it sits behind the static model on size, ahead on quality — hence the fallback slot.
**Why not paraphrase‑multilingual‑MiniLM‑L12‑v2:** identical 118M size to e5‑small, older, weaker multilingual retrieval, 128‑token cap — no reason to pick it over e5‑small.

### 21.6 Verdicts

- **UK/EN/DE/PL shared semantic space expected:** YES — for both shortlist models (static‑mrl lists all four; e5‑small lists all four and is a proven cross‑lingual retriever). Quality *level* for `uk` specifically is **unverified** and is a 2B measurement.
- **Mandatory remote API:** NO. **Fully on‑device:** YES (both shortlist models run locally with no network).
- **Model license verified:** YES for the recommendation — `static-similarity-mrl-multilingual-v1` is **Apache‑2.0** (verified this session). **Redistribution risk:** LOW (Apache‑2.0, bundle the matrix + `vocab.txt`; include the license text in the app's acknowledgements).

### 21.7 Tokenizer implementation strategy

- **Recommended model:** BERT‑multilingual **uncased WordPiece**, 105 879 tokens. Ship `vocab.txt` (~1.5 MB). Implement a self‑contained `WordPieceTokenizer` in Swift (NFD normalize → strip accents / control chars per the "uncased" recipe → lowercase → whitespace + punctuation split → greedy longest‑match WordPiece with `##` continuation, `[UNK]` fallback). No `[CLS]`/`[SEP]` needed (mean pooling over content tokens only); no attention mask needed (bag of tokens); no token‑type IDs. **Tokenizer complexity: LOW.** Optionally use `swift-transformers` (1.0, has WordPiece) instead of hand‑rolling — but a ~200‑line dependency‑free tokenizer is preferable for this narrow use.
- **E5 fallback:** XLM‑RoBERTa **SentencePiece unigram**, 250 037 tokens. Ship `sentencepiece.bpe.model` (~5 MB) or the fast `tokenizer.json`. Needs `swift-transformers` `UnigramTokenizer` (available in 1.0; a recent release fixed its O(N²) → O(N) perf) or linking the C++ `sentencepiece` lib. Special tokens `<s>`/`</s>`, padding to batch max, real attention mask required. Plus the `query: ` / `passage: ` prefixes. **Tokenizer complexity: MEDIUM.**

### 21.8 Core ML conversion strategy

- **Recommended model:** **none required.** It is an embedding‑matrix lookup + mean + L2‑norm. Ship the matrix as a little‑endian Float16 (or int8 + scale) blob, `mmap` it, do the math with `Accelerate`/`vDSP`. This side‑steps every Core ML risk (unsupported ops, flexible shapes, ANE eligibility, `coremltools` version drift).
- **E5 fallback (if chosen):** `transformers` → `coremltools` on the BERT encoder only. Keep **tokenizer outside** the model (Swift). Keep **mean pooling + L2‑norm outside** the model (or fold pooling in with a fixed op; normalization trivially in Swift). Static input shape `[1, 128]` (pad/truncate to 128) plus a batched variant `[B, 128]`, or an enumerated‑shapes model. Precision: fp16 first; try `coremltools` 8‑bit **linear quantization** or **palettization (4‑bit)** on the 96M‑param embedding table (the bulk) and measure quality delta in 2B. ANE: BERT‑base‑H384 encoders generally place well on ANE but verify with `MLComputeUnits.all` and a coremltools performance report on a real device. **Conversion feasibility: HIGH** (well‑trodden path), but it is genuine work and adds `coremltools` to the build toolchain (not the app).

### 21.9 Quantization strategy

- **Recommended model:** ship **int8 rows + per‑matrix (or per‑row) scale** for ~27 MB @256‑dim, or **fp16** for ~54 MB @256‑dim with zero quality question. Compare int8 vs fp16 vs 128‑dim‑fp16 in 2B; pick the smallest that clears the quality gate.
- **E5 fallback:** fp16 baseline; then `coremltools` 8‑bit linear quant, then 4‑bit palettization of the embedding table, measuring precision@1 on the acceptance set at each step.

### 21.10 Model asset size

- **KNOWN:** the recommended model's on‑disk form at full 1024‑dim safetensors is ~434 MB fp32 **[E from 105 879 × 1024 × 4]**; HuggingFace reports the same order.
- **ESTIMATED (target if selected):** **≈27 MB (int8 @256‑dim)** or **≈54 MB (fp16 @256‑dim)**, + ~1.5 MB `vocab.txt`. **UNKNOWN until built:** exact bytes after MRL slicing + quantization + any container overhead.
- **Real‑device latency measured:** NO — nothing in this audit is benchmarked.

### 21.11 Prompt 2B benchmark plan (run after selecting one model, before any activation)

Add a **gated, non‑deterministic** integration target `MultilingualEmbeddingProviderBenchmark` (skipped in CI / normal runs; run manually on a real device). It must record, as **measured** data (never estimated):

| Metric | What to measure | Target (⚠️ = unverified target, to be confirmed/beaten) |
|---|---|---|
| Model asset size | bytes added to the `.ipa` (matrix + vocab) | ⚠️ ≤ 55 MB; strongly prefer ≤ 30 MB |
| Cold load | first `embed` call incl. `mmap` + vocab parse | ⚠️ < 300 ms |
| Warm query embed | one short sentence, model resident | ⚠️ < 50 ms (must leave headroom under the builder's **2 s** budget and the G2 **4 s** enrichment timeout — both already in code) |
| Batch memory embed | 32 short memories (the `refreshStale` limit) | ⚠️ < 1.0 s |
| Tokenizer only | tokenize one short sentence | ⚠️ < 5 ms |
| Peak extra RAM | during a 32‑item batch | ⚠️ < 80 MB resident |
| Device matrix | iPhone SE (3rd gen) / iPhone 12‑class ↔ current | all complete within budget; on failure/OOM the provider throws → builder already falls back to lexical (verified in `CrossLingualRetrievalTests`) |
| **Quality — acceptance queries** | stored UA "Віддає перевагу еспресо без цукру."; queries UA/EN/DE/PL "what coffee should I order?" equivalents | each retrieves the memory with `cosine ≥ 0.40` **and** an unrelated memory ("Runs 10k every Sunday.") scores below it |
| **Quality — labeled set** | ~24 hand‑labeled `(query, relevant‑memory, distractor)` triples spread across uk/en/de/pl and the 5 memory categories (preference / profile / project / person / rule) | precision@1 ⚠️ ≥ 0.80; no distractor within 0.05 cosine of the true match |
| Same‑language non‑regression | run the full existing `EvenAITests` with the real provider wired | 929/929 still green; lexical‑only cases unchanged |

The ⚠️ targets are **derived from the budgets already in the code** (2 s builder, 4 s G2) and reasonable mobile expectations — they are **not measurements** and 2B may revise them.

### 21.12 Acceptance criteria before shipping activation (flipping `PersonalAIContainer` off `NoSemanticScorer`)

1. 2B quality gate passed (acceptance queries + labeled‑set precision@1 ≥ target) **on the recommended model, on a real device**.
2. 2B latency: warm query embed + index lookup completes with ≥ 2× headroom under the 2 s builder budget on the oldest supported device.
3. Asset size signed off against the then‑current app‑size budget.
4. Full `EvenAITests` green with the real provider wired (same‑language behaviour unchanged; `semantic: nil` identity test still holds for the lexical path).
5. `modelIdentifier` string finalised (see §21.13) and `EmbeddingVectorIndex` rebuild‑on‑change verified end‑to‑end with a real re‑embed.
6. Fail‑open re‑verified with the real provider: model‑absent, model‑throws, model‑times‑out, memory‑disabled, tombstoned, wrong‑owner → all fall back to lexical, none leak.
7. License acknowledgement added to the app's open‑source notices.

### 21.13 Model versioning strategy

`modelIdentifier` becomes a compound, greppable string — any change forces `EmbeddingVectorIndex.rebuild` (derived data only; canonical memory untouched):

```
<model-slug>/d<dim>/<norm>/tok<tokver>/pp<preprocver>
e.g.  static-mrl-ml-v1/d256/l2/tokwp1/pp1
```

- `model-slug` — the checkpoint + our conversion revision.
- `d<dim>` — output dimension after MRL truncation.
- `<norm>` — `l2` or `raw`.
- `tok<n>` — tokenizer implementation version (vocab file + normalization recipe).
- `pp<n>` — text preprocessing version (casing, accent strip, any prefixes).

Also bump `EmbeddingVectorIndex.Document.schemaVersion` if the on‑disk entry shape changes. `MemoryRecord.embeddingModelVersion` mirrors `modelIdentifier` per record for staleness. **Nothing here touches `PersonalMemoryDocument`, sync, backup, or export** — vectors remain derived and rebuildable.

### 21.14 Remaining unknowns (all resolved by measurement in 2B, not by more research)

- Whether `static-similarity-mrl-multilingual-v1` clears the retrieval quality bar despite the authors' "not for retrieval" caveat — **the pivotal unknown**.
- Ukrainian‑specific cross‑lingual quality for either shortlist model (both list `uk`; neither publishes per‑language retrieval numbers for uk).
- Exact quantized asset size and any decode/`mmap` overhead.
- Real cold/warm latency and RAM on the oldest supported device.
- For the E5 fallback only: whether folding the `query:`/`passage:` distinction into the seam (`embed(_:role:)`) is worth the quality vs. picking a prefix‑free model.
- Whether 256‑dim is the right MRL cut or 128 suffices (smaller index, faster cosine).

