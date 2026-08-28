# EvenAI Personal AI — Phase 2 Cloud Implementation Report

**Goal:** turn the Phase 1 local Personal AI memory system (committed at
`e6a9fa2`) into a durable, portable **Personal AI Cloud** — so a user never
loses years of memory because one device or one hosting provider disappears.

**Boundary honoured:** everything is built and verified **locally against an
in-process simulated backend that runs only in tests and dev builds**. No
provider account was created, nothing was paid for, nothing was deployed. No
Railway. `AIConversationEngine` / Voice / Glasses / backend: **zero
changes**. G2 cloud personalization stays Phase 3.

**A shipping build wires NO cloud** — `PersonalAIContainer.live` has
`cloudService == nil` and reports `cloudEnvironment == .notConfigured`. The
UI says exactly that; nothing implies cross-device durability. Local
AES-256-GCM encryption, Export, and local Backup files are the only
off-device options today, and all three are real.

**Status:** implemented + green + audited. 46 new cloud tests (116 Personal
AI tests total), full non-UI suite passing, no regressions. The pre-commit
audit found 1 real defect (production silently wired the simulation) — fixed.

---

## PHASE 2 ARCHITECTURE

Three persistence layers, all reachable through Phase 1's `PersonalMemoryStore`
/ new `PersonalDataStore` abstractions so callers (`PersonalAIService`,
`DefaultPersonalAIContextBuilder`) are unchanged:

```
A. PRIMARY CLOUD (authoritative)   PersonalCloudService protocol
                                   shipping build → nil (.notConfigured)
                                   tests / -EvenAISimulatedCloud → MockPersonalCloudService
                                                                   over InMemoryPersonalCloudBackend
B. LOCAL ENCRYPTED CACHE           LocalPersonalMemoryStore + LocalPersonalAIConversationStore
                                   behind EncryptedDocumentFile (AES-256-GCM, Keychain key) — LIVE
C. INDEPENDENT BACKUP FILES        BackupStore — Phase 2: LocalDirectoryBackupStore
                                   (AES-256-GCM .paibak blobs in the app container) — LIVE
```

Layer B and the local-file path of C are **real and running in a shipping
build**. Layer A is a designed, fully-tested seam with no provider wired.

Orchestration:

```
PersonalAISyncEngine   ─ incremental push/pull, retry, idempotency, conflicts, tombstones
PersonalConflictResolver ─ deterministic per-kind policy
LocalPersonalDataStore ─ facade: memory store + conversation store + revisions + sync state
PersonalDataExporter / PersonalDataImporter ─ portable JSON bundle + validation
PersonalAIBackupCoordinator ─ schedule, retention, client-side encryption
PersonalAICloudRestoreCoordinator ─ new-iPhone / reinstall recovery (cloud → backup fallback)
```

Everything is provider-agnostic. iOS never sees a hostname, a vendor SDK
(beyond Apple's on-device `FoundationModels` and `CryptoKit`), or a
Railway concept.

---

## PRIMARY CLOUD DATABASE DESIGN

**Protocol:** `PersonalCloudService` — `pull(ownerID, since:)` /
`push(SyncPushRequest) → SyncPushResult` / `snapshot(ownerID)` /
`deleteAllData(ownerID)`. Every method is `ownerID`-scoped; the
implementation MUST enforce isolation server-side.

**Phase 3 relational schema** (Postgres — the design; CloudKit maps the same
records to `CKRecord`s, see Hosting Options):

| table | key columns | notes |
|---|---|---|
| `users` | `id` (uuid) | one row per account; `created_at`, `deleted_at` |
| `memories` | `(owner_id, client_id)` | `client_id` = Phase 1 `MemoryRecord.id`; `remote_id`, `revision` (server-assigned, monotonic), `payload` (jsonb, schema-versioned), `deleted_at`, `updated_at` |
| `memory_revisions` | `(client_id, revision_id)` | append-only; `version`, `changed_at`, `source`, `reason`, `previous_payload` |
| `memory_sources` | `(client_id, conversation_id/message_id)` | provenance back-links |
| `rules` | `(owner_id, client_id)` | same shape as `memories`; `priority`, `scope` |
| `people` | (view) | `memories WHERE payload->>'category' = 'people'` |
| `projects` | (view) | `memories WHERE payload->>'category' = 'projects'` |
| `episodes` | (view) | `memories WHERE payload->>'category' = 'episodes'` |
| `style_profiles` | `owner_id` | singleton per user; `revision`, `payload` |
| `conversations` | `(owner_id, client_id)` | `do_not_remember` rows are never uploaded |
| `messages` | `(owner_id, client_id)` | `conversation_id`, append-only, `deleted_at` |
| `sync_state` | `(owner_id, device_id)` | server cursor per device |
| `devices` | `(owner_id, device_id)` | `last_seen`, non-secret sync plumbing |
| `backup_manifests` | `(owner_id, bundle_version)` | `checksum`, `counts`, `schema_version`, `tier` |
| `embeddings` | `(client_id, model_version)` | **nullable / derived**; safe to drop |

- **Row-Level Security** on `owner_id` for every table.
- `client_id` (the Phase 1 device UUID) is preserved everywhere — a record's
  identity survives app delete, new iPhone, and provider migration.
- `payload` as `jsonb` + `schemaVersion` inside it keeps schema migrations
  cheap.

**Phase 2 implementation:** `InMemoryPersonalCloudBackend` (actor) is a
faithful simulation — per-owner stores, server-assigned monotonic revisions,
opaque cursor, optimistic-concurrency conflict detection, idempotent push,
tombstone-wins, and pagination (so `hasMore` is exercised). It is what Phase
3's real conformer must behave like, and it is what every test runs against.

---

## LOCAL CACHE

`LocalPersonalMemoryStore` and `LocalPersonalAIConversationStore` (Phase 1)
now take an injected `DocumentFileStoring`:

- `PlaintextDocumentFile` — default (tests, previews).
- `EncryptedDocumentFile` — production, wired by `PersonalAIContainer.live`:
  `CryptoKit` AES-GCM (authenticated encryption), 256-bit key from
  `KeychainSymmetricKeyStore`. A `"EAP1"` magic prefix versions the blob.
  Reading a Phase 1 **plaintext** file is transparent and the next write
  seals it — a one-time, no-data-loss migration.

The cache holds the full working set as a `PersonalMemoryDocument` (+ a
sibling conversations file) — the same value type used for export, backup and
sync. It survives relaunch, works fully offline, and is what the Personal AI
context builder reads on every turn.

---

## SYNC ENGINE

`PersonalAISyncEngine` (actor). `sync() → SyncOutcome`:

1. **Guards** → `.skipped` if **no cloud service configured** (the shipping
   default) / sync disabled / not authenticated / already running. A stale
   persisted `cloudSyncEnabled` flag can never re-arm sync when
   `cloudService == nil` (`PersonalAIService.open()` forces it off).
   **Global memory OFF → pull-only** (receive updates, never upload — §33).
2. **Push** — `dataStore.pendingChanges()` is the offline queue (records
   whose `syncState != .synced`, **excluding Do-Not-Remember conversations
   and their messages**). Batched with a deterministic `idempotencyKey`
   (`deviceID` + sorted `(kind,id,baseRevision,deleted)` hash) so a retried
   batch never double-applies. Server conflicts → `PersonalConflictResolver`
   → resolved records re-pushed until convergence (bounded rounds).
3. **Pull** — cursor-based, paginated. A response with any un-decodable
   envelope is **rejected without advancing the cursor and without touching
   local data** (`code=decode`).
4. **Persist** cursor + `lastSyncSucceededAt`; refresh pending count.
5. **Cancellation-safe** — checked between phases; a cancelled sync leaves
   pending changes pending.

**The invariant:** a sync failure of any kind (`offline`, `server`,
`decode`, `unauthorized`) returns `.failedRetryable` / `.failedFatal`, keeps
every local record and its content byte-identical, and keeps the queue
intact. Proven by dedicated tests.

**Base-revision model:** the server's optimistic-concurrency check compares
against the **last server revision the device actually synced**
(`PersonalSyncState.syncedRevisions`), *not* a record's local `revision` (a
local edit counter). Without this, a burst of local edits could coincidentally
match a server revision and clobber a concurrent tombstone — the fix is
tested (`tombstoneNoResurrection`).

