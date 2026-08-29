# Personal AI — Independent Encrypted Backup (Cloudflare R2)

**Scope of this document + implementation:** design and **local** implementation
of the provider-independent independent-backup layer, with **Cloudflare R2**
as the planned first target. **Nothing is deployed.** No R2 bucket, no
Cloudflare Worker, no Cloudflare login, no API token, no billing. The real
network transport ships **dormant**; `PersonalAIContainer.live` is unchanged.

Baseline: `de0f37a56d798f85fe354866457b10e245132f62`.

---

## PRIMARY STORAGE DESIGN

The Personal AI data model has three storage roles behind stable seams:

| Role | Seam | Status |
|---|---|---|
| **Local protected cache** | `PersonalMemoryStore` / `PersonalAIConversationStore` over `EncryptedDocumentFile` (AES-GCM, Keychain key, `…ThisDeviceOnly`, `.completeFileProtection`) | **live** — the authoritative on-device copy |
| **Primary cloud provider** | `PersonalCloudService` (`pull` / `push` / `snapshot` / `deleteAllData`) | **adapter built** (`CloudKitPersonalCloudService`), **not wired** — CloudKit needs a paid Apple Developer Program membership, which this account does not currently have (see `PHASE2_CLOUDKIT_STEP1_PLAN.md`). Wiring is shelved (`git stash`, `~/Desktop/cloudkit-step2.patch`). |
| **Independent encrypted backup** | `BackupStore` + `PersonalAIBackupCoordinator` | **live on-device** (`LocalDirectoryBackupStore`); **R2 seam built and dormant** (this task) |
| **Portable export/import** | `PersonalDataExporter` / `PersonalDataImporter` / `PersonalDataArchiveBuilder` | **live** — single-file bundle + (new) open folder/zip archive |

The primary cloud (CloudKit, or later Postgres) is the **synchronised** store.
The independent backup is a **one-directional disaster-recovery copy**. They
never share a failure domain and never share code beyond the
`PersonalDataBundle` shape.

## LOCAL CACHE DESIGN

Unchanged. `LocalPersonalMemoryStore` / `LocalPersonalAIConversationStore`
persist a `PersonalMemoryDocument` / conversation set as an AES-GCM-sealed
JSON file in Application Support. The `SymmetricKeyStore` key is a 256-bit
Keychain item with **its own service** (`com.evenai.personalai.cache-key`),
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never iCloud-synced,
**never shared with `AuthTokenStore`**. A cloud or R2 outage cannot touch
this file — the app runs entirely from it.

## INDEPENDENT BACKUP DESIGN

```
PersonalDataBundle  (the one snapshot type — memories, revisions, rules,
       │             projects/people/episodes (= memories by category),
       │             style profile, conversations, messages, tombstones,
       │             manifest with counts + checksum + ownerID)
       ▼
PersonalDataExporter.data(for:)          canonical JSON
       ▼
BackupEncryptionProviding.seal(_:)       AES-256-GCM + EncryptedBackupEnvelope framing
       ▼   (sealed `.eapb` blob — never plaintext past this line)
BackupStore.putBackup(_:handle:ownerID:)
       ├── LocalDirectoryBackupStore      on-device (Application Support) — LIVE
       └── R2BackupStore                  off-device DR — DORMANT
                │
                ├── BackupCredentialProviding.presign(op,key,ownerTag)   ← Worker (not deployed)
                └── BackupObjectTransport.put/get/delete/head(url)       ← HTTPS (dormant)
       ▼
PersonalAIBackupCoordinator     verify-before-publish · retention · restore
```

New protocols (`EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift`),
all provider-neutral, **no Cloudflare / AWS / S3 type anywhere**:

- `BackupEncryptionProviding` — `seal` / `open` / `schemeIdentifier`
- `BackupObjectTransport` — `put` / `get` / `delete` / `head` over an
  already-authorised URL
- `BackupCredentialProviding` — `presign(operation, key, ownerTag)` +
  `isConfigured`

New infrastructure (`EvenAI/Infrastructure/PersonalAI/Backup/`):

