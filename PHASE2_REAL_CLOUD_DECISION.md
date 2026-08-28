# EvenAI Personal AI — Real Cloud Decision

**Purpose:** choose the real production architecture for the Personal AI Cloud
(primary store, auth, independent backup, restore, export, future
server-side model access, future G2 personalization). Decision document only
— **no code, no accounts, no deployment.**

**Inputs:** Phase 1 (local memory foundation) and Phase 2 (cloud / sync /
backup / restore architecture, provider-agnostic behind `PersonalCloudService`
/ `BackupStore`) are committed at `9abb954`. A shipping build reports
`.notConfigured`. This document picks what fills that seam.

> **Verification note (updated 2026-08-28).** The provider facts in the
> CLOUDKIT, SUPABASE, FIREBASE and CLOUDFLARE sections and in the COST
> sections have been updated to currently published provider terms. Figures
> still change without notice — re-confirm each one against the provider's
> own pricing page immediately before acting on it. Nothing here has been
> tested against a live provider account, and no account has been created.

---

## RECOMMENDATION

**Primary store: Apple CloudKit private database.**
**Auth: Sign in with Apple** (identity), **implicit iCloud account** (CloudKit itself).
**API host: none now.** A future server-side model call is *client-mediated*
(the phone builds context from CloudKit and POSTs it to a **stateless** model
endpoint that never stores or reads memory).
**Independent backup: Cloudflare R2** (or Backblaze B2) — the app uploads the
same AES-256-GCM-sealed `PersonalDataBundle` it already produces, to a
**non-Apple** object store. Convenience copies (on-device file, optional
iCloud Drive folder) are *not* the DR backup.
**Export: on-device zip archive** (human-readable `chats/readable-history.md`
+ machine-readable JSON/JSONL + `manifest.json`), AirDrop / Files / Share
to Mac.

**Why, in one paragraph:** CloudKit stores each user's Personal AI records in
**that user's private iCloud database**, so the bytes count against **the
user's own iCloud storage quota, not a developer-side bucket** — there is no
per-user line item for EvenAI to pay and no free tier for EvenAI that can be
withdrawn (CloudKit access is part of the $99/yr Apple Developer Program
EvenAI already pays). It enforces per-user isolation and at-rest/in-transit
encryption at the platform level, gives automatic new-iPhone restore through
`CKSyncEngine`, and maps 1:1 to the Phase 2 record model. Its real
weaknesses — no `pg_dump`-style export and **no clean headless server-side
read path** — are addressed by Phase 2's portable export/backup work and by
the client-mediated model pattern, **but the server-side-access question
must be proven before Phase 3** (see *IMPORTANT SERVER-SIDE AI LIMITATION*
below). If server-side access to canonical private records turns out
impractical, canonical storage migrates to a server-accessible database
(Postgres) **without changing the Personal AI domain model or export
format** — the `PersonalCloudService` seam makes that an adapter swap and
stable `client_id`s make it lossless.

**Do not read this as "CloudKit because iOS."** The server-side-AI question
is analysed in full below; the conclusion is that EvenAI's *actual* roadmap
(on-device model, client-mediated cloud model, client-mediated G2
personalization) does not need standing server access to memory, and the
cost/fragility constraints are decisive among otherwise-comparable options.
**But** the CloudKit server-access path is an unproven risk that must be
resolved before Phase 3 — see *IMPORTANT SERVER-SIDE AI LIMITATION*.

### Architecture decision (retained)

| Layer | Decision |
|---|---|
| **PRIMARY** | CloudKit private database |
| **LOCAL** | encrypted / file-protected iPhone cache (Phase 2, already built) |
| **INDEPENDENT BACKUP** | Cloudflare R2 (non-Apple, different failure domain) |
| **OPTIONAL SERVER / API** | Cloudflare Workers, only when required, always stateless |
| **AI MODEL** | provider-independent, usage-based, optional; on-device by default |

This stack stands unless the server-side-access proof (below) fails, in
which case **PRIMARY** moves to a server-accessible database (Postgres) with
the domain model and export format unchanged.

---

## ARCHITECTURE DIAGRAM

```
                         ┌─────────────────────────────────────────────┐
   iPhone (EvenAI)        │            Apple iCloud (per Apple ID)       │
 ┌──────────────────┐     │  ┌───────────────────────────────────────┐  │
 │ PersonalAIService│     │  │  CloudKit PRIVATE database             │  │
 │  ├ context bldr  │◄───►│  │  container: iCloud.com.evenai.personal │  │
 │  ├ sync engine   │ CK  │  │  zone: PersonalAI                      │  │
 │  │   ▲           │sync │  │   CKRecord: Memory / Rule / Conversation│ │
 │  │   │           │     │  │            Message / StyleProfile      │  │
 │  ▼   │           │     │  │   (isolation + encryption = Apple)     │  │
 │ Encrypted local  │     │  └───────────────────────────────────────┘  │
 │ cache (AES-GCM,  │     │  ┌───────────────────────────────────────┐  │
 │  Keychain key)   │     │  │ iCloud Drive  EvenAI/Backups/  (opt.)  │  │  ← convenience copy
 │  = Phase 2, LIVE │     │  │  EvenAI-PersonalAI-YYYY-MM-DD.paibak   │  │    (same failure
 └───────┬──────────┘     │  └───────────────────────────────────────┘  │     domain as CK)
         │                └─────────────────────────────────────────────┘
         │  sealed PersonalDataBundle (AES-256-GCM), scheduled
         ▼
 ┌───────────────────────────┐         DIFFERENT FAILURE DOMAIN (non-Apple)
 │  Cloudflare R2 bucket      │  ◄──────  INDEPENDENT BACKUP
 │  s3-compatible, 0 egress   │           (uploaded via presigned URL from a
 │  key: <ownerID>/<version>  │            ~30-line Worker; identity = SIWA)
 └───────────────────────────┘

 ┌───────────────────────────┐
 │  Export archive (on-device)│  ──────►  AirDrop / Files / Share  ──►  Mac
 │  EvenAI-PersonalAI-*.zip   │           README.md · manifest.json
 │  human + machine readable  │           chats/ · memory/ · history/
 └───────────────────────────┘

 FUTURE (Phase 4, only if server-side model is added — still no standing
 memory access):
   iPhone builds context from CloudKit ──►  stateless model Worker  ──►  Claude/GPT
                                            (proxies, streams, stores nothing)
```