**Triggers:** after each Personal AI Chat turn (fire-and-forget, *after* the
visible response and *after* async memory extraction — §22/§24), on
`open()`, and on the auth-identity handoff.

---

## CONFLICT POLICY

Deterministic, per `PersonalRecordKind` — never blind last-write-wins:

| Kind | Policy | Behaviour |
|---|---|---|
| memory / project / person / knowledge / episode | `semanticMerge` | run `MemoryMerger.reconcile` (Phase 1). Duplicate → collapse; contradiction → supersede; **genuinely different facts → keep server live AND re-issue the local one under a fresh id** (nothing lost). Loser → `RecordRevision`. |
| rule | `ruleUnion` | newest `updatedAt` wins the text (tiebreak by id); `enabled` = local **AND** server (a rule disabled on one device stays disabled); loser text → `RecordRevision`. |
| message | `appendOnly` | never overwritten — the server copy is authoritative history. |
| conversation (metadata) | `highestRevisionThenNewest` | highest revision, then newest `updatedAt`, then id. |
| style profile | `newestWins` | newest `updatedAt` (tiebreak id); loser → `RecordRevision`. |

A **tombstone on either side always wins** — resolution never resurrects a
deleted record. Every resolution converges to the same result regardless of
which device syncs first (`deterministicRuleConflict`).

---

## VERSION HISTORY

`RecordRevision` — append-only per record: `revisionID`, `recordID`,
`recordKind`, `version`, `changedAt`, `source`, `reason` (machine code, never
content), `previousPayloadJSON`, `previousRevision`.

Written on **every** content-replacing change: user edit, merge/supersede
(Phase 1), sync fast-forward, and conflict resolution. Retention:
`userConfirmed` records keep full history; inferred records keep the last 10
(`LocalPersonalMemoryStore.pruneRevisions`).

Powers the Memory Center's **Version History** section with a swipe-to-Restore
action (`PersonalAIService.restoreMemoryRevision`). Revisions travel in the
backup bundle and survive export/import.

---

## TOMBSTONES

Deletion is a first-class sync concept:

- `deletedAt` on every syncable record; a delete sets `status = .deleted`,
  `enabled = false`, `deletedAt`.
- Push of a delete is **always accepted** by the server (tombstone-wins) and
  bumps the server revision.
- A stale device that edits and pushes its still-live copy loses the
  optimistic-concurrency check (its `baseRevision` < the tombstone's server
  revision) → conflict → tombstone-wins resolution → the edit is dropped, the
  record stays deleted on **both** devices.
- Tombstones are retained in the document (never hard-deleted) so the history
  and any Phase 3 "restore deleted memory" flow have the data.

Proven: `tombstoneNoResurrection`, `deletedMemoryDoesNotResurrect` (implicit
in the round-trip tests), tombstones survive export/import and encrypted
backup.