| File | Role |
|---|---|
| `EncryptedBackupEnvelope.swift` | binary framing `"EAPB1" + len + headerJSON + rawCiphertext`; `BackupOwnerTag` (salted SHA-256) |
| `AESGCMBackupEncryption.swift` | production `BackupEncryptionProviding`; opens legacy raw blobs too |
| `BackupObjectTransports.swift` | `DormantBackupObjectTransport` (prod default), `URLSessionBackupObjectTransport` (real, compiled, unused) |
| `BackupCredentialProviders.swift` | `NotConfiguredBackupCredentialProvider` (prod default), `WorkerBackupCredentialProvider` (real, compiled, unused) |
| `R2BackupStore.swift` | `BackupStore` over transport + credentials; object/catalog layout; `.dormant` composition |
| `CompositeBackupStore.swift` | fan-out to `[local + R2]`; **a secondary (R2) failure is never fatal** |
| `PersonalDataArchiveBuilder.swift` | the portable open export folder/zip |
| `StoredZipArchive.swift` | minimal dependency-free STORE-method zip writer + CRC-32 |

Enhanced (`PersonalAIBackupCoordinator.swift`): uses `BackupEncryptionProviding`;
**verify-before-publish**; owner check on load; `loadLatestBackupBundle`
now iterates newest→oldest and returns the first backup that
decrypts + validates + owner-matches.

## WHY R2 IS NOT PRIMARY STORAGE

R2 is an **object store**, not a database. It has no query, no transactions,
no per-record concurrency, no change feed. The Personal AI sync engine needs
all of those. R2 is used **only** as an encrypted, append-mostly bucket of
whole-snapshot blobs for disaster recovery. It is never:

- the primary Personal AI database,
- the live synchronisation database (the sync engine talks to
  `PersonalCloudService`, never `BackupStore`),
- a source G2 reads (G2 reads the on-device `PersonalAIContextBuilder`),
- a source touched per chat request (backups run on a schedule, not per turn).

Putting the live database in R2 would mean re-uploading a full snapshot on
every edit and reading a full snapshot to answer a question — untenable.

## ENCRYPTION MODEL

- **Algorithm:** AES-256-GCM (`CryptoKit` `AES.GCM`), random 96-bit nonce per
  seal, authenticated (tampering ⇒ open fails).
- **Where:** on the device, *before* the bytes reach any `BackupStore`.
  `LocalDirectoryBackupStore` and `R2BackupStore` only ever see ciphertext.
- **Envelope:** `EncryptedBackupEnvelope` binary framing wraps the raw
  ciphertext with a tiny JSON header (see BACKUP FORMAT). The ciphertext is
  **not** base64'd — no size bloat on a multi-hundred-MB backup.
- **Provider-side encryption (R2 SSE):** would be a second, additive layer,
  not a replacement — and it is **not claimed** here because it isn't
  configured.
- **Legacy:** `open` also parses a bare `AES.GCM.SealedBox(combined:)` blob,
  so on-device backups written before this layer still restore.

## KEY MANAGEMENT DESIGN

- The backup key **is** the local-cache key — one 256-bit `SymmetricKey` from
  `KeychainSymmetricKeyStore` (`com.evenai.personalai.cache-key`), device-only,
  not iCloud-synced.
- **Consequence:** a raw `.eapb` object in R2 is unrecoverable without that
  device. This is deliberate — R2 (or a Worker, or Cloudflare) never has the
  key. The **user-saved export archive** (unencrypted, the user chose to
  export it) is the recovery path when the device is also gone.
- **Trade-off + future work:** a "wrap the backup key with a user passphrase"
  option would let a user restore an R2 backup onto a brand-new device with no
  access to the old one. Additive; decided later.
- The `EncryptedBackupEnvelope.encryptionScheme` header field means a future
  key/algorithm change is detectable (`unsupportedScheme` on open).

## PRODUCTION AUTH MODEL FOR R2

**A production iPhone app must never embed a permanent R2 access key.** A
binary can be extracted; a leaked key exposes every user's bucket.

The model implemented as a dormant seam:

