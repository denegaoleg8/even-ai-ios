# Phase 2 — Final Gate Review

**Review + documentation only.** This file makes no code, provider, deployment,
billing, or configuration change. It decides one thing: whether the Phase 2
*local* scope is complete enough to begin **Phase 3 — Personal AI → G2
Integration** locally, without pretending real off-device cloud durability is
production-ready.

- **Baseline:** `HEAD == origin/main == ce05bf4b02896198df2903745331455448af1c72`
  (`ce05bf4 Add R2 deployment readiness plan`).
- **Uncommitted at review time:** the recovery-key + versioned-namespace
  workstream just reviewed — 11 modified + 7 new files (see §"Files"), plus the
  pre-existing untracked `EvenAITests/ProductionEndpointContractTests.swift`
  (untouched). Nothing committed, nothing pushed.
- **Last verified:** full `EvenAITests` **826 / 826** (103 suites), Worker
  vitest **49 / 49** (5 files), `tsc --noEmit` clean, `xcodebuild build` +
  `build-for-testing` SUCCEEDED. This review changed no production or test
  code, so those results stand (verified: `git diff` unchanged from the
  reviewed workstream).

---

## 1. EXECUTIVE STATUS

**`LOCAL READY` — and `LOCAL READY` does NOT mean `REAL CLOUD PRODUCTION
VERIFIED`.**

- The **on-device** Personal AI memory system is real and live.
- The **software foundations** for cloud sync, a CloudKit adapter, an
  encrypted independent backup, a production-safe R2 authorization path, a
  recovery key, and a versioned object namespace are **implemented and tested
  locally** against deterministic in-memory / Miniflare fakes.
- **Zero** real off-device durability has been verified: no CloudKit
  container, no R2 bucket, no deployed Worker, no atomic replay store, no live
  identity provider, no real backup, no real restore, no real new-iPhone
  recovery. A shipping build wires **no cloud** (`PersonalAIContainer.live`
  reports `.notConfigured`).
- **Decision:** the Phase 2 *local* scope is **COMPLETE**. Phase 3 may begin
  **locally**. Real R2 / CloudKit deployment is **deferred** and is **not** a
  blocker for local Phase 3, because the architecture does not require either
  to operate. Real-infrastructure gates (A–N below, esp. C and N) remain open
  and gate a **separate** future deployment workstream.

---

## 2. LOCAL COMPLETION SUMMARY  (per category)

Status vocabulary: `COMPLETE LOCALLY` · `DESIGNED / TESTED LOCALLY` ·
`SHELVED / BLOCKED` · `REQUIRES REAL INFRASTRUCTURE` · `NOT STARTED` · `FAILED`.
Real-infrastructure status is **never** collapsed into local completion.