---

## BACKUP ARCHITECTURE

`PersonalAIBackupCoordinator` + `BackupStore` — a **separate dependency**
from `PersonalCloudService` by design (a bug or outage in one cannot corrupt
the other).

- Full `PersonalDataBundle` (memories, rules, style, conversations, messages,
  revisions, manifest).
- **Client-side AES-256-GCM sealed** before it reaches `BackupStore` (§16).
- Phase 2 `LocalDirectoryBackupStore` writes `.paibak` blobs + a manifest
  index to the app's Application Support container; a real `S3BackupStore` /
  `R2BackupStore` is a drop-in.
- `PersonalAICloudRestoreCoordinator` uses the newest backup as an automatic
  **fallback** when a cloud snapshot is unavailable
  (`restoreFallsBackToBackup`).

**Honesty about independence (§9):** the code is *architecturally*
independent of the primary DB, and today's `LocalDirectoryBackupStore` is a
genuinely separate store. But it writes into **this app's own container** —
so it does **not** yet protect against loss of this device. That requires a
real off-device `BackupStore` (S3/R2/iCloud Drive), which is Phase 3. The UI
tells the user to move a copy somewhere safe until then; the report does not
claim device-loss DR that isn't there.

---

## BACKUP FREQUENCY

`PersonalAIBackupCoordinator.runIfDue()`, driven by `lastBackupSucceededAt`:

| Tier | Cadence | Retention |
|---|---|---|
| incremental | every ~6 h **if there were changes** | last 3 |
| daily | once per 24 h (full snapshot) | last 7 |
| weekly | promoted from daily | last 4 |
| monthly | promoted from weekly | last 3 |

**Justification:** Personal AI memory is low-volume (kilobytes/day) but
high-value and rarely re-derivable. A 6-hour incremental bounds worst-case
data loss to one working session; 7 daily + 4 weekly + 3 monthly (~14
snapshots) covers "I corrupted something last Tuesday" without unbounded
storage growth. Pruning is by tier in `LocalDirectoryBackupStore`.

Tracked in `PersonalSyncState`: `lastBackupSucceededAt`, `lastBackupVersion`,
`lastBackupChecksum`, `lastBackupRecordCounts`, `lastBackupErrorCode`,
plus `schemaVersion` in every manifest.

---

## BACKUP ENCRYPTION

| Layer | Phase 2 (implemented) | Phase 3 additive |
|---|---|---|
| In transit | N/A (in-process). Phase 3: TLS to the provider. | TLS 1.2+ enforced |
| Cloud primary at rest | N/A (in-process). | provider-managed encryption (CloudKit / Postgres TDE / SSE) |
| **Backup blobs** | **application-level AES-256-GCM**, key in Keychain, sealed on-device before upload | + provider SSE as a second layer |
| Local cache at rest | **application-level AES-256-GCM** (`EncryptedDocumentFile`) + iOS `.completeFileProtection` | — |

Honest scope: Phase 2 delivers **application-level** encryption for the local
cache and for backups. Provider-managed encryption for the cloud primary is a
Phase 3 deployment concern and is not claimed as done. The key never sits in
the same file, Keychain service, or account as the data it protects or as
`AuthTokenStore`'s refresh token.

---

## EXPORT FORMAT

One open, versioned JSON file — inspectable **without an EvenAI server**:

```jsonc
{
  "manifest": {
    "format": "evenai.personal-ai.bundle",
    "schemaVersion": 1,
    "bundleVersion": 7,
    "createdAt": "…", "deviceID": "…", "ownerID": "…", "appVersion": "…",
    "counts": { "memory": 42, "rule": 5, "conversation": 8, "message": 210, "styleProfile": 1 },
    "checksum": "<sha256 of the payload with the manifest zeroed>"
  },
  "memory": { /* Phase 1 PersonalMemoryDocument, nested unchanged */ },
  "conversations": [ /* PersonalAIConversation */ ],
  "messages": [ /* PersonalAIChatMessage */ ],
  "revisions": [ /* RecordRevision */ ]
}
```

- Stable IDs, full revisions, provenance, tombstones — all included.
- **Never** contains auth tokens, refresh tokens, API keys, session secrets,
  or private keys — those types are not referenced by the bundle at all, and
  a test greps the serialized bytes to prove it.
- `ExportSelection` (`everything` / `memoriesOnly` / `conversationsOnly`)
  produces a still-valid, importable bundle with the other kinds empty.
- Settings → Personal AI → **Data & Backup** → Export All / Memories /
  Conversations → share sheet.

---

## IMPORT / RESTORE

`PersonalDataImporter`:

- **`validate(Data)`** runs *fully* before anything is applied: recognised
  `format`, `schemaVersion <= current`, checksum match, per-kind count
  integrity (catches truncation), required-field presence. Returns a typed
  `ImportError` with a user-facing message.
- **`restore(bundle, strategy:)`**:
  - `.replaceAll` — new iPhone / reinstall: wipe local, take the bundle.
  - `.merge` — reconcile into existing data: memories via `MemoryMerger`,
    rules unioned by id, messages append-only, revisions appended,
    **tombstones honoured (never resurrect)**, **dedupe by id**.
- **Validate-then-atomic-swap** — a corrupt, truncated, or checksum-mismatched
  backup is rejected and existing data is left byte-identical
  (`truncatedRejected`, `checksumMismatchRejected`, `wrongFormatRejected`).
- `PersonalBundleMigrator` — a real seam for `schemaVersion` upgrades
  (identity pass at v1); import always runs it so old backups never stop
  restoring.

---