**Failure-domain summary**

| Copy | Provider / subsystem | Survives | Role |
|---|---|---|---|
| Encrypted local cache | device Keychain + filesystem | offline, provider outage | working set (Phase 2, live) |
| CloudKit private DB | Apple — CloudKit Database | device loss, reinstall | **primary** |
| iCloud Drive folder | Apple — CloudKit Documents | app deletion; user copy to Mac | convenience (shares Apple-ID root) |
| **Cloudflare R2 bucket** | **Cloudflare — object storage** | **loss of the entire Apple ecosystem / Apple ID** | **independent DR backup** |
| Export zip | wherever the user saves it | EvenAI ceasing to exist | portability / migration |

---

## CLOUDKIT ANALYSIS

### Verified facts (Apple platform documentation)
- Personal AI records live in the **user's private CloudKit database**, which
  belongs to that user's private iCloud account.
- **Private database data counts against the user's own iCloud storage
  quota** (the same quota as iCloud Backup, Photos, iCloud Drive). It is
  **not** billed to the developer and does **not** draw on a developer-side
  CloudKit storage allowance. *There is no claim here of "unlimited free
  CloudKit storage" — the user's iCloud quota is the real limit, and a user
  near their quota can have writes fail.*
- **Private database access requires an active iCloud account** signed in on
  the device. With no iCloud account, the app runs local-only.
- **`CKSyncEngine` is Apple's supported synchronization mechanism** for
  private and shared CloudKit databases (change-token tracking, batching,
  retry/backoff, account-change handling). It is the intended path for this
  work.
- The public CloudKit database *does* have a developer-side quota that scales
  with app usage, but this design uses **only the private database**, so that
  quota is not engaged.

### Fit for the required data
`CKRecord` maps 1:1 to the Phase 2 model. One custom `CKRecordZone`
("PersonalAI") holds record types `Memory`, `Rule`, `Conversation`,
`Message`, `StyleProfile`. Two viable field layouts:
- **Typed fields** — queryable, but CloudKit indexes must be declared and
  there's no full-text/vector query on the private DB.
- **Single encrypted-blob field** (`CKRecord.encryptedValues` or our own
  AES-GCM blob) + a few plaintext sort/filter fields (`updatedAt`,
  `deletedAt`, `recordKind`). Recommended: we already sync the *whole*
  working set to the device and do retrieval on-device, so server-side
  query is not needed, and a blob keeps the schema trivial and the payload
  format identical to export/backup.

Revisions and tombstones: CloudKit's zone-change feed reports deletions, and
`recordChangeTag` is an opaque per-record version. We keep our own
`RecordRevision` log and `deletedAt` soft-tombstones inside the payload so we
control retention and history exactly as Phase 2 designed — CloudKit is a
transport, not the authority on our semantics.

### Sync mapping
| Our concept | CloudKit |
|---|---|
| pull cursor | `CKServerChangeToken` per zone |
| incremental pull | `CKFetchRecordZoneChangesOperation` / `CKSyncEngine` (iOS 17+) |
| push batch | `CKModifyRecordsOperation`, `savePolicy = .ifServerRecordUnchanged` |
| conflict (stale base) | `CKError.serverRecordChanged` → gives client / server / ancestor record → feed to `PersonalConflictResolver` |
| idempotent retry | CloudKit operations are safe to retry; our idempotency key is still computed |
| per-user isolation | **the private database is the user's — there is no cross-user surface at all** |

`CKSyncEngine` (iOS 17+, EvenAI targets iOS 18) handles change-token
bookkeeping, batching, retry with backoff, and account-change events. It is
the intended modern path and removes most of the sync plumbing — but its
real-world robustness must be confirmed on **physical devices** (STEP 9),
not just the simulator.

### The important question: can a backend read canonical memory from CloudKit?

> **This is a blocking risk for Phase 3, not a solved problem.** CloudKit's
> private database is optimized around the user's Apple/iCloud identity and
> on-device access. Before any server-side Personal AI work begins, the exact
> secure server-access path for retrieving a user's private CloudKit memory
> must be proven end-to-end. See *IMPORTANT SERVER-SIDE AI LIMITATION*.

**Directly and headlessly: no, not cleanly.**
- CloudKit **Web Services** + a **Server-to-Server key** grant a backend
  access to the **public** database only.
- **Private** database access over Web Services requires the **user's
  `ckWebAuthToken`**, obtained through an *interactive* web-auth redirect
  (`users/current` → Apple sign-in → token). A backend can use a token the
  *app* captured and forwarded — scoped, short-lived — but this is
  under-documented, brittle, and works against CloudKit's privacy model.
  It is not a pattern to build a product on.
- There is **no server-side query or compute** on a private database. A
  backend would fetch records via the token-scoped Web Services API, one
  page at a time.

**The correct pattern with CloudKit primary: the backend never touches
memory.** EvenAI already has an on-device `PersonalAIContextBuilder`. For a
server-side model call, the client assembles the context (rules + retrieved
memories + style + recent turns) and POSTs *that* to a **stateless** model
endpoint. The endpoint proxies to Claude/GPT and streams back. It stores
nothing, reads nothing. This is **more** private and has **better** failure
isolation than a backend with standing DB access — "backend disappears" then
means only "no cloud model," never "memory at risk."

**When CloudKit primary becomes the wrong choice:** if the roadmap requires
the backend to process a user's memory *while the client is offline* —
server-generated weekly digests, proactive notifications derived from
memory, cross-user (anonymised) analytics, a web client. None of these are
on EvenAI's stated roadmap (on-device model; client-mediated cloud model;
client-mediated G2 personalization). If any becomes real, the switch is:
add `PostgresPersonalCloudService`, dual-write during cutover, then flip
`PersonalAIContainer` — an adapter change, not a rewrite.