```
iPhone                         Cloudflare Worker (authenticated)        R2
──────                         ───────────────────────────────        ──
BackupCredentialProviding
  .presign(.put, key, tag) ──► POST /presign  { op, key }
                               Authorization: Bearer <identity token>
                               │
                               │ 1. verify the identity token
                               │    (Sign in with Apple `sub` / EvenAI
                               │     account token)
                               │ 2. check key is under "<tag>/…"
                               │ 3. sign a URL with the R2 secret
                               │    (the secret lives ONLY here)
                               │    scoped to that one key + verb,
                               │    expiring in minutes
                               ◄── { url, headers, expiresInSeconds }
BackupObjectTransport
  .put(data, to: url)      ─────────────────────────────────────────► PUT object
```

- The app holds **no** R2 credential — only a short-lived, single-operation,
  key-scoped pre-signed URL.
- `WorkerBackupCredentialProvider` (compiled, dormant) is the client half.
  `NotConfiguredBackupCredentialProvider` (`isConfigured == false`) is the
  production default — every call throws `notConfigured`.
- Defence in depth: `WorkerBackupCredentialProvider.presign` refuses to even
  request a URL for a key outside its own `<ownerTag>/` prefix.
- **The Worker is a documented boundary. It is NOT written or deployed here.**
  Its contract: one `POST /presign` route, verifies an identity token, signs
  an R2 URL scoped to `<ownerTag>/*`, returns it. ~30–50 lines.

## WHAT MUST NEVER BE STORED IN R2 (or any backup / export)

- passwords, refresh tokens, access tokens, session tokens, bearer tokens
- API keys (EvenAI backend, OpenAI, Anthropic, Cloudflare, R2)
- private keys, the Keychain symmetric key, any Keychain item
- the raw Personal AI user id in an object **key path** (only the salted
  `ownerTag` hash appears there)
- plaintext Personal AI content (only the sealed `.eapb` blob)

Enforced structurally (`PersonalDataBundle` references none of these types)
and by tests that grep the sealed blob, the decrypted bundle, and every
export file for token/secret patterns.

## BACKUP FORMAT

### Encrypted object (`.eapb`)

```
 0 ..< 5      "EAPB1"                magic + envelope-format digit
 5 ..< 9      UInt32 (big-endian)    header length H
 9 ..< 9+H    header JSON            EncryptedBackupEnvelopeHeader
 9+H ..< end  ciphertext             raw AES-GCM combined box
```

`EncryptedBackupEnvelopeHeader` — the **minimum** metadata readable without
the key:

| field | why it's outside the ciphertext |
|---|---|
| `encryptionScheme` | to know how to open it / detect a scheme change |
| `createdAt` | order / retention without a decrypt |
| `ownerTag` | reject another user's object pre-decrypt (salted hash, **not** the id) |
| `bundleSchemaVersion` | "too new" check without a decrypt |
| `bundleVersion` | order / dedupe without a decrypt |
| `ciphertextSHA256` + `ciphertextLength` | detect truncation / bit-rot before spending a decrypt |

No counts, no content, no account id.

### Catalog (`<ownerTag>/catalog.json`)

`{ version, handles: [BackupHandle] }` — `BackupHandle` is
`{ id, createdAt, bundleVersion, sizeBytes, checksum, tier }`. Publishing a
backup = rewriting this object; see ATOMIC BACKUP PUBLICATION.

### Inner bundle (`PersonalDataBundle`, unchanged)

`BackupManifest` (`format`, `schemaVersion`, `bundleVersion`, `createdAt`,
`ownerID`, `counts`, `checksum` = SHA-256 of the canonical bundle JSON with
the manifest omitted) + `memory` (`PersonalMemoryDocument`: records, rules,
style, `revisions`, tombstoned records retained) + `conversations` +
`messages`.

## BACKUP FREQUENCY

