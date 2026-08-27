# Personal AI — Phase 2 Cloud & Backup Design

**Status: design only. Nothing in this document is built or deployed in Phase 1.**
Every seam it relies on already exists in the Phase 1 code (named in
parentheses). No Phase 1 type needs to change shape for any of this — the
work is additive.

---

## 1. Guiding constraints (carried from Phase 1)

- Memory is **portable independently of the model provider**. Storage and
  generation are two unrelated swappable dependencies
  (`PersonalMemoryStore` vs `PersonalAIModelProviding`).
- **No Railway lock-in.** The backend is a deployment choice, expressed
  behind `PersonalMemoryAPI` / `PersonalAIAPI`.
- **The AI Conversation / G2 core is never made to depend on the cloud.**
  The G2 seam stays optional and last in the pipeline.
- **Local-first.** The device stays fully functional with no network and no
  subscription; the cloud is sync + durability, not a gate.

---

## 2. Primary cloud database

**Shape:** one row per `MemoryRecord` and per `Rule`, keyed by
`(ownerID, id)`, plus a `memory_revisions` append-only table.

| Column | Source (Phase 1 field) |
|---|---|
| `owner_id` | `MemoryRecord.ownerID` |
| `client_id` (uuid) | `MemoryRecord.id` — stable forever, generated on device |
| `remote_id` | `MemoryRecord.remoteID` — assigned on first push |
| `revision` | `MemoryRecord.revision` — monotonic per record |
| `payload` (jsonb) | the whole record, schema-versioned |
| `deleted_at` | `MemoryRecord.deletedAt` (tombstone, never hard-deleted) |
| `updated_at` | `MemoryRecord.updatedAt` |

**Engine:** Postgres (managed — Neon / Supabase / RDS / Cloud SQL, chosen at
deploy time). Justification mirrors `ARCHITECTURE.md`'s auth-store note:
per-user relational data with real constraints and atomic multi-row writes.
Row-level security on `owner_id`. `payload` as `jsonb` keeps schema
migrations cheap while `schemaVersion` inside it guards forward-compat.

**Not** the chat `store.js` JSON-file pattern — memory is long-lived,
security-relevant, and needs revision history.

---

## 3. Encrypted local cache

Replaces `LocalPersonalMemoryStore`'s plaintext JSON file with an
**encrypted** store exposing the *same* `PersonalMemoryStore` protocol —
callers (`PersonalAIService`, `DefaultPersonalAIContextBuilder`) are
untouched.

- **At rest:** SQLite via SQLCipher, **or** the current JSON document
  sealed with `CryptoKit.AES.GCM`. Key in the Secure Enclave / Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), **separate from
  `AuthTokenStore`** — auth credentials and memory never share a key or a
  file (Phase 1 §17 already keeps them in separate stores).
- **Contents:** exactly a `PersonalMemoryDocument` — so cache, backup, sync
  payload and export are one format.
- **Eviction:** none needed at realistic memory volumes; the cache is the
  full working set.

---

## 4. Cloud sync

Behind a new `HybridMemoryStore: PersonalMemoryStore` that composes the
encrypted local cache with a `CloudMemoryStore` conformer.

**Algorithm (per record, using fields that already exist):**

1. **Pull:** `CloudMemoryStore.pull(since: cursor)` → server records changed
   since the last cursor.
2. **Merge:**
   - server `revision` > local `revision`, local `syncState == .synced` →
     take server (fast-forward).
   - local has un-pushed edits (`syncState == .pendingPush`) and server also
     changed → **conflict**: keep both as sibling records, then run the
     existing `MemoryMerger.reconcile` on them (duplicate → collapse;
     contradiction → supersede; else keep both). `syncState = .conflict`
     until resolved, surfaced in the Memory Center.
   - tombstones (`deletedAt`) always win over a concurrent edit.
3. **Push:** send `pendingPush` records; server assigns `remoteID` /
   authoritative `revision`; local rows flip to `.synced`.
4. **Cursor:** persist the server watermark; sync is incremental.

Triggers: on app foreground, after each `PersonalAIService` turn that wrote
memory, and on a background-refresh task. All best-effort — a failed sync
never blocks a chat turn or the G2 pipeline.

---

## 5. Version history

The `memory_revisions` append-only table stores every prior `payload` of a
record. Powers:

- "**Undo this correction**" in the Memory Center (restore revision N-1).
- Auditing an `inferredFromConversation` record's evolution.
- Recovering from a bad merge (each `supersede` writes a revision, so the
  superseded content is never lost — Phase 1 already keeps it as a
  `.superseded` record locally).

