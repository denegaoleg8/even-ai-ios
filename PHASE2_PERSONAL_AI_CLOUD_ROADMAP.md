# Personal AI Cloud — Phase 2 Roadmap & Verified Status

**Single source of truth for where the Personal AI durability work actually
stands.** Documentation only — this file makes no code, provider, or
deployment change.

- **HEAD / origin/main:** `fe2bbe1d6a202d4fb23cceb721735d0d7e84ae26`
- **Last updated:** 2026-08-29
- **Related docs:** `PHASE1_PERSONAL_AI_REPORT.md`,
  `PHASE2_PERSONAL_AI_CLOUD.md` (design),
  `PHASE2_PERSONAL_AI_CLOUD_IMPLEMENTATION.md` (Phase 2 cloud/sync report),
  `PHASE2_CLOUDKIT_STEP1_PLAN.md` / `PHASE2_CLOUDKIT_STEP1_IMPLEMENTATION.md`
  (CloudKit adapter foundation),
  `PHASE2_R2_INDEPENDENT_BACKUP.md` (R2 independent-backup design + local
  implementation), `PHASE2_REAL_CLOUD_DECISION.md` (provider decision).

---

## Honest one-line summary

The **local** Personal AI memory system and the **software foundations** for
cloud sync, a CloudKit adapter, and an encrypted independent backup are
built, committed, and tested locally. **No real off-device cloud durability
has been verified.** No Cloudflare R2 bucket exists, no production R2
authentication is configured, and production CloudKit is not configured
(blocked on a paid Apple Developer Program membership). G2 / Phase 3 has not
started.

---

## Target architecture — the 3-copy + export recovery model

The durability design has **three copies plus a portable export**:

1. **Protected local iPhone cache** — on-device, AES-256-GCM sealed, Keychain
   key (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
2. **Primary cloud (planned: Apple CloudKit private database)** — the
   authoritative cross-device store.
3. **Independent encrypted backup (planned: Cloudflare R2)** — a
   non-Apple object store holding the same AES-256-GCM-sealed
   `PersonalDataBundle`, for disaster recovery if CloudKit or the Apple
   account is lost.

Plus: **portable user export** — an open, human-readable + machine-readable
`EvenAI-PersonalAI-YYYY-MM-DD/` archive (and `.zip`), readable without EvenAI,
containing no secrets.

**What is actually implemented and tested today:** copy **#1** (real, live),
and the **software foundations** for **#2** and **#3** (adapter code, seams,
encryption, backup/restore logic, deterministic tests against in-memory
fakes). The portable export foundation is implemented and tested locally.

**What is NOT verified today:** real provider durability for **#2** and
**#3**. Copies #2 and #3 do not yet exist as real off-device data anywhere.

---

## COMPLETE (built, committed, tested locally)

- **Local Personal AI memory foundation** — `MemoryRecord` / `Rule` /
  `PersonalAIConversation` / `PersonalAIChatMessage` / `RecordRevision` /
  style profile, on-device stores, context builder, extraction pipeline.
  (`e6a9fa2`)
- **Provider-independent cloud / sync architecture** — `PersonalCloudService`
  seam, `PersonalAISyncEngine`, conflict policy, tombstones / resurrection
  guard, cursor-based incremental pull, idempotent push, offline queue,
  in-process simulated backend for tests. Shipping build reports
  `.notConfigured` and wires no cloud. (`9abb954`)
- **CloudKit adapter foundation (pure-Swift, STEP 1)** — `CloudKitPersonalCloudService`,
  record mapper, two-custom-zone schema, database facade, account binding,
  persisted adapter state, error mapping, deterministic tests against an
  in-memory CloudKit double. Not wired into `.live`; no Apple portal work.
  (`de0f37a`)
- **Encrypted independent-backup architecture + local implementation (R2
  layer / foundation)** — `BackupEncryptionProviding` /
  `BackupObjectTransport` / `BackupCredentialProviding` Core seams,
  `EncryptedBackupEnvelope` framing, AES-256-GCM sealing on-device,
  `R2BackupStore` (dormant in production), `CompositeBackupStore`,
  presigned-URL auth model (no client-side R2 secret), dormant / not-configured
  production defaults. (`fe2bbe1`)