`PersonalAIBackupCoordinator.runIfDue()` (called after `open()` and after a
Personal AI turn's async extraction):

- **incremental** if ≥ 6 h since the last successful backup,
- **daily** (full snapshot) if ≥ 24 h,
- otherwise nothing.

Plus an explicit **user-created recovery snapshot** (`backup(tier:)` from a
"Create recovery backup" button). Every tier is a full `PersonalDataBundle`
snapshot — "incremental" is a retention label, not a delta format (personal
memory is small; a delta format is complexity with little payoff).

## RETENTION POLICY

Per-tier keep-counts, pruned oldest-first after every successful backup
(`PersonalAIBackupCoordinator.retention`):

| tier | keep | ≈ coverage |
|---|---:|---|
| incremental | 3 | last ~18 h |
| daily | 7 | last week |
| weekly | 4 | last month |
| monthly | 3 | last quarter |

Total ≤ 17 objects per user. At ~1–10 MB sealed each (personal scale) that's
~20–170 MB — comfortably inside R2's 10 GB-month free allowance for one user,
and for hundreds of users. The **inspected existing schedule was kept** — it
already matches the "latest verified + daily + bounded history + explicit
snapshot" shape the brief suggested.

## VERSION HISTORY

- `BackupHandle.bundleVersion` increments once per backup produced on a
  device (`PersonalSyncState.lastBackupVersion + 1`).
- Record-level edit history (`RecordRevision`) travels **inside** every
  bundle and is restored with it.
- Multiple retained backups give point-in-time recovery at tier granularity.

## INTEGRITY VERIFICATION

Four independent layers, checked on both backup-verify and restore:

1. **Envelope** — `ciphertextSHA256` + `ciphertextLength` vs the bytes on
   disk → catches truncation / corruption **before** a decrypt.
2. **AES-GCM tag** — decrypt fails on any tampering or a wrong key.
3. **Bundle checksum** — `PersonalBundleChecksum.verify` (SHA-256 of the
   canonical bundle JSON minus the manifest) → catches a tampered payload.
4. **Structural validation** — `PersonalDataImporter.validate`: recognised
   `format`, `schemaVersion ≤ current`, per-kind `counts` match the actual
   records, required fields present.

Plus an **owner check** — `bundle.manifest.ownerID` must equal the current
Personal AI user id (a bundle with no owner is accepted; a *different* owner
is rejected as `ownerMismatch`).

## ATOMIC BACKUP PUBLICATION

`PersonalAIBackupCoordinator.backup(tier:)`:

1. build snapshot → seal.
2. `putBackup` the sealed object. **A throw here leaves the catalog — every
   prior backup — completely untouched.** `PersonalSyncState.lastBackupSucceededAt`
   is not advanced.
3. **verify-before-publish**: read the object back, decrypt, re-validate,
   owner-check. On failure → `deleteBackup` the just-uploaded object,
   return `.failed("verify")`, do not advance `lastBackupSucceededAt`.
4. only now: prune + advance `lastBackupSucceededAt` / `lastBackupVersion` /
   `lastBackupChecksum`.

`R2BackupStore` publication itself is two steps: PUT the object, then rewrite
`catalog.json`. If the catalog rewrite fails, the new object is an
unreferenced orphan (pruned later) and `listBackups` still returns the
previous verified set.

`loadLatestBackupBundle` iterates newest→oldest and returns the first backup
that fully verifies — so a half-written or foreign object that somehow got
into the catalog is skipped and the previous good backup is used.

## EXPORT FORMAT

The **portable user export** (`PersonalDataArchiveBuilder`) — separate from
the encrypted `.eapb` backup, open, readable without EvenAI, no secrets:

```
EvenAI-PersonalAI-YYYY-MM-DD/
  README.md                      plain-English: what this is, schema version
  manifest.json                  format, schema versions, counts, ownerTag (hash), file list
  chats/readable-history.md      human transcript — "## <title>", "**You**" / "**Personal AI**", ISO-8601 timestamps
  chats/conversations.jsonl      one JSON object per message
  memory/memories.json           [MemoryRecord] — stable ids, provenance, timestamps
  memory/rules.json              [Rule]
  memory/style-profile.json      PersonalAIStyleProfile
  memory/projects.json           memories where category == projects (same ids, convenience copy)
  memory/people.json             memories where category == people
  history/revisions.jsonl        one RecordRevision per line
  history/tombstones.jsonl       one deleted record per line — so a re-import never resurrects it
```

Written as a folder (`writeArchive`) and/or a single `.zip` (`writeZip`,
STORE method, no compression, opens in Finder / Files). UTF-8, ISO-8601 UTC.
The existing single-file `PersonalDataBundle` JSON export and
`PersonalDataImporter` are **unchanged**.

## RESTORE FLOW

`PersonalAICloudRestoreCoordinator.restore(ownerID:)` (unchanged control
flow):

1. **cloud snapshot first** (`PersonalCloudService.snapshot`) — when a
   primary cloud is wired.
2. **fall back to the newest verified independent backup**
   (`PersonalAIBackupCoordinator.loadLatestBackupBundle`).
3. each candidate is **fully validated before any local mutation**
   (`PersonalDataImporter.validate` + owner check); only a bundle that
   passes is applied, as one `.replaceAll` swap.
4. `.replaceAll` **preserves the local `PersonalSyncState`** (sync
   preference, cursor, backup history) — a restore restores canonical data,
   not device config.
5. a failed/invalid candidate leaves local data **exactly as it was**.

## NEW IPHONE RECOVERY FLOW

1. New iPhone, install EvenAI, sign in (same EvenAI account ⇒ same
   `PersonalAIUserID`).
2. If a primary cloud is wired (CloudKit, later): `snapshot()` → restore.
   Fastest path.
3. Else / if that fails: the user opens their saved **export archive** (or,
   once R2 + a passphrase-wrapped key exist, an R2 backup) → import →
   `.replaceAll`.
4. Stable ids are preserved, tombstones honoured — a later sync does not
   duplicate or resurrect anything.

## DISASTER RECOVERY FLOW

| Scenario | What recovers the data |
|---|---|
| Local cache corrupted | The primary cloud (when wired); else the newest verified backup — cloud/local backup, both re-validated before touching local data. |
| Primary cloud provider outage | Nothing to do — the app runs from the local cache; sync resumes later; backups continue to `LocalDirectoryBackupStore`. |
| Primary cloud provider *disappears* (account terminated) | The independent backup (different failure domain) + the user's export archive. Restore into a new provider via `.replaceAll`; `client_id`s preserved. |
| Device lost **and** cloud unavailable | The R2 backup (once configured) or the user's saved export archive, onto a new device. |

## WHAT HAPPENS IF CLOUDKIT IS UNAVAILABLE

Today CloudKit is **not wired** (paid-membership blocker). The app is
`cloudEnvironment == .notConfigured`: memory lives only in the encrypted
local cache; the sync engine is inert; backups still run to
`LocalDirectoryBackupStore`; export still works. **No data is at risk from
CloudKit's absence** — it just means no cross-device sync yet.

Once wired: a CloudKit outage → the sync engine returns `.failedRetryable`,
keeps every pending change queued, never clears local data; the independent
backup is unaffected (separate seam).

## WHAT HAPPENS IF R2 IS UNAVAILABLE

R2 is a `BackupStore` *secondary* under `CompositeBackupStore`. A dormant /
offline / quota-exceeded / 5xx R2:

- `CompositeBackupStore.putBackup` still succeeds if the **local** primary
  succeeded; the R2 error is recorded as `lastSecondaryErrorCode` only.
- `PersonalAIBackupCoordinator` treats a total backup-store failure as
  `.failed` — it **never advances `lastBackupSucceededAt`**, **never clears
  local data**, and the **previous verified backup stays recoverable**.
- Restore falls through R2 → local backup → (nothing) without mutating local
  data.

Verified by `BackupHardeningTests`: provider-unavailable, interrupted upload,
repeated 5xx, corrupted object — in every case local memory is byte-identical
afterwards and the prior backup still loads.

## WHAT HAPPENS IF THE CLOUD PROVIDER DISAPPEARS

The `PersonalDataBundle` is the authority and is provider-agnostic. The
independent backup and the export archive both reconstruct the full dataset
with stable ids. Switching primary provider (CloudKit → Postgres, or R2 →
B2/S3) is an adapter swap behind `PersonalCloudService` / `BackupStore` —
`R2BackupStore` → `S3BackupStore` is a like-for-like replacement (R2's API is
S3-compatible; the `BackupObjectTransport` seam is already generic).

## WHAT HAPPENS IF THE USER LOSES ONE DEVICE

- Their data is in: the primary cloud (when wired), the R2 backup (when
  wired), and any export archive they saved.
- A new device with the same EvenAI account restores from whichever is
  available. Data-loss window = time since the last successful sync (cloud)
  or the last verified backup (R2 / export).
- The lost device holds only an encrypted cache whose key is device-local
  and non-exportable.

## WHAT REMAINS BLOCKED UNTIL REAL PROVIDERS ARE CONFIGURED

| Blocked | Needs |
|---|---|
| Real off-device backups (R2) | a Cloudflare account, an R2 bucket, and a deployed `/presign` Worker + an identity-token source. **None created.** |
| CloudKit primary sync | a **paid** Apple Developer Program membership (this account is a free Personal Team), then the App ID iCloud capability + container. |
| Restore an R2 backup onto a brand-new device with no access to the old one | a passphrase-wrapped backup key (additive, designed above, not built). |
| Any claim about real R2 latency / durability / cost | an actual R2 test — **not authorized in this task and not performed**. |

## ESTIMATED R2 STORAGE / REQUEST MODEL

Per the retention policy: ≤ 17 sealed objects + 1 catalog per user, each
~1–10 MB at personal scale (a heavy multi-year user with lots of chat could
reach tens of MB per snapshot).

| Users | Stored | PUTs/mo (Class A) | GETs/mo (Class B) | R2 cost/mo* |
|---:|---|---|---|---|
| 1 | ~20–170 MB | ~60 (2 backups/day × verify + catalog) | ~60 | **$0** (free: 10 GB-month · 1M Class A · 10M Class B) |
| 100 | ~2–17 GB | ~6 000 | ~6 000 | **$0** (storage may edge the 10 GB free tier at the high end → ~$0.015/GB-month over) |
| 1 000 | ~20–170 GB | ~60 000 | ~60 000 | ~**$0.15–2.5** storage; ops still free-tier |
| 10 000 | ~200 GB–1.7 TB | ~600 000 | ~600 000 | ~**$2–25** storage; ~$0 ops (still under 1M Class A) |

\* Cloudflare R2 Standard as published (re-confirm before acting): storage
$0.015/GB-month, Class A $4.50/M, Class B $0.36/M, **egress free**. No
CloudKit / R2 recurring minimum. A `/presign` Worker stays within Workers
Free (~100k req/day) until ~thousands of active users, then Workers Paid
$5/month.

## REQUIRED MANUAL CLOUDFLARE SETUP FOR LATER (do NOT do now)

1. Create a **Cloudflare account** (free). A payment card may be required to
   open R2 even on the free tier — verify at signup.
2. Create an **R2 bucket** (e.g. `evenai-personal-ai-backups`), one region.
3. Create an **R2 API token** scoped to that bucket (Object Read & Write).
   **Store it only in the Worker's secrets — never in the app, never in the
   repo.**
4. Write + deploy a **Worker** with one route `POST /presign`:
   - verify the caller's identity token (Sign in with Apple `sub` / the
     EvenAI account token),
   - derive `ownerTag` server-side (do not trust the client's),
   - reject any `key` not under `<ownerTag>/`,
   - sign an R2 URL (`aws4` / R2's S3 API) for the one verb + key, expiring
     in ~5 minutes,
   - return `{ url, headers, expiresInSeconds }`.
5. In the app (a later, separate change): wire
   `PersonalAIContainer.live`'s `backupStore` to
   `CompositeBackupStore(primary: LocalDirectoryBackupStore(),
   secondaries: [R2BackupStore(credentials: WorkerBackupCredentialProvider(endpoint:…, identityToken:…), transport: URLSessionBackupObjectTransport())])`.
6. Add a real-R2 integration test suite, scheme-gated, run manually with test
   credentials — **do not commit credentials**.

---

*Design + local implementation only. No Cloudflare account, no R2 bucket, no
Worker, no credentials, no billing, no deployment. `PersonalAIContainer.live`
unchanged. Not committed, not pushed.*