Retention: full history for `userConfirmed` records; last 10 revisions for
inferred ones.

---

## 6. Independent backups

Separate from sync, so a sync bug can't corrupt the backup:

- **Nightly server-side snapshot** of each owner's full document to
  object storage (S3-compatible), server-side encrypted, 30-day retention,
  write-only from the app's perspective.
- **On-device manual export:** `PersonalMemoryStore.export()` →
  `PersonalMemoryDocument` → user-initiated share sheet (encrypted `.pai`
  file). Already callable today (`PersonalAIService.exportDocument()`).

---

## 7. Export / restore

- **Export:** `export()` → `PersonalMemoryDocument` → JSON (or encrypted
  `.pai`). Stable, schema-versioned, human-readable.
- **Restore:** `PersonalMemoryStore.replaceAll(with:)` (exists in Phase 1)
  or a merge-import that runs each incoming record through
  `MemoryMerger.reconcile` against current memory.
- **Format compatibility:** `PersonalMemoryDocument.schemaVersion` gates it;
  an older document is migrated forward on import.

---

## 8. New-iPhone recovery

1. Sign in → `AuthState` establishes `ownerID`.
2. `CloudMemoryStore.snapshot()` → full `PersonalMemoryDocument`.
3. `replaceAll(with:)` into the fresh encrypted local cache.
4. Sync cursor set to the snapshot watermark; incremental from there.

No device-to-device transfer needed; the cloud snapshot is authoritative.
If the user was offline-only in Phase 1, the local `export()` file is the
migration path.

---

## 9. Disaster recovery

| Failure | Recovery |
|---|---|
| Device lost / wiped | Cloud snapshot (§8). |
| Cloud DB corruption | Restore from nightly object-storage snapshot (§6). |
| Bad sync merge | Per-record revision history (§5); tombstones are reversible. |
| Backend provider outage | App keeps running on the encrypted local cache; sync resumes on reconnect. Local suggested replies / translation unaffected (never touched the cloud). |
| Provider migration | Re-point `CloudMemoryStore` / `PersonalMemoryAPI` at the new host; `client_id`s are stable, so records re-associate by `id`. |

---

## 10. Model provider options

All behind `PersonalAIModelProviding` — memory does not care which is used:

| Tier | Conformer | Notes |
|---|---|---|
| On-device | `OnDevicePersonalAIModelProvider` (Phase 1) | Apple FoundationModels → heuristic. Private, offline, free. |
| Self-hosted | `SelfHostedPersonalAIProvider` (Phase 2) | e.g. llama.cpp / vLLM behind `PersonalAIAPI`. Data stays on infra you control. |
| Managed API | `CloudPersonalAIProvider` (Phase 2) | Anthropic / OpenAI / etc. via `PersonalAIAPI`. Opt-in; the context builder already produces a provider-neutral prompt. |

The `PersonalAIContextBuilding` output (`systemPromptText` + structured
fields) is already vendor-neutral, so switching tiers is a one-line wiring
change in `PersonalAIContainer`.

---

## 11. Hosting options

| Option | Fit |
|---|---|
| Managed Postgres + serverless functions (Neon + Vercel/Cloudflare, Supabase) | Lowest ops; good default. |
| Single VPS (Postgres + a small API process) | Cheapest; fine for a solo/early product. |
| Existing Railway project, new isolated service | Reuses infra **without** coupling — memory API is its own process/DB, no shared code with ASR/chat/auth (same discipline as `ARCHITECTURE.md`'s "share a process, nothing in code"). |
| Fully on-device + iCloud (CloudKit private DB) | No server at all: `CloudMemoryStore` backed by CloudKit. Strong privacy story; loses cross-platform and server-side snapshot. Viable Phase 2 v1. |

**Recommendation:** CloudKit private database for the first Phase 2 release
(zero backend to operate, per-user isolation for free, `CKRecord` maps
cleanly to `MemoryRecord`), with the `CloudMemoryStore` protocol keeping a
managed-Postgres migration open if cross-platform or server-side analytics
are later needed.

---

## 12. What Phase 1 already guarantees for all of the above

- Every record carries `id` / `remoteID` / `revision` / `syncState` /
  `deletedAt` / `ownerID` — **no schema migration** to start syncing.
- `PersonalMemoryDocument` is cache + backup + export + sync-payload in one
  type.
- `export()` / `replaceAll(with:)` already exist on `PersonalMemoryStore`.
- `MemoryMerger.reconcile` is the conflict-resolution engine, already
  tested.
- Storage and model provider are independent protocols.
- The G2 seam is optional and additive; the cloud never becomes a
  dependency of the proven pipeline.