### Verdict
Strong primary **for this product's current roadmap**: no developer-side
per-user storage cost (the user's iCloud quota carries it), zero ops,
platform-enforced isolation and encryption, automatic new-iPhone restore via
`CKSyncEngine`. Weak on native export/portability (addressed: Phase 2
export/backup) and — **the open risk** — weak on headless server-side read
access, which is acceptable only while Personal AI processing stays
client-mediated.

**To re-confirm before acting:** current iCloud storage tiers and any
behaviour when a user is at quota; `CKSyncEngine` maturity on physical
devices (STEP 9). Sources: developer.apple.com/icloud/cloudkit/ ·
"Deciding whether CloudKit suits your app" · "CKSyncEngine" API reference.

---

## SUPABASE ANALYSIS

**What you get:** managed Postgres + `pgvector`, GoTrue auth (email / OAuth /
magic link / Apple), S3-compatible Storage, Deno Edge Functions, realtime.
A complete backend with low ops.

**Fit for the data:** ideal. Relational model for memories / rules /
revisions / tombstones; `pgvector` for future semantic retrieval *server-
side*; direct SQL for a future backend; RLS for isolation.

**Server-side AI:** first-class — a backend (Edge Function or your own
service) has direct SQL access and pgvector. This is the scenario CloudKit
is weak on.

**Cost / fragility (the decisive issue) — current published terms:**
- **Free: $0.** 500 MB database per project; **no automatic backups**;
  low-activity Free projects **may pause after roughly one week** of
  inactivity; a paused project can currently be restored within a **one-year
  window** (after which it may be removed). A daily-use personal app would
  not pause, but the user's stated requirement is to avoid a fragile
  dependency on a free tier that can change — this is exactly that.
- **Pro: $25/month base.** Adds **automatic backups**; **PITR
  (point-in-time recovery) is priced separately** on top of the base.
- Re-confirm at supabase.com/pricing before acting.

Supabase appears here **only as a comparison**. These facts do not change the
recommendation.

**Portability:** high — plain Postgres (`pg_dump` anytime), GoTrue is
open-source, Storage is S3-compatible. If EvenAI leaves Supabase it takes a
standard SQL dump with it.

**Ops:** you own the schema, migrations, RLS policies (a security-critical
surface you must get right), and backup verification.

**Verdict:** the best choice **if** server-side autonomous memory processing
is a near-term certainty, or if Android/web clients are planned. Loses on the
hard cost/fragility constraint for a single personal user today.

---

## FIREBASE ANALYSIS

**What you get:** Firestore (NoSQL document DB), Firebase Auth (free for
email / Google / Apple / anonymous; phone auth costs), Cloud Storage, Cloud
Functions, and — recently — Firestore vector search via a Vertex AI
extension (which costs).

**Fit for the data:** workable but awkward. Firestore's document/collection
model doesn't fit relational memory + a revision log + tombstones as
naturally as SQL; you denormalise and manage composite indexes. Revisions
become a subcollection; queries are constrained (no joins, no `OR` across
fields without care, no full-text).

**Server-side AI:** good — the Admin SDK with a service-account key gives a
backend full Firestore access. Better than CloudKit here.

**Cost / fragility — current published terms:**
- **Spark plan has a genuine no-cost tier and does not require a payment
  method** for the Spark-supported services (Firestore, Auth for the common
  providers, Hosting, etc.), within daily quotas — roughly 1 GiB Firestore
  storage and tens-of-thousands of reads/writes/deletes per day, generous
  for one user.
- **Some server/cloud functionality requires Blaze** (pay-as-you-go): Cloud
  Functions, outbound networking from functions, larger quotas. Blaze
  requires a billing account and is **per-operation billing that can
  surprise** (a chatty sync or a bad query loop = a bill); you set budget
  alerts, not hard limits.
- Re-confirm at firebase.google.com/pricing before acting.

**Portability: poor (the disqualifier).** Firestore's data model *and query
semantics* are proprietary; there is no standard dump — export is
`gcloud firestore export` to a Google-specific format in a GCS bucket, or
you roll your own. Migrating off Firestore is a data-model rewrite. This
directly conflicts with "Personal AI data must remain provider-portable" and
"understandable if EvenAI disappears." Add the (perception) risk of Google
sunsetting products.

**Verdict:** rejected on portability and per-op cost unpredictability,
despite good server-side access and a generous free tier.

---

## CLOUDFLARE ANALYSIS

**Candidate architecture:** D1 (SQLite) primary · Workers (API + logic) · R2
(object storage / backups, **zero egress**) · Vectorize (vector index,
future) · **Sign in with Apple** for identity (Cloudflare has no consumer
auth product; Cloudflare Access is for teams).

**Fit for the data:** good — D1 is SQLite, so the relational model, revisions
and tombstones map cleanly, and portability is a `.sql` dump. libSQL/D1 has
native vector support arriving, or use Vectorize.

**Server-side AI:** first-class — your Workers *are* the backend with direct
D1 access; Workers AI gives cheap edge inference, or a Worker calls
Claude/GPT. Strong.

**Cost / fragility — current published terms:**

*R2 Standard, included (free) per month:*
- **10 GB-month of storage**
- **1,000,000 Class A operations** (writes / lists / mutating calls)
- **10,000,000 Class B operations** (reads)
- **egress (data transfer out) is free**

*R2 Standard, paid once the included amounts are exceeded:*
- storage **$0.015 / GB-month**
- Class A **$4.50 / million**, Class B **$0.36 / million** (re-confirm)
- Usage over the included limits **becomes billable** — R2 is not a hard-
  capped free tier; it is a free allowance on top of a metered service.

*Workers:*
- **A free tier exists** — approximately **100,000 requests/day** on Workers
  Free, with per-request CPU limits.
- **Workers Paid has a $5/month minimum**, which raises limits substantially.
- Workers **can** therefore create a recurring cost: sustained traffic above
  the free daily allowance pushes the project onto the $5/month plan.

**No forced idle-pause** on D1/Workers/R2 (unlike Supabase Free). Re-confirm
all figures at developers.cloudflare.com/{r2,workers,d1}/platform/pricing.
Whether opening an R2 bucket requires a card on file should be checked at
signup.

**Portability:** high for data (SQLite dump, S3-compatible R2, SIWA
standard); *some* lock-in in the Workers runtime (V8 isolates, not Node —
porting the API logic to another host is real but bounded work).

**Ops:** you write, test (`wrangler dev`), version and deploy Workers +
manage D1 migrations. More code and more moving parts than Supabase; far
less than raw AWS.

**Verdict:** the strongest option **if** you want an owned, cheap,
non-fragile backend with server-side AI from day one and can accept writing
Workers. It is also the recommended **independent backup** target (R2) *and*
the recommended future **stateless model proxy** host — even though it is not
the recommended primary.

---

## IMPORTANT SERVER-SIDE AI LIMITATION

**This risk is not hidden and is not resolved by this document.**

CloudKit's private database is **optimized around the user's Apple / iCloud
identity and the user's device access**. It is designed for a signed-in
device to sync its own data — not for a headless backend to read a specific
user's records on demand. Concretely:

- The public database supports server-to-server keys; **the private database
  does not**. Private-database access from outside a signed-in device
  requires the **user's `ckWebAuthToken`**, produced by an *interactive*
  web-auth flow, and there is **no server-side query or compute** over
  private data.
- A pattern where the app captures a scoped token and forwards it to the
  backend is under-documented and brittle, and it works against CloudKit's
  privacy model.

**Therefore, before Phase 3 / server-side Personal AI begins, we must prove
the exact secure server-access path** for retrieving a user's canonical
private CloudKit memory — end to end, with a real device, a real container,
and a real backend — or conclude that it is impractical.

**If that path is impractical or imposes unacceptable constraints**, the
architecture must permit **migrating canonical cloud storage to a
server-accessible database** (e.g. Postgres / Supabase / Neon) **without
changing:**
- the Personal AI **domain model** (`MemoryRecord`, `Rule`,
  `PersonalAIConversation`, `RecordRevision`, tombstones, provenance,
  `client_id`s), or
- the **export / backup format** (`PersonalDataBundle`, the export zip
  layout).

The Phase 2 `PersonalCloudService` seam and stable `client_id`s are what
make this a bounded adapter swap rather than a rewrite. The interim,
client-mediated model call (phone builds context → stateless endpoint) is a
valid design **only while Personal AI processing does not need to run
without the client present**.

---

## DECISION MATRIX

Scores 1–10 (10 = best). "Cost for one user" weights permanence and
non-fragility, not just the sticker.

| Criterion | CloudKit | Supabase | Firebase | Cloudflare |
|---|---:|---:|---:|---:|
| Durability | 9 | 8 | 8 | 8 |
| Cost for one user | **10** | 6 | 8 | 9 |
| Scalability | 9 | 8 | 8 | 8 |
| Server-side AI compatibility | 3 | **9** | 8 | **9** |
| Backup capability | 4 | 8 | 5 | 8 |
| Portability | 5 | **9** | 3 | 8 |
| Security | **9** | 8 | 8 | 7 |
| Operational complexity (10 = simplest) | **10** | 6 | 7 | 5 |
| New-iPhone recovery | **10** | 7 | 7 | 7 |
| Future G2 compatibility | 8 | 8 | 7 | 8 |
| **Total / 100** | **77** | **77** | **69** | **77** |

Three options tie at 77 with different shapes. The tie-breakers, in the
user's own priority order:

1. **"Near-zero cost for one personal user without a fragile trial
   dependency"** (hard requirement) → **CloudKit** has no developer-side
   per-user storage cost at all (the user's iCloud quota carries it) and no
   revocable free tier. Cloudflare is close (free allowances on a metered
   service; $5/month if Workers traffic grows). Supabase fails this ($25 for
   reliability, Free tier pauses and has no automatic backups).
2. **Server-side AI** (future, soft) → satisfiable **client-mediated** with
   CloudKit; a hard win for Supabase/Cloudflare only if the backend must run
   *without the client*.
3. **Portability** (hard requirement) → CloudKit's gap is **already closed**
   by Phase 2 export/backup; Firebase's gap is structural.
4. **Operational complexity / new-iPhone recovery** → **CloudKit** wins
   outright.

→ **CloudKit primary**, with **Cloudflare R2** as the independent backup and
the future stateless model proxy, and **Postgres (Supabase/Neon) as a
documented Phase-4 swap** if the roadmap changes.

---

## PRIMARY STORAGE

**Apple CloudKit private database.**
- Container `iCloud.com.evenai.personal-ai`, one custom zone `PersonalAI`.
- Record types: `Memory`, `Rule`, `Conversation`, `Message`, `StyleProfile`
  — each an AES-GCM-sealed payload blob + plaintext `updatedAt` /
  `deletedAt` / `recordKind` for sort/filter, keyed by the Phase 2
  `client_id` (`CKRecord.ID.recordName`).
- Sync via `CKSyncEngine`; conflicts via `serverRecordChanged` →
  `PersonalConflictResolver`; tombstones as soft-delete payload fields
  (retention under our control).
- `PersonalCloudService.snapshot()` = fetch all records in the zone →
  assemble a `PersonalDataBundle`.
- `deleteAllData()` = delete the zone.

---

## AUTH

**Sign in with Apple** for the `ownerID` identity string; **implicit iCloud
account** for CloudKit access itself (no explicit auth call — CloudKit uses
the device's signed-in iCloud user).
- SIWA is free, standard OIDC, gives a stable `sub` used as `ownerID` (for
  R2 backup key-scoping and for any future backend to verify the identity
  token server-side).
- No password store, no reset flow, no account-recovery burden — Apple owns
  all of it.
- The Phase 2 `PersonalOwnerBox` / `updateOwner()` handoff already exists;
  SIWA feeds it instead of the current `AuthState.currentUser`.

---

## API HOST

**None now.** The Personal AI Chat path is on-device (context builder +
`OnDevicePersonalAIModelProvider`).

**Future (Phase 4, optional):** one **Cloudflare Worker**, ~30–60 lines,
**stateless** — receives `{ systemContext, messages, userMessage }` from the
client (which built the context from CloudKit), proxies to Anthropic/OpenAI
with the app's server key, streams the response back. It **never** stores or
reads memory. Conforms to the Phase 2 `PersonalAIAPI` seam and also to
`PersonalAIModelProviding`.

---

## INDEPENDENT BACKUP

**Cloudflare R2** (recommended) or **Backblaze B2**.
- The app produces the **same** AES-256-GCM-sealed `PersonalDataBundle` the
  Phase 2 `PersonalAIBackupCoordinator` already builds, and uploads it via a
  presigned `PUT` obtained from the stateless Worker (auth: SIWA identity
  token). Key: `<ownerID-hash>/<bundleVersion>-<tier>.paibak`.
- Schedule: weekly full + on "significant change" (Phase 2 coordinator logic
  reused); retention 4 weekly / 3 monthly.
- **Different failure domain from CloudKit:** a different company, different
  service class (object store vs record DB), reachable without an Apple ID.
- **R2 vs B2:** R2 has **zero egress fees** (restore/verify traffic is free)
  and an S3-compatible API (portable); B2 is also cheap with a 10 GB free
  tier. R2 recommended for the egest-free restores.

**Convenience copies (NOT the DR backup — they share the Apple-ID root):**
- On-device sealed file (always).
- Optional `iCloud Drive/EvenAI/Backups/` visible folder — survives app
  deletion, lets the user drag a copy to a Mac.

**Rule enforced:** primary = Apple; independent backup = **not** Apple.

### Backup honesty

CloudKit + R2 is an **architecture decision, not an operational guarantee.**
It becomes real independent disaster recovery **only after all of:**
1. real CloudKit container configured and in use as primary,
2. real R2 bucket configured with credentials,
3. encrypted backup archives **actually uploading successfully** on schedule,
4. **restore from R2 tested** end-to-end (download → decrypt → validate →
   import → verify counts / ids / revisions / tombstones).

Until every one of those is true, the only copies that actually exist are
the **on-device encrypted cache** and any **export archive the user has
personally saved**. The Data & Backup UI must not claim DR protection before
step 4 passes.

---

## EXPORT TO MAC

**On-device, no server.** Settings → Personal AI → Data & Backup → Export.

Options (each produces a valid, importable archive):
- **Export everything** → the full zip below
- **Export chat history** → `chats/` only
- **Export memories** → `memory/memories.json` + `rules.json` + `style-profile.json`
- **Export projects / people** → `memory/projects.json` + `people.json`
- **Create recovery backup** → the sealed `.paibak` (encrypted, for restore,
  not for reading)

**Full archive `EvenAI-PersonalAI-YYYY-MM-DD.zip`:**

```
README.md              plain-English: what this is, how to read it, schema version,
                       "no EvenAI software needed for chats/"
manifest.json          { schemaVersion, exportedAt (ISO-8601 UTC), appVersion,
                         ownerID (opaque), counts{...}, sha256 of each part }

chats/
  readable-history.md  human-readable transcript, one section per conversation,
                       "## <title or date>", "**You** / **Personal AI**", timestamps
  conversations.jsonl  one JSON object per message: { id, conversationID, role,
                       text, timestamp, eligibleForMemory }

memory/
  memories.json        [ MemoryRecord ]  — canonical, stable ids, timestamps,
                       provenance (sourceConversationIDs / sourceMessageIDs),
                       category, confidence, status, deletedAt
  rules.json           [ Rule ]
  style-profile.json   PersonalAIStyleProfile
  projects.json        memories where category == "projects" (also in memories.json;
                       duplicated here for convenience, same ids)
  people.json          memories where category == "people"

history/
  revisions.jsonl      one RecordRevision per line: { revisionID, recordID, recordKind,
                       version, changedAt, source, reason, previousPayloadJSON }
  tombstones.jsonl     one per line: { id, recordKind, deletedAt, lastKnownContentHash }
```

**Guarantees:** UTF-8; ISO-8601 UTC timestamps; stable ids everywhere;
`schemaVersion` in `manifest.json` and `README.md`; per-part SHA-256 in the
manifest; provenance and revisions included. **Never** contains auth tokens,
refresh tokens, API keys, session secrets, or private keys (the bundle types
don't reference them — verified by a Phase 2 test that greps the bytes).
`chats/readable-history.md` is understandable in any text editor forever.

**Transfer:** standard iOS Share sheet → AirDrop, Save to Files (→ iCloud
Drive / On My iPhone), Mail, Messages, or any Files provider. A `.zip` opens
natively on macOS.

---

## RECOVERY SCENARIOS

For the recommended architecture (CloudKit primary · R2 backup · on-device
cache · export archive):

### A. User loses iPhone
New iPhone → sign into the same iCloud account → install EvenAI → sign in
with Apple → `CKSyncEngine` pulls the entire `PersonalAI` zone → identity,
memories, rules, projects, people, style, conversations, revisions restored;
tombstones honoured. **Data-loss window: the last successful CloudKit sync
(seconds of active use).** Dependencies: iCloud account, network.

### B. User deletes EvenAI
Reinstall → the CloudKit private DB is **untouched by app deletion** (it is
Apple's store, not the app container) → first launch pulls everything.
If the user *also* did Settings → iCloud → Manage → EvenAI → **Delete Data**,
restore from the **R2 backup** or the user's saved **export archive**.
**Data-loss window: zero (CloudKit) or since last R2 backup.**

### C. Primary database fails (CloudKit outage or record corruption)
App keeps running on the **encrypted local cache** (Phase 2, live). Sync
resumes when CloudKit recovers. A corrupted record → restore it from
on-device **version history** (`RecordRevision`) or from the R2 backup. AI
Conversation and local G2 replies are unaffected — they never touch
CloudKit. **Data-loss window: zero for the working device.**

### D. Primary provider account disappears (Apple ID locked / terminated)
CloudKit private DB becomes inaccessible. Recover from: (1) the **R2 backup**
(non-Apple), (2) the user's last **export archive** on a Mac. `.replaceAll`
into a new Apple ID's CloudKit; `client_id`s preserved so nothing
re-duplicates. **Data-loss window: since the last R2 backup / export.**

### E. EvenAI backend disappears
There is **no backend for memory** — CloudKit is client-direct. If the
optional stateless model Worker is gone, the only effect is "no cloud model"
→ the on-device model still works, memory is untouched. **Nothing to
recover.**

### F. Backup provider fails (Cloudflare / R2 down or account lost)
Primary (CloudKit) and the local cache are unaffected. Re-run the backup
when R2 recovers, or point `R2BackupStore` at B2 (S3-compatible — a config
change). The on-device export + iCloud Drive copy cover the interim.
**No memory at risk.**

### G. Both primary service and iPhone unavailable (CloudKit down AND device lost)
Restore from the **R2 backup** or the user's **export archive** onto a new
device. This is the exact scenario the non-Apple independent backup exists
for. **Data-loss window: since the last R2 backup** (weekly + on significant
change → typically hours–days).

### H. User wants to migrate away from EvenAI
Settings → Export → **Export everything** → `EvenAI-PersonalAI-YYYY-MM-DD.zip`
→ AirDrop to Mac. `chats/readable-history.md` is readable in any editor;
`memory/*.json` + `history/*.jsonl` are documented in `README.md` +
`manifest.json` (`schemaVersion`, stable ids, provenance, revisions,
tombstones). No EvenAI software or account required to read or re-use it.

---

## SECURITY

| Dimension | Recommended (CloudKit + R2 + SIWA) |
|---|---|
| **Authentication** | Sign in with Apple (OIDC, hardware-backed, no password); iCloud account for CloudKit (device-bound). No credential store to breach. |
| **Server-side user isolation** | **Structural** — a CloudKit private database *is* the user's; there is no query surface that returns another user's data. For R2, objects are keyed by a salted hash of `ownerID` and the presigned-URL Worker verifies the SIWA identity token before signing a `PUT`/`GET` scoped to that prefix. |
| **Encryption at rest** | CloudKit: Apple-managed at rest. Local cache: **application-level AES-256-GCM** (`EncryptedDocumentFile`, Phase 2) + iOS `.completeFileProtection`. R2: our payload is **already sealed client-side** before upload; R2's own SSE is a second layer. |
| **Encryption in transit** | CloudKit: Apple TLS. R2 / model Worker: TLS 1.2+ enforced. |
| **Application-level backup encryption** | Every backup/export `.paibak` is AES-256-GCM sealed on-device with the Keychain key before it leaves the device — provider-independent. The human-readable export zip is *not* encrypted (by design — the user chose to export it) and contains no secrets. |
| **Key management** | 256-bit key in the iOS Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, **own** `kSecAttrService` (`com.evenai.personalai.cache-key`), **not** iCloud-synced, **never** stored beside ciphertext, **no shared code or key with `AuthTokenStore`**. Trade-off: the key is device-local, so a raw R2 blob is unrecoverable without the device *unless* the user also exported an archive — documented; a future "wrap the backup key with a user passphrase" option closes this. |
| **Account recovery** | Handled by Apple (Apple ID recovery). EvenAI holds no recovery secret. |
| **Deletion behavior** | `deletePersonalAIAccount()` (Phase 2): delete the CloudKit zone + local cache + conversations + destroy the Keychain key (residual ciphertext becomes unrecoverable) + best-effort delete R2 objects. **Retention honesty:** CloudKit deletion is immediate; R2 objects are deleted immediately by our call but Cloudflare may retain them briefly in internal systems; user-saved export files are never touched. The Data & Backup UI states this. App Store's in-app-account-deletion requirement is satisfied. |

**Comparison of the isolation model:** CloudKit's "no cross-user surface"
is *safer than* Supabase/Firebase/Cloudflare, where isolation is RLS /
Security Rules / Worker code that a developer must write correctly and keep
correct. That is a real point in CloudKit's favour.

---

## PORTABILITY

Lock-in score (10 = fully portable, no lock-in):

| Layer | CloudKit path | Note |
|---|---:|---|
| Canonical records | **9** | `PersonalDataBundle` (Phase 2) is the authority; CloudKit stores our sealed payload verbatim; export is documented open JSON/JSONL |
| Cloud provider | 6 | CloudKit itself is Apple-only, BUT switching to Postgres is an adapter swap behind `PersonalCloudService`; `client_id`s make it lossless; export archive is the manual bridge |
| AI model provider | **10** | `PersonalAIModelProviding` seam; context builder emits vendor-neutral prompt; on-device default |
| Embedding provider | **10** | `EmbeddingProviding` seam; vectors are derived/rebuildable; `embeddingModelVersion` metadata only |
| iOS app implementation | **8** | the format is documented; `readable-history.md` needs no software; the JSON is plain |

**Requirement met:** canonical Personal AI records are exportable
independently of the cloud provider, the model provider, the embedding
provider, and the app — today, on-device, in an open format.

---

## COST — 1 USER

> **Estimated fixed infrastructure cost can remain $0** while CloudKit
> private-user storage and Cloudflare R2/Workers usage stay within their
> included/free quotas. **Costs become usage-dependent when those limits are
> exceeded.** The figures below are the expected case for one personal user,
> not a guarantee.

| Component | Provider | Expected monthly | Becomes billable when |
|---|---|---|---|
| Database (primary) | CloudKit private DB | $0 to the developer | never to the developer; the *user* pays if their iCloud quota fills |
| API / server | none | $0 | a stateless Worker is added and its traffic exceeds Workers Free (~100k req/day) → $5/mo |
| Independent backup | Cloudflare R2 | $0 | archive storage > 10 GB-month, writes > 1M/mo, or reads > 10M/mo → metered ($0.015/GB-month + op fees) |
| Vector / embedding | on-device `NLEmbedding` | $0 | if moved server-side (not planned) |
| AI model | on-device FoundationModels | $0 | if the optional cloud model is enabled |

Fixed, already paid: Apple Developer Program **$99/year** (required to ship
EvenAI at all — predates this decision).

Optional opt-in cloud model: ~**$2–5/month** for one active user
(~20 turns/day, Haiku-class, ~2k in / ~400 out ≈ $0.003–0.005/turn).
Re-confirm current Anthropic/OpenAI pricing before enabling.

**Risk factors that move a $0 estimate off $0:** backup archive size;
snapshot retention depth; R2 read/write operation volume; Workers API
traffic; future AI-model calls; any future embeddings / vector processing
moved off-device.

---

## COST — 100 USERS

Fixed infrastructure cost **can remain $0** while usage stays within the
free/included quotas; it becomes usage-dependent past them.

| Component | Provider | Expected monthly | Notes |
|---|---|---|---|
| Database | CloudKit private DBs | $0 to the developer | each user's own iCloud quota |
| API / server | none, or 1 stateless Worker | $0 | ~100 users' traffic is well under Workers Free (~100k req/day); a burst or a chatty client could still trip the $5/mo plan |
| Independent backup | R2 | $0 | ~100 MB–1 GB stored, ~hundreds of writes/day — under the 10 GB / 1M-write / 10M-read included amounts |
| Vector / embedding | on-device | $0 | — |
| AI model (only if cloud model enabled, all active) | Claude/GPT | ~$200–300 *usage* | $0 if on-device; usage-driven, not fixed |

---

## COST — 1,000 USERS

Fixed infrastructure cost is **$0 to low-single-digits**; the variable risk
grows with traffic and archive volume.

| Component | Provider | Expected monthly | Notes |
|---|---|---|---|
| Database | CloudKit private DBs | $0 to the developer | — |
| API / server | 1 Worker | $0–5 | Workers Paid $5/mo minimum once sustained traffic exceeds ~100k req/day |
| Independent backup | R2 | $0–2 | ~1–10 GB stored + ~1k writes/day sits **near the edge** of the included amounts; retention depth and archive size decide whether it tips into metered billing |
| Vector / embedding | on-device | $0 | — |
| AI model (only if cloud model enabled, active) | Claude/GPT | ~$2,000–3,000 *usage* | $0 if on-device; dominant and linear — the reason on-device stays the default |

### 10,000 users (for completeness)
CloudKit still $0 to the developer. Worker ~$5–25/mo. R2 ~$2–10/mo depending
on archive size and retention. **Fixed ≈ $10–40/mo**; model usage (if cloud)
dominates everything else and scales linearly.

**There is no hidden fixed minimum on the recommended path** (CloudKit
private storage bills the user's quota, not EvenAI; R2 and Workers have $0
minimums until their free allowances are exceeded), **but "no fixed minimum"
is not "always free."** The estimate holds only while every metered
dimension stays inside its included amount. The unavoidable recurring charge
is the $99/yr Apple Developer fee, which predates this decision.

---

## RISKS

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | `CKSyncEngine` edge cases on real hardware (account switch mid-sync, large first push, zone-not-found) differ from the simulated backend | Medium | Sync bugs → user confusion, not data loss (local cache + R2 backup) | STEP 9 physical-device test is mandatory before `.connected` ships; keep the Phase 2 simulated-backend suites as the logic spec |
| 2 | User's own iCloud storage quota fills → CloudKit writes fail for that user | Low–Medium | That user's sync stalls (local cache + R2 backup unaffected) | Surface a clear "iCloud storage full" state; the user upgrades iCloud or frees space; nothing is lost |
| 2b | Apple changes CloudKit / iCloud terms | Low | Could introduce a cap or cost | `PersonalCloudService` swap to Postgres is pre-designed; `client_id`s make migration lossless |
| 3 | **CloudKit private-DB server-side read path is unproven** — roadmap adds server-side autonomous memory processing and the secure access path proves impractical | Medium | Canonical storage must migrate to Postgres | **Blocking pre-Phase-3 task** (see *IMPORTANT SERVER-SIDE AI LIMITATION*): prove the path end-to-end or switch primary; domain model + export format stay unchanged via the `PersonalCloudService` seam |
| 4 | R2 account requires a payment card; a lapsed card → backup uploads fail silently | Medium | Independent backup stops (primary + local unaffected) | Surface "last backup failed" in the UI (Phase 2 already tracks `lastBackupErrorCode`); fall back to iCloud Drive copy; B2 is a drop-in alternative |
| 5 | Device-local backup key → a raw R2 blob is unrecoverable if the device is also lost and no export was made | Medium | Scenario G data loss if the user never exported | Prompt the user to save an export archive during onboarding and after significant memory growth; add optional passphrase-wrapped backup key (Phase 4) |
| 6 | CloudKit has no server-side query → all retrieval is on-device over the full working set | Certain | Fine at personal-memory scale (MBs); would not scale to a shared knowledge base | Not a concern for this product; documented |
| 7 | Sign in with Apple is the only identity → a user with no Apple ID cannot use the cloud | Low (iOS-only app) | That user is local-only | Local-only is a fully supported, honest state (Phase 2 `.notConfigured`) |
| 8 | Provider pricing / terms drift after this document (updated 2026-08-28) | Certain | Cost estimates could be off | Every figure names its source page; re-confirm at STEP 1 before acting |
| 9 | "CloudKit + R2" is treated as live DR before it is actually configured, uploading, and restore-tested | Medium | False sense of safety | *Backup honesty* checklist in INDEPENDENT BACKUP; UI must not claim DR until restore-from-R2 passes |

---

## IMPLEMENTATION SEQUENCE

**Not to be executed now.** Each step tagged: **$** costs money · **KEY**
needs credentials/config · **iOS** changes iOS code · **SRV** needs server
code · **LOCAL** fully testable locally.

### STEP 1 — Provider / account configuration
Enable the CloudKit **container** + entitlement in the Apple Developer
portal; add the **Sign in with Apple** capability; (later) create a
**Cloudflare account** + R2 bucket + scoped API token.
- **$**: no (CloudKit/SIWA covered by the existing $99/yr program; Cloudflare
  free — ⚠️ card may be required to open R2)
- **KEY**: yes — existing Apple Developer account for CloudKit/SIWA; a **new
  Cloudflare account** only when STEP 6b starts
- **iOS**: yes (entitlements file, capabilities)
- **SRV**: no
- **LOCAL**: partial — CloudKit dev environment works in the simulator with a
  sandbox iCloud account; the container config itself is portal-only

### STEP 2 — Production schema (CloudKit record types + zone)
Define `Memory` / `Rule` / `Conversation` / `Message` / `StyleProfile` record
types (payload blob + `updatedAt` / `deletedAt` / `recordKind` fields) in the
CloudKit **Development** environment by saving sample records, then **promote
to Production** in the CloudKit console.
- **$**: no · **KEY**: Apple Developer account · **iOS**: yes (the CKRecord
  mapping lives in the adapter) · **SRV**: no · **LOCAL**: yes (dev env)

### STEP 3 — Production `PersonalCloudService` adapter
`CloudKitPersonalCloudService` implementing `pull` / `push` / `snapshot` /
`deleteAllData` via `CKSyncEngine` + `CKModifyRecordsOperation`; map
`SyncRecordEnvelope` ↔ `CKRecord`; `serverRecordChanged` →
`PersonalConflictResolver`; `CKServerChangeToken` → cursor. Wire
`PersonalAIContainer.make(cloudService:environment: .connected)`.
- **$**: no · **KEY**: no (uses the signed-in iCloud user) · **iOS**: yes
  (one new file + one wiring line) · **SRV**: no · **LOCAL**: yes — most
  suites keep the mock; a small `@Suite` of real-CloudKit integration tests
  runs against the dev environment behind a scheme flag

### STEP 4 — Authentication (Sign in with Apple)
`ASAuthorizationController` flow; persist the stable `user` id; feed it to
the Phase 2 `PersonalOwnerBox` via `PersonalAIService.updateOwner()`
(replacing the `AuthState.currentUser` source). No auth server.
- **$**: no · **KEY**: Apple Developer (SIWA capability) · **iOS**: yes ·
  **SRV**: no (until a backend exists; then verify the identity token
  server-side) · **LOCAL**: partial — SIWA needs a device/simulator with an
  Apple ID; the identity-handoff logic is unit-testable with a fake

### STEP 5 — Migration / first sync
On upgrade from `.notConfigured` → `.connected`: mark the whole local
`PersonalDataBundle` `.pendingPush`, run one `CKSyncEngine` cycle (push all →
pull), verify counts. Idempotent; `client_id` → `CKRecord.recordName`.
- **$**: no · **KEY**: no · **iOS**: yes (a one-time migration trigger) ·
  **SRV**: no · **LOCAL**: yes (dev CloudKit; the sync logic is already
  covered by the simulated-backend suites)

### STEP 6 — Independent encrypted backup
- **6a — iCloud Drive convenience copy** (no new account): write the sealed
  `.paibak` to a ubiquity `EvenAI/Backups/` folder on the backup schedule.
  - **$**: no · **KEY**: no · **iOS**: yes (an `iCloudDriveBackupStore:
    BackupStore`) · **SRV**: no · **LOCAL**: yes
- **6b — Cloudflare R2 (the real independent backup)**: `R2BackupStore:
  BackupStore` uploads via a presigned URL from a one-route Worker
  (`POST /backup-url`, auth = SIWA identity token, returns a `PUT` URL
  scoped to `<ownerHash>/`).
  - **$**: R2 ~$0 at this scale (⚠️ card-on-file likely); Worker $0 free
  - **KEY**: **yes — Cloudflare account + R2 bucket + API token (the first
    genuinely new external credential)**
  - **iOS**: yes (`R2BackupStore` conformer)
  - **SRV**: yes (~30-line Worker)
  - **LOCAL**: yes — client tested against `LocalDirectoryBackupStore` /
    MinIO; Worker tested with `wrangler dev`

### STEP 7 — Export to Mac
`PersonalDataArchiveBuilder` extends the Phase 2 exporter: renders
`chats/readable-history.md`, emits `*.jsonl` / `*.json`, writes
`manifest.json` + `README.md`, zips, hands to the Share sheet.
- **$**: no · **KEY**: no · **iOS**: yes (archive builder + Data & Backup
  buttons) · **SRV**: no · **LOCAL**: yes — fully (golden-file tests on the
  archive structure and the rendered markdown)

### STEP 8 — Restore verification (automated)
Round-trip tests: CloudKit dev env → wipe local → restore; R2 mock → restore;
export zip → import. Assert stable ids, revisions, tombstones, no dupes.
- **$**: no · **KEY**: Apple Developer (dev CloudKit) · **iOS**: test-only ·
  **SRV**: no · **LOCAL**: yes

### STEP 9 — Physical new-iPhone / reinstall test
Real devices: create data on device A → confirm CloudKit sync → device B
(same Apple ID) install → confirm full restore. Then delete app + "Delete
Data" in iCloud settings → restore from R2 / export archive. Account-switch
mid-sync. Airplane-mode reconciliation.
- **$**: no (needs a second iOS device or a wipe) · **KEY**: a real Apple ID
  · **iOS**: no (verification) · **SRV**: no · **LOCAL**: **NO — the one
  step that genuinely requires physical hardware**

### STEP 10 — Production readiness audit
CloudKit schema promoted to Production; entitlements correct; privacy
nutrition labels / privacy manifest updated for CloudKit data types;
in-app account-deletion path verified end-to-end (App Store requirement);
backup encryption + "no secrets in export" re-verified; diagnostics clean;
`.connected` UX wording review; `PersonalCloudService` real-CloudKit
integration suite green on a device.
- **$**: no · **KEY**: Apple Developer (App Store Connect) · **iOS**:
  possibly minor (privacy manifest, deletion UX copy) · **SRV**: only if the
  Worker shipped · **LOCAL**: partial

---

## FIRST EXTERNAL ACCOUNT / CREDENTIAL REQUIRED

**Strictly first (configuration, not a new account, $0):** enable the
**CloudKit container** and the **Sign in with Apple** capability in the
**existing** Apple Developer account (App Store Connect / Certificates,
Identifiers & Profiles). ~10 minutes, no cost, no card.

**First genuinely new account ($0, but a card may be required to open it):**
a **Cloudflare account** with an **R2 bucket** and a scoped **API token** —
needed only at **STEP 6b** (the independent off-Apple backup). Everything
through STEP 6a (CloudKit primary + sync + iCloud Drive convenience backup +
export) is buildable and testable with **only the existing Apple Developer
account**.

**Not required at any step in this plan:** Supabase, Firebase, a Postgres
host, a vector database, an embedding vendor, or an AI-model API key (the
model stays on-device; a cloud model and its key are a separate, later,
opt-in decision).

---

*Decision document only. No production code modified. No provider account
created, nothing deployed, nothing purchased. Committing this file records
the architecture decision — it does not make any of it operational. Phase 3
(G2) not started. The CloudKit server-side-access proof is a blocking
prerequisite for Phase 3.*