| # | Category | Status | Evidence |
|---|---|---|---|
| **A** | Local Personal AI memory | **COMPLETE LOCALLY** | `LocalPersonalMemoryStore`, `PersonalMemoryDocument`, retrieval, rules/priority, style, temporal, extraction — `EvenAITests/PersonalAI/*` 70 tests; live on device (copy #1) |
| **B** | Provider-independent cloud / sync architecture | **COMPLETE LOCALLY** (real providers: DESIGNED / TESTED LOCALLY) | `PersonalAISyncEngine`, `PersonalCloudService` seam, `PersonalCloudProviderIndependence` / `PersonalCloudIsolation` / `PersonalAISyncEngineTests`; `PersonalAIContainer.live` = `.notConfigured` |
| **C** | Local cache safety | **COMPLETE LOCALLY** | AES-256-GCM `EncryptedDocumentFile`, Keychain `…ThisDeviceOnly`; `EncryptedDocumentFileTests`, `PersonalCloudResilienceTests` |
| **D** | CloudKit adapter foundation | **DESIGNED / TESTED LOCALLY** | pure-Swift `CloudKit*` adapter + record mappers + error mapper + restore; `EvenAITests/PersonalAICloud/CloudKit*` (8 suites). **Step 2 (entitlements/container) = SHELVED / BLOCKED** — see §5 |
| **E** | R2 backup foundation | **COMPLETE LOCALLY** (foundation) | `BackupStore` / `R2BackupStore` / `CompositeBackupStore` / `LocalDirectoryBackupStore` (live) / `AESGCMBackupEncryption` / `EncryptedBackupEnvelope`; `BackupEncryptionTests`, `R2BackupStoreTests`, `BackupHardeningTests` |
| **F** | Production-safe R2 authorization path | **DESIGNED / TESTED LOCALLY** (client + Worker model) · **REQUIRES REAL INFRASTRUCTURE** to deploy | `BackupAuthorizationClient` (server-authoritative scope), `WorkerBackupCredentialProvider` (identity-bound), `R2ProductionBackupAdapter` (capability-gated composition), `RemoteBackupCompositionAuthority`; `cloudflare/backup-worker/` Worker + Miniflare tests; `R2ProductionPathSecurityTests` 35, `R2ProductionPathAuthorizationBypassTests` 12, `R2DeploymentContractTests` 11, Worker 49 |
| **G** | Recovery-key model | **DESIGNED / TESTED LOCALLY** · real new-iPhone restore **NOT VERIFIED** | `PersonalAIRecoveryKey` (256-bit KEK, versioned, checksum), `BackupKeyWrapping` / `"EAPB2"` wrapped envelope, `open(_:using:)`, `RecoveryKeyStore` seam; `PersonalAIRecoveryKeyTests` 18; `PHASE2_PERSONAL_AI_RECOVERY_KEY.md` |
| **H** | Versioned backup format / namespace | **COMPLETE LOCALLY** | `BackupObjectNamespace` (one definition, validating gen, non-guessing parser, unknown-version-fails-safe), `"EAPB1"`/`"EAPB2"` envelope digits, client + Worker prefix handling; `BackupObjectNamespaceTests` 13 + Worker `object-namespace.test.ts` 7 |
| **I** | Export / import / restore architecture | **COMPLETE LOCALLY** | `PersonalDataArchiveBuilder`, `StoredZipArchive`, `PersonalDataImporter` (validate-before-mutate), `PersonalAICloudRestoreCoordinator`, `PersonalAIBackupCoordinator` (verify-before-publish); `PersonalDataExportImportTests`, `PersonalCloudRestoreTests`, `PersonalDataRestorePreferenceTests` |
| **J** | Cross-user isolation | **COMPLETE LOCALLY** (tested) · live-bucket proof **REQUIRES REAL INFRASTRUCTURE** | salted `BackupOwnerTag` namespacing, server-derived owner tag, per-owner grant scope; `crossUserReadDenied`, `deleteIsolatedPerUser`, `accountDeletionScoped`, `serverIgnoresClaimedTag`, `crossOwnerV1GrantRefused`, `PersonalCloudIsolationTests` |
| **K** | Failure safety | **COMPLETE LOCALLY** | seal/put/verify/outage/corruption/truncation/expiry/replay/interrupted-upload paths all leave local cache byte-identical + prior verified backup recoverable; `BackupHardeningTests`, `outageNeverFailsLocalBackup`, `PersonalCloudResilienceTests` |
| **L** | Documentation / recovery plan | **COMPLETE LOCALLY** | `PHASE2_R2_PRODUCTION_PATH.md`, `PHASE2_R2_DEPLOYMENT_READINESS.md` (Gate A–N, cost gate, rollback), `PHASE2_PERSONAL_AI_RECOVERY_KEY.md`, `PHASE2_PERSONAL_AI_CLOUD_ROADMAP.md`, this file |
| **M** | Real CloudKit verification | **SHELVED / BLOCKED** | reason: no paid Apple Developer Program team. Step-2 patch stashed (`stash@{0}` / `7efa6d4…`) + `~/Desktop/cloudkit-step2.patch` (`a80809f7…`). No private-DB CRUD / sync / restore verified. |
| **N** | Real R2 / Worker verification | **REQUIRES REAL INFRASTRUCTURE + USER APPROVAL** | Gate C (create resources + billing) and Gate N (production enablement) need explicit sign-off. Nothing deployed, no bucket, no billing, no credentials. |

---

## 3. DEPLOYMENT GATES A–N

Source: `PHASE2_R2_DEPLOYMENT_READINESS.md` §16. **None may be marked complete
without real evidence.** All of D–N are downstream of user approval at C.

| Gate | Status | Why / Evidence | Blocker | User approval? |
|---|---|---|---|---|
| **A** — architecture reviewed + approved | **PENDING (this review is the input)** | §§2–14 of the readiness doc are written and internally consistent; local contract tests green. Awaiting explicit approval to treat the architecture as locked. | user has not yet approved the architecture | **YES** |
| **B** — current Cloudflare pricing re-verified | **NOT DONE** | The docs carry pricing marked *"MUST BE RE-VERIFIED FROM CURRENT CLOUDFLARE DOCUMENTATION BEFORE DEPLOYMENT"*. No fresh check performed (this review does no network access). | pricing not re-fetched; R2 rates, Workers Paid split, Durable-Object plan requirement, D1 free allocation all unverified for *today* | no (but feeds C) |
| **C** — user explicitly approves resource creation + billing | **NOT DONE** | The hard stop. No Cloudflare account resource, bucket, KV/D1/DO, Worker deploy, or billing may be created without this. | explicit user sign-off absent | **YES** |
| **D** — create R2 bucket; confirm `backup/v1/` | **NOT DONE** | `BackupObjectNamespace` already implements `backup/v1/` with cross-language tests; only bucket creation + a final "is this the form?" check remain. | blocked on C | via C |
| **E** — atomic idempotency store (D1 / Durable Object) + wire `idempotencyKey` | **NOT DONE** | `cloudflare/backup-worker/src/replay.ts` is a coarse, **non-atomic get-then-put** KV heuristic that **runs nowhere**. The `idempotencyKey` wire field is specified + format-tested (`idempotencyKeyFormatContract`) but **unwired**. **R4 is NOT solved.** | needs a real D1 table or Durable Object namespace + the additive Swift/Worker wire field | blocked on C |
| **F** — `wrangler deploy` to dev | **NOT DONE** | Worker source complete + Miniflare-tested; `ALLOW_DEV_IDENTITY` never enabled. | blocked on E | blocked on C |
| **G** — verified auth: real issuer + JWKS + opaque stable `sub`; prove `canonicalUserID == sub` | **NOT DONE** | `auth.ts` is a dev-only stub. `ownerTag v1` is byte-identical client↔Worker (9 shared vectors) — but against **fixtures**, not a real token subject. | **no live EvenAI identity provider** exists with an opaque stable `sub` + published JWKS | no (needs infra) |
| **H** — one disposable test backup end-to-end | **NOT DONE** | — | blocked on G | no |
| **I** — verify stored object is ciphertext-only | **NOT DONE** | Locally proven for the model (`serverSeesOnlyCiphertext`, `remoteCatalogCarriesNoPlaintextOrPII`); not against a real bucket. | blocked on H | no |
| **J** — restore the disposable backup onto a clean install | **NOT DONE** | Locally proven end-to-end through the fakes (`fullRoundTripThroughAuthorizer`). | blocked on H | no |
| **K** — cross-user security test against the live bucket | **NOT DONE** | Locally proven (§2 row J); not against a real bucket. | blocked on J | no |
| **L** — account-deletion test (live) | **NOT DONE** | Design in readiness §12; local proof `accountDeletionScoped`. | blocked on K | no |
| **M** — real new-device recovery on real hardware | **NOT DONE** | The recovery-key **mechanism** is implemented + unit-tested (wrong/corrupted/rotated key rejection, no key material remote, versioning). A **two-device round trip** (set up key → back up → lose device → restore from code alone) has never run. | needs a real backup target + two physical devices; also the recovery **UI** + `PersonalAIContainer.live` wiring (deferred) | no |
| **N** — production enablement explicitly approved | **NOT DONE** | — | user sign-off + Gates D–M green | **YES** |

**Currently known open items are exactly as stated in the task:** B (pricing),
C (approval), E (atomic replay), G (identity provider), M (real recovery), N
(approval). No gate is marked complete.

---

## 4. RECOVERY READINESS

**`LOCAL RECOVERY MECHANISM IMPLEMENTED` — `REAL NEW-IPHONE RECOVERY` NOT
`VERIFIED`.** These are separate and must stay separate.

| Claim | State | Evidence |
|---|---|---|
| A recovery key exists locally | **YES** | `PersonalAIRecoveryKey` — 256-bit `SymmetricKey`, `version = 1`, deterministic opaque `keyID`, checksum-protected `recoveryCode` (`EARK1-…` base32) + framed recovery file; `generatedKeyShape`, `recoveryCodeRoundTrip`, `serializationRoundTrip` |
| Wrong key fails safely | **YES** | `recoveryKeyMismatch` / `recoveryNotAvailable` / `openFailed` — typed, no plaintext, input untouched; `wrongRecoveryKeyFails`, `corruptedWrappedMaterialFails`, `failedRecoveryIsInert` |
| Recovery material is not exposed remotely | **YES** | envelope header carries only *wrapped* (AES-GCM) DEK copies + non-reversible `keyID` fingerprints; the sealed blob and the (unchanged) `BackupManifest` contain no raw key / `recoveryCode`; `headerCarriesNoKeyMaterial`, `remotePayloadCarriesNoRecoveryKey`, `manifestCarriesNoRecoveryKey`, `noKeyMaterialLogged` |
| Versioning exists | **YES** | `PersonalAIRecoveryKey.currentVersion`, `BackupKeyWrapping.version`, `"EAPB2"` envelope digit — independent of bundle schema; future version rejected not guessed (`unknownVersionRejected`) |
| `backup/v1` namespace exists | **YES** | `BackupObjectNamespace` (client) + `scope.ts` (Worker); `BackupObjectNamespaceTests` 13, `object-namespace.test.ts` 7; `R2BackupStore` uses it end-to-end |
| Real fresh-device restore is verified | **NO** | never run; Gate M. Needs a real backup target + two devices, plus the recovery UI + container wiring (deferred) |
| Cloud escrow is implemented | **NO** | explicitly **not** present. `RecoveryKeyStore` is a device-only convenience seam, not escrow. No iCloud-Keychain sync, no server recovery, no key-escrow service. |
| Rotation is honest | **YES** | slot `keyID` records which key opens a backup; a rotated key against a pre-rotation backup → `recoveryKeyMismatch`; the historical key still works; `rotationCompatibility` |

**Sufficient to start Phase 3 locally?** **YES.** Phase 3 does not touch the
backup / recovery path at all — it consumes the *local* Personal AI context
builder and memory store. The recovery mechanism being locally complete
removes it as a *conceptual* blocker to the durability story; its real-hardware
verification (Gate M) is deployment-workstream work, orthogonal to Phase 3.

---

## 5. CLOUDKIT STATUS

| Claim | State |
|---|---|
| CloudKit adapter foundation exists | **YES** — pure-Swift adapter, record ID / record mapper / error mapper / restore, provider-independence tests, 8 `CloudKit*` suites green |
| CloudKit Step 2 remains shelved | **YES** — `stash@{0}: On main: cloudkit-step2-apple-config-pending-paid-team`, commit `7efa6d4869353833e4ca02c6ae3baf315b0d9598`; `~/Desktop/cloudkit-step2.patch` md5 `a80809f705cf73ad24cdf513e41b673a` — both intact, untouched this review |
| Current local signing | **Personal Team / free provisioning** (no paid Apple Developer Program team available) |
| Paid Apple Developer Program status | **NOT independently portal-verified** in the prior check — treated as unavailable |
| Real CloudKit private-DB CRUD | **NOT VERIFIED** |
| Real CloudKit sync | **NOT VERIFIED** |
| Real new-iPhone CloudKit restore | **NOT VERIFIED** |

**Required to begin Phase 3 local integration?** **NO.**

**Architectural principle enforced:** *Phase 3 must not require live CloudKit
to operate.* `PersonalAIContainer.live` wires `cloudService = nil`,
`cloudEnvironment = .notConfigured`; the sync engine is inert
(`.skipped(.noCloudService)`); memory lives on-device only. Phase 3 reads the
local `contextBuilder` / `memoryStore` — no cloud call anywhere on that path.
CloudKit remains a **future `cloudService` swap in `PersonalAIContainer`
only**, unblocked when a paid Apple Developer team exists.

---

## 6. R2 STATUS

| Claim | State |
|---|---|
| Provider-independent backup foundation exists | **YES** |
| Production-safe client authorization composition exists | **YES** — `R2ProductionBackupAdapter.makeStore` is the sole path to a remote-capable store (`RemoteBackupCompositionAuthority` capability); `BackupAuthorizationClient` guard is unconditional |
| Owner-tag contract tested locally | **YES** — `ownerTag v1`, secret-free, byte-identical client↔Worker, 9 shared cross-language vectors |
| Recovery-key model exists locally | **YES** (§4) |
| `backup/v1` namespace exists locally | **YES** (§4) |
| Worker contract tests exist | **YES** — `cloudflare/backup-worker/` Miniflare suite, 49 tests, `tsc` clean |
| Real Worker deployed | **NO** |
| Real R2 bucket created | **NO** |
| Real atomic replay primitive deployed | **NO** — R4 not solved |
| Real identity provider wired | **NO** |
| Real off-device backup verified | **NO** |
| Real restore verified | **NO** |

**Required to begin Phase 3 local integration?** **NO.**

**Architectural principle enforced:** *Phase 3 must not require R2 to operate.*
R2 is copy **#3** (disaster-recovery only); it is never on the Personal AI read
path, never on the G2 path, and a shipping build cannot reach it
(`R2ProductionBackupAdapter.inert`, `DormantBackupObjectTransport`,
`NotConfiguredBackupCredentialProvider`). Phase 3 has **zero** R2 dependency.

---

## 7. PHASE 3 — GO / NO-GO

### Decision: **GO** — Phase 3 (Personal AI → G2 Integration) may begin **locally**.

**Why GO:**

1. The G2 seam **already exists and is contract-tested** — `PersonalAISurface.g2Replies`,
   the shared `PersonalAIContextRequest` type, `RetrievalQuery.surface`,
   `Rule.isActive(surface:)`, `MemoryScope.appliesTo(surface:)`,
   `PersonalAIG2SeamContractTests` (Scenario 22: "same contract both
   surfaces", "cannot touch the AI Conversation core").
2. `AIConversationEngine` reply generation is **already** optional, bounded
   (`repliesTimeout`), cancellable (`CancellationError` handled), and
   stale-safe (sequence comparison before any G2 display update) — a thrown
   error is already treated as "no replies this turn", never a session
   failure. The translation is emitted independently and first.
3. The production reply generator (`LocalSuggestedReplyGenerator`) is **fully
   local**, two-tier (FoundationModels → `LightweightLocalReplyGenerator`),
   with **no cloud tier and no automatic Railway fallback** — by explicit
   design.
4. `PersonalAIContainer.live` is `.notConfigured`; the local context builder
   and memory store need no cloud.
5. Neither CloudKit nor R2 is on any critical path; both are deferrable.

### NO-GO conditions (must all remain false to proceed / continue)

- Phase 3 work modifies `AIConversationEngine` translation/listening timing or
  the G2 microphone path without an explicit, separately-approved reason.
- Personal AI context becomes a **precondition** for a suggested reply (rather
  than an optional enrichment).
- Any Phase 3 path introduces a synchronous or blocking dependency on
  CloudKit, R2, or the Railway backend.
- Personal AI retrieval is not cancellable / not stale-rejecting on a newer
  utterance.
- `memoryDisabled` / `MemoryScope` / active rules / account identity are not
  honoured on the G2 path.
- Cross-user memory retrieval becomes possible.

If any NO-GO condition becomes true during Phase 3 → **stop and re-review.**

---

## 8. NARROWEST PHASE 3 INTEGRATION SEAM

```
finalized foreign-language ConversationTurn
        │
AIConversationEngine.generateSuggestedReplies(for:sequence:turnStartTime:)
        │  builds SuggestedReplyContext (recentTurns, contextItems)   ← unchanged
        ▼
   replyGenerator: SuggestedReplyGenerating           ← the ONLY injection point that changes
        │
   ┌────┴─────────────────────────────────────────────┐
   │  NEW: PersonalAIEnrichedReplyGenerator (decorator) │
   │   1. build PersonalAIContextRequest(surface: .g2Replies, …)         │
   │      from the turn + recentTurns, via PersonalAIContextBuilding      │
   │   2. fold the resulting PersonalAIContext into the context           │
   │      (additive field on SuggestedReplyContext — the protocol's       │
   │       own doc sanctions growing this type without a signature change)│
   │   3. delegate to the wrapped LocalSuggestedReplyGenerator            │
   │   • context build fails / times out / memory off  → skip step 1–2,   │
   │     still generate plain local replies                              │
   └────┬─────────────────────────────────────────────┘
        ▼
   LocalSuggestedReplyGenerator (FoundationModels → Lightweight)   ← unchanged
```

- **One wiring change** (`EvenAIApp` / the composition root: wrap
  `LocalSuggestedReplyGenerator` in the new decorator). `AIConversationEngine`,
  `LocalSuggestedReplyGenerator`, the G2 transport, and the translation path
  are **not touched**.
- **Additive only** to `SuggestedReplyContext` (a `personalAIContext:
  PersonalAIContext?` field) — every existing call site is source-compatible.
- The Personal AI layer is **advisory / contextual only**. It is *not*, and
  must never become: the transcription owner, the translation owner, the
  microphone owner, the glasses-rendering owner, a cloud-sync dependency, or a
  mandatory precondition for replies.
- The decorator owns its own timeout + cancellation for the context build,
  *inside* the engine's existing outer `repliesTimeout` — so a slow retrieval
  can never extend the reply budget the engine already enforces.

---

## 9. PERFORMANCE / LATENCY CONSTRAINTS

No new millisecond figures are invented here — none have been measured on real
hardware for this path (see ROADMAP "Known gaps": live Simulator/device
profiling still outstanding).

| Constraint | Mechanism |
|---|---|
| Translation rendering is independent of Personal AI | `AIConversationEngine` emits the turn's translation before, and regardless of, reply generation — existing behaviour, must be preserved |
| Personal AI context may enrich replies **after** translation | the decorator runs inside `generateSuggestedReplies`, which is already downstream of the translation emit |
| Cancellation on a newer utterance | the engine already cancels the replies task and rejects stale results via sequence comparison; the decorator's context build inherits that cancellation (it is `async` and cooperative) |
| Stale-result rejection | unchanged — the engine's sequence check gates the G2 *display* update; a late context build that lost the race produces replies that are simply never shown |
| Local retrieval timeout / budget | the decorator wraps the context build in its own bound, **strictly shorter** than `AIConversationEngine.repliesTimeout`, so enrichment can time out and fall through without eating the reply budget |
| Fallback to lightweight local replies | context-build failure/timeout/`memoryDisabled` → the decorator calls the wrapped generator with the un-enriched context; `LocalSuggestedReplyGenerator`'s tier-2 `LightweightLocalReplyGenerator` needs nothing beyond the phone |

**Hard rule:** Personal AI retrieval must not delay translation, and must not
delay replies beyond the budget the engine already enforces.

---

## 10. PRIVACY / MEMORY CONSTRAINTS

Phase 3 must respect, on the `.g2Replies` surface, exactly what Personal AI
Chat already respects:

| Control | Enforcement point (already exists) |
|---|---|
| Memory enabled / disabled | `store.isMemoryEnabledGlobally()` → `PersonalAIContext.memoryDisabled`; the decorator must skip enrichment when disabled |
| Active rules | `Rule.isActive(now:surface:)` — surface-parameterised |
| Instruction priority | `PersonalAIPriority` ordering in `DefaultPersonalAIContextBuilder` |
| User-selected conversation profile | `PersonalAIContextRequest.conversationID` + project/person hints |
| Deletion / tombstone semantics | retrieval reads the live store; a deleted / tombstoned memory is not returned |
| Account identity | `LocalPersonalDataStore(ownerID:)` / `PersonalOwnerBox`; a Phase 3 account switch must invalidate any cached G2 context |
| No cross-user retrieval | store is per-owner; retrieval never crosses `ownerID` |
| No secret / token storage | Personal AI stores facts/preferences only — structurally no credentials (`noSecretsInBackup`) |
| No leaking Personal AI content to G2 beyond what is intentionally rendered | the decorator passes context **only** to the reply generator; it never sends memory text to the glasses transport — only the generated reply strings the user already sees are rendered |
| `MemoryScope` per surface | `MemoryScope.appliesTo(surface: .g2Replies)` gates which memories are eligible |

---

## 11. PHASE 3 TEST PLAN  (drafted — not implemented in this review)

To be written **before** Phase 3 implementation:

| # | Test | Asserts |
|---|---|---|
| 1 | Personal AI context enriches G2 suggestions | with relevant memory, the enriched generator produces replies that reflect it |
| 2 | no memory → existing local replies still work | empty store → `LightweightLocalReplyGenerator` output unchanged from today |
| 3 | memory disabled → no retrieval | `isMemoryEnabledGlobally() == false` → decorator does not call the context builder |
| 4 | cloud unavailable → no regression | `PersonalAIContainer.live` (`.notConfigured`) → replies identical to the un-enriched path |
| 5 | stale retrieval cannot overwrite a newer reply set | a slow context build for turn N completing after turn N+1 displayed → N's replies never reach the G2 display |
| 6 | translation appears before Personal AI enrichment | turn translation is emitted with no dependency on the reply/enrichment task |
| 7 | continuous listening never stops | the transcriber / mic pipeline runs unaffected while enrichment is in flight or failing |
| 8 | account switch invalidates Personal AI context | owner change → any cached G2 context is dropped; next turn rebuilds under the new owner |
| 9 | deleted memory not reused | delete a memory mid-session → it does not appear in a subsequent G2 enrichment |
| 10 | rules influence replies appropriately | an active `.g2Replies`-scoped rule changes the enriched output; an inactive/other-surface rule does not |
| 11 | no cross-user memory leakage | user A's memory never appears in user B's G2 enrichment |
| 12 | performance path remains non-blocking | context-build timeout → replies still returned within the engine's `repliesTimeout`; translation latency unchanged |
| 13 | decorator failure is invisible | context builder throws → wrapped generator still called; engine sees normal replies |
| 14 | no backend/Railway dependency reintroduced | source scan: the Phase 3 seam imports no networking / `AuthenticatedAPIClient` / backend types |

---

## 12. DEPLOYMENT WORK DEFERRED (a separate future workstream)

Not Phase 3. Ordered, each gated on the one before, C and N on explicit user
approval:

1. **Gate B** — re-verify current Cloudflare pricing / free-tier limits.
2. **Gate C** — user approves creating Cloudflare resources + billing.
3. **Gate D** — create the R2 bucket; confirm `backup/v1/`.
4. **Gate E** — stand up an **atomic** idempotency store (D1 / Durable
   Object); wire the `idempotencyKey` field (Swift + Worker). **Solves R4.**
5. **Gate F** — `wrangler deploy` to a dev environment.
6. **Gate G** — wire a real verified identity provider (opaque stable `sub` +
   JWKS); prove `canonicalUserID == sub`.
7. **Gates H–L** — disposable backup, ciphertext-only check, restore,
   cross-user, account-deletion — all against the real dev bucket.
8. **Gate M** — real new-iPhone recovery on two physical devices; also build
   the recovery **UI** and wire `PersonalAIRecoveryKey` into
   `PersonalAIContainer.live`.
9. **Gate N** — user approves production enablement; cohort rollout.
10. **CloudKit** — enable when a paid Apple Developer Program team is
    available; unstash `cloudkit-step2`.

R3 (a presigned URL is a short-lived bearer capability) is **inherent** and
stays documented, not "fixed".

---

## EXPLICIT WORDING

**`LOCAL READY` does NOT mean `REAL CLOUD PRODUCTION VERIFIED`.**

- Phase 2 *local* scope: **COMPLETE.**
- Real off-device durability (CloudKit **and** R2): **NOT VERIFIED**, deferred,
  gated on user approval, and **not required for Phase 3 to operate.**
- Phase 3: **GO, locally.**