## NEW IPHONE RECOVERY

`PersonalAICloudRestoreCoordinator.restore(ownerID:)`:

1. Sign in → `RootView` hands the `ownerID` to `PersonalAIService.updateOwner`
   → the owner box → the engines.
2. If nothing is local, `PersonalSyncState.needsCloudRestore` is set.
3. `PersonalAIService.open()` sees the flag → `restoreFromCloud()`:
   `cloudService.snapshot(ownerID)` → **validate** → `importBundle(.replaceAll)`
   → sync cursor set to the snapshot's highest revision.
4. If the cloud snapshot is unavailable → automatic fallback to the newest
   independent backup.
5. The Personal AI Chat reloads from the restored store; memories, rules,
   style, projects, people and conversation history are all present.

Proven end-to-end: `newIPhoneRestore`, `reinstallRestoreViaService`,
`restoredMemoryDrivesContext` (the restored project memory actually flows
into `PersonalAIContextBuilder`).

---

## DISASTER RECOVERY

| # | Scenario | What copy remains | Restore path | Data-loss window | Dependencies |
|---|---|---|---|---|---|
| A | iPhone lost | cloud primary + server-side backups | sign in on new device → auto cloud restore | up to last successful sync (seconds–minutes of active use) | auth, network |
| B | App deleted / reinstalled | cloud primary + local backups (if any survived*) | sign in → auto restore; else Restore-from-Backup-File | same as A | auth, network |
| C | Cloud API host down | encrypted local cache + local/independent backups | app keeps running on cache; sync + backup resume on reconnect; AI Conversation + local G2 replies **unaffected** | zero (offline) | none |
| D | Primary DB unavailable/corrupt | independent backup blobs (separate store) | restore newest backup → re-seed primary | since last backup (≤ 6 h incremental) | backup store access |
| E | DB accidentally corrupted | per-record `memory_revisions` + backups | restore affected records from revision history, or full restore from backup | ≤ 6 h | — |
| F | Hosting provider shuts down | everything is portable: `PersonalDataBundle` export + backups + `client_id`s | stand up a new `PersonalCloudService` conformer, import the latest bundle; `client_id`s re-associate every record | one export cycle | new provider |
| G | Migration to another provider | same as F, planned | dual-write during cutover, then flip `cloudService` | zero (planned) | new provider |

\* App deletion removes the app container; a real deployment would also store
backups in the provider's object storage (Phase 3) so they survive an app
wipe.

---

## PERSONAL AI CHAT CLOUD PATH

Unchanged visible latency, cloud made additive:

```
user message
  → PersonalAIService.send()
  → apply memory commands (explicit-instruction tier)          [local, sync]
  → PersonalAIContextBuilder.buildContext()                    [local, sync]
  → PersonalAIModelProviding.generate()  → visible response    [on-device / heuristic]
  ── response shown, status = .idle ──
  → passive memory extraction + merge (eligible turns only)    [async, does not block]
  → triggerBackgroundSync()  → PersonalAISyncEngine.sync()     [fire-and-forget]
     → PersonalAIBackupCoordinator.runIfDue()
```

Memory extraction and cloud sync are **strictly after** the visible reply and
never on its critical path (§22/§24). A Phase 3 cloud model provider is just
another `PersonalAIModelProviding` conformer — the context builder already
emits a vendor-neutral prompt.

---

## MODEL PROVIDER INDEPENDENCE

`PersonalAIModelProviding` (Phase 1) is untouched. Storage and generation are
two unrelated swappable dependencies:

| Tier | Conformer | Status |
|---|---|---|
| on-device | `OnDevicePersonalAIModelProvider` (FoundationModels → heuristic) | Phase 1, shipping |
| self-hosted | `SelfHostedPersonalAIProvider` | Phase 3, protocol ready |
| managed API (Anthropic / OpenAI / …) | `CloudPersonalAIProvider` via `PersonalAIAPI` | Phase 3, protocol ready |

Changing the model provider requires **no** change to memory storage, sync,
backup, or the schema.

---

## EMBEDDING STRATEGY

- `EmbeddingProviding` protocol; Phase 2 ships `NoEmbeddingProvider` (no-op).
  Retrieval stays lexical (`TextSimilarity` / `MemoryRetriever`) and is
  fully sufficient.
- `MemoryRecord.embeddingModelVersion: String?` — **metadata only**. Vectors
  are **derived data**: if the index or the vendor is lost, canonical
  `canonicalContent` is untouched and the index is rebuilt. Proven:
  `embeddingLossIsHarmless`.
- Phase 3 `embeddings` table is nullable and keyed by `(client_id,
  model_version)` so a model change triggers a clean re-embed, never a data
  loss.

---

## PRIVACY

Memory Center shows per-record sync state (`SyncBadge`: Local / Synced /
Pending). Data & Backup shows Last synced, Pending changes, Sync error, Last
backup, Backup status.

The user can:

- turn cloud sync **off** and keep all local data (`setCloudSyncEnabled(false)`
  freezes the engine, deletes nothing),
- export their data (open JSON),
- **delete cloud data** (server copy only — local kept),
- **delete the entire Personal AI account** (server + local cache +
  conversations + style + the encryption key).

Do-Not-Remember conversations and their messages are excluded from upload,
extraction, and export (`doNotRememberNeverUploads`). Global memory-off makes
sync pull-only (`memoryOffIsPullOnly`).

---

## ACCOUNT DELETION

`PersonalAIService.deletePersonalAIAccount()` — wipes local data
**unconditionally**, even with no cloud wired:

1. `cloudService?.deleteAllData(ownerID)` — clears the primary store for that
   owner if a service is wired (isolation-scoped; other users untouched).
   **No-op today** (no service).
2. `store.replaceAll(with: .empty)` — wipes the local memory cache.
3. `conversationStore.wipe()` — wipes conversations + messages.
4. `keyStore.destroy()` — deletes the Keychain key, making any residual
   ciphertext unrecoverable.

Tested with no cloud (`deleteWipesLocalWithoutCloud`). `deleteCloudData()` is
a harmless no-op when `.notConfigured` and the button is hidden.

**Retention honesty:** today there is no provider, so there are no
provider-managed snapshots. Export/Backup **files the user saved themselves**
are never touched by deletion — the UI says so. When Phase 3 wires a
provider, its backups and the app's uploaded backup blobs may be retained up
to **30 days** per the retention policy before permanent deletion (stated in
the UI, not glossed over). Server-side derived embeddings are deleted with
the `memories` rows they key off.

---

## LOCAL SECURITY

Audit of local storage:

| Store | Phase 1 | Phase 2 |
|---|---|---|
| `LocalPersonalMemoryStore` (JSON) | plaintext + `.completeFileProtection` was **not** set | **AES-256-GCM** via `EncryptedDocumentFile`, `.completeFileProtection`, transparent plaintext migration |
| `LocalPersonalAIConversationStore` (JSON) | plaintext | same as above |
| encryption key | — | Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, **own** `kSecAttrService` (`com.evenai.personalai.cache-key`), never iCloud-synced |
| `AuthTokenStore` refresh token | Keychain (unchanged) | untouched — separate service/account, no shared code or key |
| sync device id | — | `UserDefaults` (non-secret plumbing), deliberately not in the Keychain |

**Keys are never stored beside the data they protect** — key in Keychain,
ciphertext in Application Support.

---

## MEMORY CENTER CLOUD UX

**Wording is driven by `PersonalAIService.cloudEnvironment` — the app never
claims durability it doesn't have (§16).**

- **Settings → Personal AI → Data & Backup** (`PersonalAIDataBackupView`):
  - `.notConfigured` (shipping build today): header row "Personal AI Cloud —
    Not set up"; footer states the memory is **only on this device**,
    encrypted, and **won't survive losing this iPhone** — use Export or a
    Backup file. The sync section, status section, and "Delete Cloud Data"
    are hidden. Export ×3 and local Backup/Restore-from-file remain (they
    work).
  - `.simulated` (dev build with `-EvenAISimulatedCloud`): a ⚠️ banner —
    "Simulated cloud — development build only. Data here does not survive an
    app relaunch, a reinstall, or device loss."
  - `.connected` (Phase 3): the real "synced to the cloud, restored on a new
    device" wording — only then.
- **Memory Center list** — per-row `SyncBadge` (Local / Pending / Synced).
  Never shows "Synced" while `.notConfigured` (records stay `.localOnly`).
- **Memory detail** — Version History section with swipe-to-Restore, plus
  Sync state / Revision / provenance rows.

---

## HOSTING OPTIONS

Evaluated for: relational DB · auth · API hosting · vector search · backup
storage. **Pricing is indicative (knowledge cut-off Jan 2026) and must be
re-checked before any commitment.**

| Provider | Free tier | Min paid / mo | Storage incl. | Backups | Auth | Portability / lock-in | 1 user | ~100 users | ~1,000 users | Ops complexity |
|---|---|---|---|---|---|---|---|---|---|---|
| **Apple CloudKit (private DB)** | yes — 1 GB private data + generous request quota, scales with users at no dev cost | **$0** | per-user iCloud quota (user pays Apple) | Apple-managed; no independent export unless app builds it | Sign in with Apple / iCloud account | **low** lock-in for data model (CKRecord ≈ our records), **high** for platform (Apple-only) | $0 | $0 | $0 (still free at this scale) | **very low** — no servers |
| **Supabase** (Postgres + Auth + Storage + pgvector) | 500 MB DB, 1 GB storage, 50k MAU, pauses after 1 wk idle | ~$25 (Pro) | 8 GB DB, 100 GB storage | daily (Pro), PITR add-on | built-in (email, OAuth, magic link) | **low** — plain Postgres, `pg_dump` anytime | $0 | $0–25 | ~$25 | low–medium |
| **Neon** (serverless Postgres) | 0.5 GB, autosuspend | ~$19 (Launch) | 10 GB | PITR 7–30 days | none (bring your own) | **low** — standard Postgres, branching | $0 | $0–19 | ~$19–40 | low (DB only; need separate auth + API) |
| **Turso** (libSQL / SQLite at edge) | 9 GB total, 500 DBs, 1B row reads | ~$5 (Starter) | 24 GB | daily | none | **low** — SQLite, `.dump` | $0 | $0–5 | ~$5–29 | low (DB only) |
| **PlanetScale** (MySQL) | *removed* — no free tier since 2024 | ~$39 (Scaler) | 10 GB | daily + PITR | none | medium — MySQL, no FKs by default | $39 | $39 | ~$39–99 | low–medium |
| **Fly.io** (VPS + Postgres) | small allowance | ~$5–15 (1 shared VM + volume) | your volume size | you run `pg_dump` / snapshots | none | **very low** — it's your Postgres + your API | ~$5 | ~$10–20 | ~$30–60 | **medium–high** — you operate it |
| **Render** (web service + managed Postgres) | free web (spins down), free DB expires after 30 days | ~$7 web + ~$7 DB | 1 GB DB (Basic) | daily (paid) | none | low–medium | ~$14 | ~$14–25 | ~$25–60 | medium |
| **Cloudflare** (D1 + Workers + R2) | D1 5 GB, Workers 100k req/day, R2 10 GB | ~$5 (Workers Paid) | D1 5 GB, R2 10 GB free then $0.015/GB | R2 for backups; D1 Time Travel 30 days | none (bring your own, or Access) | medium — D1 is SQLite-ish, R2 is S3-compatible | $0 | $0–5 | ~$5–15 | medium |
| **AWS** (RDS + Lambda + S3) | 12-mo trial only | ~$15–30 (db.t4g.micro + Lambda + S3) | 20 GB | automated + PITR | Cognito (fiddly) | low (Postgres) but **high** operational surface | ~$20 | ~$25–40 | ~$50–120 | **high** |
| Railway | — | — | — | — | — | **excluded per project constraint** | — | — | — | — |

