# Personal AI — Cross‑Lingual Memory Retrieval Plan

**Status:** Prompt 1 / Slice 1 **implemented** (uncommitted, awaiting review). Prompt 2+ not started.
**Baseline:** built on `HEAD == origin/main == 53d9afa692bf74731ed922e7068c0de9c68b97b0` (`53d9afa`).
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