- **Backup / restore validation tests** — deterministic snapshot, integrity
  verification (envelope hash + length, GCM tag, bundle checksum, structural
  validate), verify-before-publish, atomic publication, retry idempotency,
  interrupted-upload safety, corrupted / wrong-key rejection, owner-mismatch
  rejection, "a failed or unavailable backup never clears local data",
  validate-before-destructive-mutation. (`fe2bbe1`)
- **Portable export / import foundation** — `PersonalDataExporter` /
  `PersonalDataImporter` (format / schema / checksum / count / required-field
  validation, tombstone-aware restore, dedupe by id), plus
  `PersonalDataArchiveBuilder` producing the open
  `EvenAI-PersonalAI-YYYY-MM-DD/` folder + `.zip`. Secrets structurally
  absent; byte-scan tests prove it.

> **Precise wording:** "R2 **production backup**" is **not** complete. Only
> the "R2 **independent backup layer / foundation**" is complete — the
> code, seams, encryption, and local tests. No real R2 data has ever been
> written.

---

## SHELVED / BLOCKED

**Reason: a paid Apple Developer Program team is currently unavailable.** The
only Apple team on this machine is a free Personal Team
(`isFreeProvisioningTeam = 1`), and CloudKit is not available on a free
Personal Team.

- **Apple CloudKit entitlements / container setup** — the `EvenAI.entitlements`
  file, `project.yml` `CODE_SIGN_ENTITLEMENTS` wiring, iCloud capability, and
  Development container configuration.
- **Real CloudKit private-database verification** — connecting the STEP 1
  adapter to a real `CKContainer` and confirming per-user private-DB
  semantics, zones, and sync.
- **New-iPhone real CloudKit restore test** — restoring a full Personal AI
  memory set onto a second physical device from CloudKit.

**Where the shelved work lives (do not modify):**

- git stash: `stash@{0}` — `cloudkit-step2-apple-config-pending-paid-team`
- backup copy: `~/Desktop/cloudkit-step2.patch`
  (md5 `a80809f705cf73ad24cdf513e41b673a`)

---

## NOT YET CONFIGURED

None of these has been created, enabled, or attempted. The code is designed
to accept them later without embedding an R2 secret in the app.

- **Real Cloudflare R2 bucket** — not created.
- **Secure production R2 upload / download endpoint and authentication** —
  the presigned-URL Worker (which would hold the R2 secret server-side) is
  designed and documented only; not written, not deployed. No API tokens,
  no account, no billing.
- **Real encrypted off-device R2 backup** — no sealed `PersonalDataBundle`
  has ever been uploaded anywhere off-device.
- **Real R2 restore test** — restoring from an actual R2 object has not been
  done.
- **Production CloudKit** — not configured (see SHELVED / BLOCKED).

---

## FUTURE (in order)

1. **Finish real CloudKit setup** once a paid Apple Developer Program
   membership is available — unshelve `cloudkit-step2.patch`, configure the
   entitlement / container, wire `PersonalAIContainer.live` behind the
   development flag, verify against a real `CKContainer`.
2. **Configure the secure R2 production backup path** — stand up the
   presigned-URL Worker so the R2 secret stays server-side; the iPhone app
   never holds permanent R2 credentials. Create the bucket, wire
   `WorkerBackupCredentialProvider` + `URLSessionBackupObjectTransport`
   behind configuration.
3. **Perform real backup + restore / recovery tests** — real CloudKit sync,
   real R2 encrypted upload, real download + decrypt + validate + restore.
4. **Verify new-iPhone recovery** — full memory set recovered onto a second
   physical device from cloud + independent backup, and confirmed usable by
   `PersonalAIContextBuilder`.
5. **Only after cloud + recovery reliability is established**, consider
   Personal AI → G2 **Phase 3** integration (`AIConversationEngine` cloud
   personalization). Not started; explicitly gated on the above.

---

## Current claim boundary

Until FUTURE steps 1–4 are done and verified, the product must **not** claim
real off-device cloud durability for Personal AI. Today's honest statement:
local data is encrypted on device, a portable export exists, and the cloud /
backup software is built but dormant — `PersonalAIContainer.live` reports
`.notConfigured` and wires no cloud provider.