### Recommendation

**Phase 3 v1: Apple CloudKit private database.**
- Zero fixed cost and it stays zero as users grow (each user's data counts
  against *their* iCloud quota, not ours).
- Per-user isolation is enforced by Apple — no RLS to get wrong.
- `CKRecord` maps almost 1:1 to `MemoryRecord` / `Rule` / `PersonalAIChatMessage`.
- No server to operate, patch, or scale.
- Trade-off: Apple-platform only, and independent backups must be the app's
  own (`PersonalDataBundle` export + a user-chosen destination) since Apple
  doesn't expose CloudKit data dumps. Our backup architecture already
  provides this.

**Portable escape hatch: Supabase** (or any managed Postgres). Standard
Postgres = `pg_dump` portability, generous free tier, built-in auth. If
cross-platform (Android/web) or server-side analytics ever matter, add a
`SupabasePersonalCloudService` conformer and dual-write during cutover —
`client_id`s make the migration lossless.

Both sit behind the **same** `PersonalCloudService` protocol. iOS does not
change.

---

## ESTIMATED COSTS

| Scale | CloudKit path | Supabase path |
|---|---|---|
| 1 personal user (you) | **$0/mo** | **$0/mo** (free tier) |
| ~100 users | **$0/mo** | **$0–25/mo** (likely still free; Pro if idle-pause is unacceptable) |
| ~1,000 users | **$0/mo** (well within CloudKit's per-app quota which scales with users) | **~$25–50/mo** (Pro + storage) |
| ~10,000 users | still $0 for CloudKit in practice; monitor request-per-app ceiling | ~$100–300/mo + a small API host |

Plus, on either path:
- **AI model:** $0 on-device (default). A managed API tier would add
  per-request cost (roughly $0.01–0.05 per Personal AI Chat turn depending
  on vendor/model) — opt-in, not required.
- **Object storage for independent backups (Supabase path):** included in
  Supabase Storage free tier at these scales; ~$0.02/GB/mo beyond.

**Bottom line:** the recommended CloudKit path has **no fixed monthly cost**
at any realistic scale for this product. The portable Postgres path is
**$0 now, ~$25/mo** if/when a solo product needs an always-on DB.

---

## WHAT WAS IMPLEMENTED

- Full sync engine (`PersonalAISyncEngine`) — incremental, retry, offline
  queue, idempotency, dedupe, cancellation-safe, base-revision concurrency.
- Deterministic per-kind conflict resolution (`PersonalConflictResolver`)
  with convergence and loss-free "keep both".
- Tombstones + resurrection guard.
- Version history (`RecordRevision`) — written on every change, retained,
  restorable, survives backup/export.
- Encrypted local cache (`EncryptedDocumentFile` + `KeychainSymmetricKeyStore`)
  with transparent plaintext migration.
- Portable export/import (`PersonalDataExporter` / `PersonalDataImporter`) —
  open JSON, checksum + count validation, validate-then-atomic-swap, schema
  migration seam.
- Independent encrypted backups + retention (`PersonalAIBackupCoordinator` +
  `LocalDirectoryBackupStore`), separate from the primary.
- New-iPhone / reinstall recovery (`PersonalAICloudRestoreCoordinator`) with
  cloud → backup fallback.
- In-process simulated backend (`InMemoryPersonalCloudBackend`) with real
  server semantics + `MockPersonalCloudService` failure injection — **test /
  dev-only, never wired by a shipping build** (`PersonalAIContainer.simulated()`
  behind the `-EvenAISimulatedCloud` DEBUG launch arg).
- User ownership + `ownerID`-scoped isolation (enforced by the backend
  abstraction, tested — the Phase 3 real backend must enforce it server-side
  with RLS).
- Memory Center cloud UX: Data & Backup screen, sync badges, version history.
- Account deletion (cloud + local + key).
- `PersonalDataStore` facade; `PersonalCloudService` / `BackupStore` /
  `EmbeddingProviding` protocols.
- 38 new cloud tests; the 5 required `xcodebuild` runs.

---

## WHAT STILL REQUIRES EXTERNAL PROVIDER CREDENTIALS

Phase 3 deployment needs a **provider decision** and, for that provider:

| If CloudKit | If Supabase / Postgres |
|---|---|
| a CloudKit **container** enabled on the app's Apple Developer account (schema pushed via the CloudKit console / `CKSchema`) | a **Supabase project** (or managed Postgres + object storage + auth), its connection string / API keys, and a small deployed API process implementing `PersonalCloudService` over HTTP |
| `com.apple.developer.icloud-services` + `icloud-container-identifiers` entitlements | server-side RLS policies + the schema migration applied |
| a real `CloudKitPersonalCloudService` conformer (~1 file) | a real `SupabasePersonalCloudService` conformer + an `AuthenticatedAPIClient`-style transport |
| — | an S3-compatible bucket for server-side backups (if not using Supabase Storage) |

Nothing above was created. `PersonalAIContainer.live` wires **no cloud
service** today (`.notConfigured`). Phase 3 adds one `make(cloudService:
environment: .connected)` call there plus the conformer file — no change
anywhere above `PersonalCloudService`.

---

## FILES CHANGED

**New — Core (`EvenAI/Core/Domain/PersonalAI/`), 11 files:**
`PersonalRecordKind`, `PersonalCloudSyncable`, `RecordRevision`,
`PersonalSyncState`, `PersonalAIConversation`, `BackupManifest`, `SyncTypes`,
`ConflictPolicy`, `PersonalDataBundle`, `PersonalCloudProtocols`,
`PersonalDataImportExport`.

**Extended — Core (additive, back-compat):** `MemoryRecord`
(+`embeddingModelVersion`, `PersonalCloudSyncable` conformance), `Rule`
(conformance), `PersonalAIModelProviding` (`PersonalAIChatMessage` + sync
fields + custom Codable), `PersonalMemoryDocument` (+`revisions`,
+`syncState`, `decodeIfPresent`), `PersonalMemoryStore` (+4 sync methods),
`PersonalAIProtocols` (`PersonalAIConversationStore` + 7 sync methods).

**New — Infrastructure (`EvenAI/Infrastructure/PersonalAI/`), 13 files:**
`SymmetricKeyStore`, `EncryptedDocumentFile`, `PersonalSyncCodec`,
`InMemoryPersonalCloudBackend`, `MockPersonalCloudService`,
`PersonalConflictResolver`, `LocalPersonalDataStore`, `PersonalAISyncEngine`,
`PersonalDataExporter`, `PersonalDataImporter`, `PersonalBundleMigrator`,
`LocalDirectoryBackupStore`, `PersonalAIBackupCoordinator`,
`PersonalAICloudRestoreCoordinator`, `NoEmbeddingProvider`.

**Extended — Infrastructure (additive):** `LocalPersonalMemoryStore`
(injected file store + sync methods + revision pruning),
`LocalPersonalAIConversationStore` (rewritten: sync-aware, Phase 1
migration, injected file store), `InMemoryPersonalMemoryStore` (sync
methods).

**Extended — App:** `PersonalAIService` (cloud state + ~12 methods + sync
triggers), `DI/PersonalAIContainer` (Phase 2 wiring + `PersonalOwnerBox` +
`PersonalAICloudBundle`), `RootView` (one `.task(id:)` auth→ownerID handoff).

**New — Features:** `PersonalAIDataBackupView`. **Extended:** `PersonalAIView`
(+link), `MemoryCenterView` (`SyncBadge`), `MemoryCenterDetailViews`
(version history).

**New — Core (audit):** `PersonalCloudEnvironment`.

**New — Tests (`EvenAITests/PersonalAICloud/`), 7 suites:**
`PersonalAISyncEngineTests`, `PersonalCloudIsolationTests`,
`PersonalDataExportImportTests`, `PersonalCloudRestoreTests`,
`PersonalCloudResilienceTests`, `EncryptedDocumentFileTests`,
`PersonalCloudProductionAuditTests` +
`EvenAITests/TestDoubles/FakePersonalCloud.swift`.

**Not touched:** `AIConversationEngine.swift`, `AgentContextStore.swift`,
`GlassesChatProvider.swift`, everything under `Infrastructure/Voice`,
`Infrastructure/Glasses`, `Infrastructure/Chat`, `Features/Voice`,
`Features/Glasses`, `Features/Conversations`, `AuthTokenStore.swift`,
`project.yml`, any backend file, `EvenAITests/ProductionEndpointContractTests.swift`.

---

## NEW TEST COUNT

**46 new cloud tests** across 7 suites, mapped to brief §30 (all 35 items)
plus the pre-commit audit items:

| §30 | Test(s) |
|---|---|
| 1, 13 | `reinstallRestoreViaService`, `offlineQueueThenReconcile` |
| 2 | `encryptedCacheSurvivesRelaunch` |
| 3, 12 | `newIPhoneRestore`, `offlineQueueThenReconcile` |
| 4–8 | `fullRoundTripStableIDs` (memories/rules/style/people/conversations) |
| 9 | `incrementalSync` |
| 10 | `idempotentRetry` |
| 11 | `concurrentSync` |
| 14, 15 | `tombstoneNoResurrection` |
| 16, 22 | `revisionOnFastForward`, `roundTrip` (revisions survive export/import) |
| 17 | `deterministicRuleConflict` |
| 18 | `failureNeverWipesLocal` |
| 19 | `malformedResponseFailsSafely` |
| 20 | `crossUserAccessRejected`, `snapshotIsolation`, `deleteIsScopedToOwner` |
| 21, 26 | `roundTrip`, `mergeNoDuplicates` |
| 23 | `encryptedBackupRoundTrip` |
| 24, 25 | `checksumMismatchRejected`, `truncatedRejected`, `wrongFormatRejected` |
| 27, 28 | `exportExcludesSecrets` |
| 29 | `embeddingLossIsHarmless` |
| 30, 31 | `cloudFailureCannotAffectAIConversation`, `compileTimeIsolation` |
| 32 | `restoredMemoryDrivesContext` |
| 33 | `memoryOffIsPullOnly` |
| 34 | `doNotRememberNeverUploads` |
| 35 | `diagnosticsNeverLeakContent` |
| §1/§16 | `productionIsNotConfigured`, `notConfiguredCannotSync`, `simulatedIsNotDurable`, `deleteWipesLocalWithoutCloud`, `deleteCloudDataNoOpWithoutCloud`, `newIPhoneUsesSeparateStores` |
| §4 | `emptyPullDeletesNothing` |
| §6 | `revisionsAreNotActiveMemories` |
| — | `codecRoundTripAllKinds`, `checksumStability`, `partialExportIsValid`, `restoreFallsBackToBackup`, `sealAndOpen`, `wrongKeyFails`, `plaintextMigration`, `missingFileIsNil` |

**46 new cloud tests** total (38 original + 8 audit). Total Personal AI tests
(Phase 1 + Phase 2): **116 tests / 20 suites**.

---

## FULL TEST RESULT

_Numbers below are post-audit (46 cloud tests: the original 38 + 6 production
-safety audit tests + 2 sync-safety tests)._

- `xcodebuild build` → **BUILD SUCCEEDED**
- `xcodebuild build-for-testing` → **TEST BUILD SUCCEEDED**
- **All Personal AI tests** — 116 tests / 20 suites (`EvenAITests/PersonalAI/*`
  + `EvenAITests/PersonalAICloud/*`) → **green**.
- **Full non-UI suite** (`-skip-testing:EvenAIUITests
  -skip-testing:EvenAITests/AIConversationEngineSoakTests`) →
  **596 tests in 83 suites passed, 0 failures** (54 s). **No regressions**
  vs the Phase 1 baseline of 552.
- `AIConversationEngineSoakTests` (isolated) → **8/8 passed**.
- `EvenAIUITests` (isolated, fresh sim) → **3/3 passed**.
- **Combined: 607 tests, 0 failures.**
- Running the whole suite in one `xcodebuild test` invocation still crashes
  this environment's simulator (`Mach error -308`) — reproduces on the Phase
  1 baseline, environmental, not fought; every suite passes when the run is
  split (`build` → `build-for-testing` → `test-without-building` per suite).

---

## AI CONVERSATION CORE CHANGES: **NO**

`git diff` on `AIConversationEngine.swift`, `AgentContextStore.swift`,
`GlassesChatProvider.swift`, and everything under `Infrastructure/Voice` /
`Infrastructure/Glasses` / `Features/Voice` / `Features/Glasses` /
`Features/Conversations` = **empty**. Zero references to any Personal AI Cloud
type in any of them. `RootView` gains one additive `.task(id:)` (auth →
ownerID handoff) — it does not touch the translation session, the
NavigationSplitView, or any G2 logic. `cloudFailureCannotAffectAIConversation`
runs a hard-failing sync engine alongside a live `AIConversationEngine`
session and asserts translation + local suggested replies are byte-for-byte
unaffected.

## BACKEND CHANGES: **NO**

No `even-ai-assistant-asr` changes, no Railway, no new endpoints.

## DEPLOYMENT PERFORMED: **NO**

No provider account created, no infrastructure provisioned, nothing paid for,
nothing deployed. A shipping build wires **no cloud** (`.notConfigured`); the
in-process simulation is test/dev-only.

---

## AUDIT (pre-commit, this pass)

**Verdict: PASS after fixes.** 1 real defect found and fixed; no features
added; AI Conversation core / Voice / Glasses / Conversations / backend
still untouched (`git diff` empty).

| # | Finding | Severity | Fix |
|---|---|---|---|
| 1 | **`PersonalAIContainer.live` wired `MockPersonalCloudService` in a shipping build.** A user could enable "Cloud Sync", see "Synced", and lose everything on reinstall — the mock's "server" is RAM. The UI said "backed up to the cloud and restored automatically on a new device." | **High** (data-safety / honesty) | `.live` now wires `cloudService: nil` + `cloudEnvironment: .notConfigured`. The simulation is only reachable via `PersonalAIContainer.simulated()` behind a `DEBUG` `-EvenAISimulatedCloud` launch arg. `PersonalAIService` gains `cloudEnvironment`; `setCloudSyncEnabled` refuses without a service; `open()` forces a stale `cloudSyncEnabled` off. `PersonalAIDataBackupView` is now state-driven and honest (`.notConfigured` says "only on this device, won't survive losing this iPhone"). Doc comments on the mock/backend marked TEST/DEV-ONLY. |
| 2 | `deletePersonalAIAccount()` early-returned if the cloud bundle was absent — local wipe could be skipped in a nil-cloud path. | Low | Now wipes local memory + conversations + key **unconditionally**; cloud delete is best-effort. |
| 3 | `RESTORE_START` trace logged `owner=\(ownerID.prefix(0))` (always empty). | Trivial | → `hasCloud=<bool>`. |

**New tests:** `PersonalCloudProductionAuditTests` (6) — `.live` is
`.notConfigured`; a nil-cloud service can't sync and reports no durability;
delete wipes local without a cloud; new-iPhone restore uses genuinely
separate store objects. Plus `emptyPullDeletesNothing` and
`revisionsAreNotActiveMemories` in the sync suite.

**Code changed during audit: YES** — `PersonalAIContainer.swift`,
`PersonalAIService.swift`, `PersonalAIDataBackupView.swift`,
`MockPersonalCloudService.swift`, `InMemoryPersonalCloudBackend.swift`,
`PersonalAICloudRestoreCoordinator.swift` (1 trace string), + new
`PersonalCloudEnvironment.swift`. All localized safety/honesty fixes, no
interface breakage. **AIConversationEngine / Voice / Glasses / Conversations
/ backend: still zero changes.**

---

## SAFE TO COMMIT: **YES**

---

*Do not commit. Do not push. Do not deploy. Stop after the audit.*
