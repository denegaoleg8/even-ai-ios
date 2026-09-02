# Phase 2 — R2 / Cloudflare Worker Deployment Readiness

**Planning + local documentation + local test hardening only.** Nothing in
this document has been deployed. No Cloudflare account resource, R2 bucket,
KV/D1/Durable Object namespace, billing, credential, token, or real network
call was created or enabled in producing it.

- **Baseline:** `275a850 Harden R2 backup path authorization and add Worker source`
  (`HEAD == origin/main`).
- **Companion:** `PHASE2_R2_PRODUCTION_PATH.md` — the committed local
  implementation this plan makes deployment-ready. That doc's §§1–14 remain
  authoritative for what exists in code.
- **This doc adds:** the deployment-time contracts (auth, owner-tag,
  replay/idempotency, presigned URL, namespace, finalization, integrity,
  retention, deletion, key management, observability), the cost/billing gate,
  a strict gate sequence, a rollback plan, and the local contract tests that
  pin the pieces provable without real infrastructure.

---

## 0. STATUS LEGEND

| Tag | Meaning |
|---|---|
| **IMPLEMENTED LOCALLY** | real code in the repo, runs in CI, no infra |
| **TESTED LOCALLY** | covered by a green test that needs no infra |
| **DESIGNED / SPECIFIED** | contract written here; code not (fully) written |
| **REQUIRES REAL CLOUDFLARE** | cannot be built or verified without a live account/resource |
| **REQUIRES USER APPROVAL** | creates a paid/billable/account-level resource — needs explicit sign-off |
| **NOT VERIFIED YET** | no real-world evidence exists |

### One-line status of the whole path

| | |
|---|---|
| REAL R2 BUCKET CREATED | **NO** |
| WORKER DEPLOYED | **NO** |
| REAL KV / D1 / DURABLE OBJECT RESOURCE | **NO** |
| REAL AUTH CONFIGURED | **NO** |
| REAL CREDENTIALS ADDED | **NO** |
| BILLING CONFIGURED | **NO** |
| REAL NETWORK BACKUP VERIFIED | **NO** |
| REAL OFF-DEVICE DURABILITY VERIFIED | **NO** |
| REAL R2 RESTORE VERIFIED | **NO** |
| RECOVERY-KEY MECHANISM (local: type + envelope wrapping + tests) | **YES** — see `PHASE2_PERSONAL_AI_RECOVERY_KEY.md` |
| RECOVERY-KEY CLOUD ESCROW | **NO — deferred** |
| REAL NEW-IPHONE RESTORE VERIFIED | **NO** |
| VERSIONED `backup/v1/` OBJECT NAMESPACE (local) | **YES** — `BackupObjectNamespace`, adopted in `R2BackupStore` |

---

## 1. CURRENT IMPLEMENTATION — WHAT IS WHAT

### Already implemented locally (Swift, shipping build, dormant)

| Piece | State |
|---|---|
| `BackupCredentialProviding` / `BackupObjectTransport` / `BackupStore` seams | IMPLEMENTED LOCALLY — provider-neutral, no Cloudflare types |
| `R2BackupStore` | IMPLEMENTED LOCALLY — private init; `authorized(...)` needs `RemoteBackupCompositionAuthority` (mintable only in `R2ProductionBackupAdapter.swift`); `.dormant` reaches no network |
| `R2ProductionBackupAdapter` | IMPLEMENTED LOCALLY — the one composition boundary; `.inert` is the shipping posture |
| `BackupAuthorizationClient` | IMPLEMENTED LOCALLY — client chokepoint: namespace + well-formedness + expiry + **server-authoritative scope** guard (`covers()` is a real check, R2 fix §14 of the companion doc) |
| `BackupAuthorizationScope` + `keyIsWellFormed` / `keyIsInOwnerNamespace` | IMPLEMENTED LOCALLY — path-traversal / control-char / length / doubled-separator rejection; **version-prefix-aware** (strips only a recognised `backup/v<N>/`) |
| `BackupObjectNamespace` — the one definition of the **versioned** `backup/v1/` layout | IMPLEMENTED + TESTED LOCALLY — validating key generation, a non-guessing parser, unknown-version-fails-safe; `R2BackupStore` uses it for every key |
| Recovery key (`PersonalAIRecoveryKey`, `BackupKeyWrapping`, `"EAPB2"` wrapped envelope, `RecoveryKeyStore` seam) | IMPLEMENTED + TESTED LOCALLY — see `PHASE2_PERSONAL_AI_RECOVERY_KEY.md`. **Not wired into `PersonalAIContainer.live`; no UI; no escrow; new-iPhone restore not verified.** |
| `WorkerBackupCredentialProvider` | IMPLEMENTED LOCALLY, **instantiated nowhere in a shipping build** — bound to `authenticatedUserID`; requires the Worker's server-derived scope; refuses foreign owner / scope-less response |
| `BackupOwnerTag.tag(_:)` | IMPLEMENTED LOCALLY — `ownerTag v1`, canonical (see §4) |
| Encryption (`AESGCMBackupEncryption`, `EncryptedBackupEnvelope`) | IMPLEMENTED LOCALLY — AES-256-GCM, Keychain device-only key, ciphertext-only off device |
| Coordinator verify-before-publish, retention 3/7/4/3, restore validate-before-mutate | IMPLEMENTED LOCALLY |

### Simulated locally (tests only, no infra)

| Piece | Simulated by |
|---|---|
| The authorizer Worker + R2 edge | `FakeBackupAuthorizationServer` (identity → server-derived tag, least-privilege grants, expiry, single-use mutation grants, plaintext-leak detector) |
| Presigned-URL transport | `InMemoryBackupObjectTransport`, `FakePresignProvider` |
| Worker HTTP contract | `cloudflare/backup-worker/` under `@cloudflare/vitest-plugin` (Miniflare) — R2 + KV simulated in memory |

### Deployment-only (cannot exist locally)

- Real R2 bucket, real R2 S3 credential, real Worker deployment, real KV/D1/DO
  namespace, real identity-token issuer + JWKS, real presigned-URL semantics,
  real cross-user isolation against a live bucket, real durability, real
  restore-on-new-device.

### Intentionally not implemented

- **Atomic request-replay / idempotency store** — the `cloudflare/backup-worker/src/replay.ts`
  model is a coarse, **non-atomic get-then-put** KV heuristic with **no client
  nonce**. It is explicitly *not* production replay protection (see §5). It
  runs nowhere.
- **A real identity provider** — `auth.ts` is a dev-only stub gated behind
  `ALLOW_DEV_IDENTITY`, never enabled.
- **Server-side owner-tag secret (HMAC v2)** — deliberately not introduced
  (see §4); a Worker-only secret would only guarantee client/Worker
  disagreement.
- **Recovery-key cloud escrow / iCloud-Keychain sync / passphrase KDF /
  recovery UI** — the recovery-key *mechanism* is implemented (§13.A,
  `PHASE2_PERSONAL_AI_RECOVERY_KEY.md`); these extensions are deferred.

---

## 2. REAL PRODUCTION TRUST BOUNDARY

```
 iOS app                         EvenAI backup authorizer                     R2
 ───────                         ─────── (Cloudflare Worker) ───────          ──
 • holds NO R2 secret            • holds the R2 S3 credential (bucket-scoped   • object
 • holds NO Cloudflare token       Object Read&Write) — the ONLY place it       store
 • holds a short-lived,            exists                                     • sees only
   VERIFIED EvenAI identity      • verifies the identity token's signature      ciphertext
   token for the current user      against a published JWKS                      (.eapb)
 • derives a LOCAL candidate     • derives the authoritative ownerTag from
   ownerTag for offline key        the VERIFIED subject via ownerTag v1
   construction, but treats      • NEVER trusts a caller-supplied userID or
   the Worker's returned scope     ownerTag as authority — only cross-checks
   as authoritative               • issues ONE grant = ONE operation on ONE
                                    key under <ownerTag>/…, TTL minutes
                                  • consumes a request idempotency key
                                    atomically (§5) for mutations
                                  • logs allow-listed fields only (§14)
```

### Value ownership

| Value | Definition | Owned / authoritative at |
|---|---|---|
| **authenticated identity** | the verified token and its claims (`iss`, `aud`, `sub`, `exp`) | **Worker** — validates signature + claims; iOS only *carries* the token |
| **PersonalAI user identity** (`canonicalUserID`) | the stable `sub` of the verified token; the SAME string iOS uses as its Personal AI user id | **Worker** derives it from the verified token; iOS uses its local copy only for offline key construction and must accept the Worker's if they differ |
| **opaque backup owner tag** (`ownerTag`) | `ownerTag v1 = SHA-256(DOMAIN ‖ canonicalUserID)` (§4) | **Worker** (authoritative, from verified subject). iOS may compute a candidate; the Worker's `scope.ownerTag` wins. |
| **backup ID** | client-generated UUID per snapshot; catalog dedupe key | **iOS** (created on device); immutable once catalogued |
| **object key** | `backup/v1/<ownerTag>/catalog.json` or `backup/v1/<ownerTag>/objects/<bundleVersion>-<tier>-<backupID>.eapb` (§7) | **iOS** constructs via `BackupObjectNamespace` (validating); **Worker** re-validates against the derived `ownerTag` and refuses anything outside it, including an unknown namespace version |
| **operation scope** | `{ownerTag, objectKey, operation}` — exactly one verb on one key | **Worker** issues it from the verified identity; iOS `BackupAuthorizationClient` refuses to use a grant that does not `cover` the exact request |

**Rule:** a caller-supplied user id / owner tag is *intent*, never authority.
The Worker's decision inputs are: the verified token, and the object key
(re-validated against the derived tag). Nothing else.

---

## 3. AUTHENTICATION CONTRACT  (DESIGNED / SPECIFIED — no real provider wired)

Provider-independent. The Worker depends on an **interface**, not on a vendor.

### Token assumptions

| Field | Contract |
|---|---|
| **issuer (`iss`)** | a single configured HTTPS issuer URL (Worker secret `AUTH_ISSUER`). The Worker rejects any other `iss`. |
| **audience (`aud`)** | a fixed string identifying this backup API (e.g. `evenai-personal-ai-backup`). Worker secret `AUTH_AUDIENCE`. Rejected if absent/mismatched. |
| **subject (`sub`)** | stable, opaque, non-reassigned per user. This IS `canonicalUserID`. Must never be an email / phone / username. If the upstream IdP only issues email-shaped subjects, the auth layer MUST map them through a stable opaque id first (documented, not invented here). |
| **expiration (`exp`)** | required. Max accepted lifetime: **15 min** (configurable `AUTH_MAX_TTL`). A token without `exp`, or with `exp` beyond `iat + AUTH_MAX_TTL`, is rejected. |
| **issued-at (`iat`)** / **not-before (`nbf`)** | honoured if present. |
| **clock skew** | ±60 s tolerance on `exp` / `nbf` / `iat` (configurable `AUTH_SKEW_SECONDS`). |

### Signature validation

- The Worker fetches the issuer's **JWKS** (`AUTH_JWKS_URL`) and caches keys by
  `kid` with a bounded TTL (≤ 10 min) and a hard refresh on an unknown `kid`.
- Supported algs: an allow-list (`AUTH_ALGS`, default `["RS256","ES256"]`).
  `alg: none` and symmetric algs are rejected outright.
- JWKS fetch failure ⇒ **fail closed** (503, no grant), never fail open.

### PersonalAI user identity derivation

`canonicalUserID := verifiedToken.sub` — verbatim, no transformation. The iOS
client's Personal AI user id MUST equal this string for offline-constructed
object keys to match the Worker's authoritative namespace. This equality is a
**Gate G** check.

### Account switching

- Each `/presign` call is independently authenticated; there is no session.
- A grant is bound to `sub` via the derived `ownerTag`; a grant minted for
  user A is unusable for user B (different namespace, and B never holds A's
  signed URL). Proven locally: `staleGrantAcrossIdentitySwitch`,
  `accountSwitchProducesDisjointNamespace`.
- On device, switching Personal AI identity swaps the `authenticatedUserID`
  the credential provider is constructed with (composition-time), so a
  post-switch `presign` is bound to the new identity or refused.

### Disabled / deleted accounts

- The IdP MUST stop issuing tokens for a disabled/deleted account, and SHOULD
  expose a revocation signal. The Worker treats **token expiry as the
  revocation bound** (≤ 15 min window) and, if `AUTH_REVOCATION_URL` is
  configured, checks a deny-list / introspection endpoint per request.
- A verified token whose `sub` is on the Worker's local **tombstone list**
  (populated by the account-deletion flow, §12) is rejected even if
  cryptographically valid.

### If no EvenAI auth provider is currently live

Then **this section is the contract**, not a wiring task. Gate G cannot pass
until a real issuer + JWKS + opaque stable `sub` exist. Do not invent a
signing key or a fake issuer to "unblock" — that is the exact failure mode
the project has repeatedly refused.

---

## 4. OWNER-TAG DERIVATION CONTRACT  (IMPLEMENTED LOCALLY + TESTED LOCALLY, cross-language)

The prior audit's blocker: **client and Worker owner-tag derivation must be
proven equal before deployment.** They now are, in code and in tests.

### The one canonical algorithm — `ownerTag v1`

```
DOMAIN         = utf8("evenai.personal-ai.backup.owner-tag.v1")     // fixed, ASCII, NOT secret
ownerTagV1(id) = lowerhex( SHA-256( DOMAIN ‖ utf8(id) ) )           // 64 hex chars
```

- `id` = `canonicalUserID` (§3): the verified token `sub`, identical on both sides.
- No separator byte: `DOMAIN` is a fixed known prefix ⇒ `id → tag` is injective
  up to SHA-256; distinct ids cannot collide through the prefix. This mirrors
  the Swift `Data(domain.utf8) + Data(id.utf8)` construction exactly.
- Deterministic, opaque, stable per user, distinct across users, no
  email/name/PII, not trivially reversible (reveals nothing about input length).

### Why no secret, and why not HMAC (yet)

The domain string is **compiled into the iOS binary**. A Worker-only secret
salt would make the two sides derive **different** tags — which is the bug. So
v1 is secret-free by necessity. Tag unlinkability rests on `canonicalUserID`
being unpredictable **and** every stored object being ciphertext — an
acceptable posture given the threat model (documented in `EncryptedBackupEnvelope.swift`).

**`ownerTag v2` (DESIGNED, not implemented):** `HMAC-SHA256(WORKER_OWNER_TAG_KEY,
canonicalUserID)`, computed **only** on the Worker, returned to the client in
`scope.ownerTag`, and **never recomputed on device**. This requires the client
to fetch its tag once (a `.head`/bootstrap `presign`) and cache it, since it
can no longer construct object keys offline. Adopt at a future gate if
unlinkability-without-a-secret is judged insufficient; it is a clean upgrade
because the client already treats `scope.ownerTag` as authoritative.

### Implementations (byte-identical)

| Side | Location |
|---|---|
| Swift | `EvenAI/Infrastructure/PersonalAI/Backup/EncryptedBackupEnvelope.swift` → `BackupOwnerTag.tag(_:)` |
| Worker | `cloudflare/backup-worker/src/ownerTag.ts` → `deriveOwnerTagV1(_)` |

### Cross-language test vectors  (non-secret fixtures — keep both lists identical)

| input | ownerTag v1 (SHA-256 hex) |
|---|---|
| `user-A` | `d5f24b52433196da1ad2febc17e66dabedc36cb2ffdd9ea6cdcf3f833d1cc97a` |
| `user-B` | `1c32fe9cff154e280ea15e0c5e16c2971bc96d0ed5f11c405826936f70b919be` |
| `dev:user-A` | `07728a26cbf2f8e5f0b46fd2faf83c93c3aa1bbe74f5c5c656b00c6cf0cfca1f` |
| `00000000-0000-0000-0000-000000000000` | `ed31e07852bf2b78a069ed3e1d463cea6ef329897fc2c5df06e13c92ff01b047` |
| `apple:001234.abcdef0123456789.4242` | `d705978cd84758a519aa6be52eb077e3a4cf6eebd6420d3d6da22f454ad81e4f` |
| `""` (empty) | `4d39a7717a77088a526b6705c8b6df986d4f1f39c2557bb1ddd13930bf9f09a1` |
| `u` | `0bd54f91e37a90c4d1d0392328a932f1490c03fc5d289a614591d61f0683db9e` |
| `apple:…` / unicode `éè-user` | `7bf412a428cb37dc7435a1e803038b84868b0f74b97c73a6ae8134e609e039c8` |
| 256×`a` | `91870690d1fdab8952fe0b1214493484d3fb4f350728ff656384bd5bf2036c83` |

- Swift: `R2DeploymentContractTests.ownerTagV1CrossLanguageVectors`
- Worker: `cloudflare/backup-worker/test/owner-tag-vectors.test.ts`

Both suites recompute the tag and assert equality with these constants. **A
drift in either implementation fails its vector test — this is the Gate-G
proof.**

**OWNER TAG CROSS-LANGUAGE VERIFIED: YES** (against fixtures; a real
`canonicalUserID` from a real token is a Gate-G item).

---

## 5. REPLAY / NONCE / IDEMPOTENCY DESIGN  (DESIGNED — atomic control NOT implemented, NOT verified)

### Requirements the real control must meet

- A unique **idempotency key** per logical mutation attempt (put object, put
  catalog, delete object), reused verbatim across retries of the *same* attempt.
- Bound to: authenticated `sub`, `operation`, `objectKey`, and a bounded
  lifetime (≥ grant TTL, ≤ 24 h).
- **Atomic consume-or-detect:** the first request with a given
  `(sub, operation, objectKey, idempotencyKey)` proceeds; a duplicate is
  rejected `409` **or** returns the original result — with **no get-then-put
  race**.
- A lost-response retry (client didn't see the 200) reusing the same key MUST
  NOT double-apply and MUST NOT corrupt catalog state.

### Idempotency-key format  (SPECIFIED + TESTED LOCALLY)

Lowercase **UUIDv4**, 36 chars, `8-4-4-4-12`, version nibble `4`, variant
`10xx`. Validator pinned in `R2DeploymentContractTests.idempotencyKeyFormatContract`
so the client and Worker agree before the wire field exists. Wiring it into
`PresignRequestBody` (Swift) + `types.ts` (Worker) is a Gate-E task (additive
optional field).

### Cloudflare primitive — atomicity assessment

| Primitive | Atomic "set-if-absent"? | Verdict |
|---|---|---|
| **Workers KV** | **NO.** Eventually consistent, last-write-wins, no compare-and-swap. `get` then `put` has a real race window. | **Insufficient for strict idempotency.** The current `replay.ts` uses exactly this and is therefore a heuristic only. |
| **D1 (SQLite)** | **YES** — `INSERT … ON CONFLICT DO NOTHING` in a transaction; check `meta.changes`/`rowsWritten`. Single-writer semantics per DB. | **Recommended for v1.** Has a usage-based free allocation (MUST be re-verified — §15). Adequate throughput for per-user backup cadence. |
| **Durable Objects** | **YES** — single-threaded per object; a DO keyed by `ownerTag` gives serialized `consume(key)` and can also serialize catalog writes. | **Recommended if** per-owner write serialization or higher throughput is needed. **Requires the Workers Paid plan** (MUST be re-verified — §15). |

**Decision (DESIGNED):** v1 uses **D1** with a table
`idempotency(sub_hash, operation, object_key, idem_key, created_at, result_json,
PRIMARY KEY(sub_hash, operation, object_key, idem_key))` and
`INSERT OR IGNORE` + `changes()` to consume atomically; a TTL sweep (or
`created_at` filter + periodic delete) bounds growth. Upgrade to a per-`ownerTag`
Durable Object if contention or catalog-write serialization demands it.

**Do not claim replay protection is solved until it is backed by D1 or a
Durable Object and verified at Gate H/K.** Until then: **ATOMIC REPLAY CONTROL
IMPLEMENTED LOCALLY: NO. REAL ATOMIC REPLAY CONTROL VERIFIED: NO.**

---

## 6. PRESIGNED URL MODEL  (DESIGNED / SPECIFIED)

| Property | Contract |
|---|---|
| **TTL** | shortest practical: **300 s** default (`GRANT_TTL_SECONDS`), floor 60 s, ceiling 900 s. `put`/`delete` at the low end. |
| **operation scope** | the signed method is exactly one of `PUT` / `GET` / `DELETE` / `HEAD`; `list` is served by the Worker, not by a presigned URL. |
| **object scope** | the signature covers exactly one object key. No prefix/wildcard signing. |
| **owner scope** | the key is under `<derivedOwnerTag>/…`, re-validated server-side against the verified identity. |
| **transport** | HTTPS only. The R2 S3 endpoint is `https://`; the Worker refuses to emit a non-HTTPS URL. |
| **no logging** | the signed URL is **never** logged, echoed outside the 200 response body, put in an error message, or sent to analytics. It carries a live `X-Amz-Signature` — logging it == logging a bearer credential. |
| **no referrer leak** | the URL is used only by `URLSessionBackupObjectTransport` with no `Referer` header and no web context; it never appears in a WebView / `<a href>` / redirect. |
| **mutation single-use (expectation)** | enforced by the **idempotency key** at the Worker (§5), not by R2 (S3 presigned URLs are inherently multi-use until expiry). Modelled locally as a `409` on grant reuse. |
| **expiration enforcement** | R2 rejects an expired signature (`403`); the client also refuses an already-expired grant before use (`BackupAuthorizationClient`, `PresignedBackupRequest.isExpired`). |

### If a presigned URL leaks

It is a **bearer capability** for exactly `(one operation, one object,
until expiry)`. Whoever holds it can perform that one operation on that one
ciphertext object until the TTL lapses. They **cannot**: read another object,
another user's data, escalate to a different operation, or obtain plaintext
(the object is `.eapb` ciphertext; the decryption key never leaves the device).
Mitigations: short TTL, HTTPS, never logged, per-object/per-op scope, and the
guarantee that a caller can never *obtain* a grant outside its own namespace.
**R3 remains: a presigned URL is a short-lived bearer capability. This is
inherent and is not "fixed".**

---

## 7. OBJECT NAMESPACE  (IMPLEMENTED LOCALLY + TESTED LOCALLY — versioned)

### Canonical layout — `backup/v1/`

```
backup/v1/<ownerTag>/catalog.json                          the committed BackupHandle list (restore source of truth)
backup/v1/<ownerTag>/objects/<bundleVersion>-<tier>-<backupID>.eapb  one sealed snapshot each
```

Defined **once** in `EvenAI/Core/Domain/PersonalAI/BackupObjectNamespace.swift`
(`currentVersion = 1`, `recognisedVersions = {1}`) — there is no `"backup/v1"`
string literal elsewhere. `R2BackupStore` builds every key through it; the
Worker mirrors the version handling in `cloudflare/backup-worker/src/scope.ts`.

- `<ownerTag>` = `ownerTag v1` hex — no PII, no raw user id, no email, no
  memory text, no person/project names.
- **Validating generation:** `objectKey(...)` / `catalogKey(...)` *throw*
  rather than emit a key with a malformed owner tag, an unknown tier, a
  negative bundle version, or an unsafe `backupID` (path separators real *or*
  percent-encoded — `%2F` / `%5C` / `%2E` — `.` / `..`, control chars,
  over-long). Tested: `BackupObjectNamespaceTests.rejectsUnsafeBackupID`,
  `rejectsMalformedOwnerTag`.
- **`keyIsWellFormed` / `keyIsInOwnerNamespace`** additionally reject empty,
  `>512` bytes, leading `/`, `//`, trailing `/`, `.` / `..` segments — on both
  the client (`BackupAuthorizationScope`) and the Worker (`scope.ts`), kept in
  sync by inspection + the cross-language vectors in
  `object-namespace.test.ts` ↔ `BackupObjectNamespaceTests`.
- **Unknown versions fail safely.** `keyIsInOwnerNamespace` strips only a
  *recognised* `backup/v<N>/` prefix; a `backup/v2/…` key keeps its prefix,
  so it can never match the owner namespace and no grant is issued for it.
  `BackupObjectNamespace.parse` returns `nil` for an unknown version — it is
  never reinterpreted. Tested: `unknownVersionFailsSafely`,
  `object-namespace.test.ts`.
- **Future `backup/v2/` coexistence:** add `2` to `recognisedVersions` on
  both sides and give it its own reader — v1 keys are undisturbed.
- Deterministic: `(ownerTag, bundleVersion, tier, backupID)` → one key.
- No cross-user collision: distinct `sub` → distinct `ownerTag` segment
  (injective, §4).

### No migration

There is **no production R2 data**, so there is nothing to migrate — the
versioned layout is simply what every object written from now on uses. A bare
`<ownerTag>/…` key (no version prefix) is still *accepted* by
`keyIsInOwnerNamespace` because the test doubles use it and there is no real
data to break; `R2BackupStore` itself never writes one.

### Cleanup safety

- A `.staged` object (uploaded, not in `catalog.json`) is invisible to
  restore and pruned (§11).
- Deletion removes the object **and** its catalog entry.

**No plaintext Personal AI content ever appears in an object key or in
`catalog.json`** — proven: `remoteCatalogCarriesNoPlaintextOrPII`,
`objectKeyNamespaceContract`, `opaqueObjectKeys`.

---

## 8. BACKUP FINALIZATION PROTOCOL  (IMPLEMENTED LOCALLY; atomic-store parts DESIGNED)

State (not a stored enum — `catalog.json` is the source of truth):

```
pending      client intends to back up; nothing uploaded
  ↓  presign(.put, objectKey) → PUT ciphertext
uploaded     object bytes in R2, NOT in catalog.json  (== ".staged" / orphan)
  ↓  presign(.put, catalogKey) → rewrite catalog with the new handle
catalogued   handle in catalog.json
  ↓  coordinator: GET back, decrypt, re-validate, owner-check
finalized    lastBackupSucceededAt advanced
  ↓
visible / restorable   listBackups() returns it; loadLatestBackupBundle can select it
```

`listBackups()` returns **only catalogued handles**, so `uploaded`-but-not-catalogued
objects are never restore candidates.

| Scenario | Behaviour |
|---|---|
| upload OK, **finalize (catalog PUT) response lost** | client retries with the **same idempotency key** → Worker consumes it once; catalog ends with exactly one entry for the handle; no duplication |
| finalize repeated (explicitly) | id-keyed catalog upsert → one entry (`duplicateUploadNoDuplication`) |
| partial upload (object PUT interrupted) | transport throws → catalog untouched → previous verified backup stays the restore target (`stagedObjectNotRestorable`, `interruptedUploadKeepsLastVerified`) |
| corrupted object at rest | size / `ciphertextSHA256` / GCM-tag checks fail on read-back → not finalized; on restore → rejected pre-mutation (`corruptedObjectRejected`) |
| duplicate backup ID | catalog dedupes by `id`; object key is a function of `id` so a re-put overwrites the same key |
| account switch mid-upload | the in-flight grant is bound to the old `ownerTag`; a post-switch `presign` is bound to the new identity → the interrupted upload is a harmless orphan under the old namespace, pruned by that account's retention |
| authorization expires mid-flow | next `presign` returns `expired` / edge returns `403` → client re-requests; no partial catalog write |
| orphan object cleanup | §11 |

**Atomicity of the catalog rewrite itself** across two concurrent devices is a
Gate-E concern: v1 relies on backup cadence making concurrent writes rare +
the idempotency store; a per-`ownerTag` Durable Object serialises catalog
writes if needed.

---

## 9. INTEGRITY MODEL  (IMPLEMENTED LOCALLY + TESTED LOCALLY)

Three independent layers, none requiring the server to hold a key:

| Layer | Covers | Where |
|---|---|---|
| **AEAD (AES-256-GCM)** | authenticity + confidentiality of the sealed bundle; tamper ⇒ `openFailed` | on device only |
| **Envelope object hash** | `ciphertextSHA256` + `ciphertextLength` in the `EncryptedBackupEnvelope` header → truncation / bit-rot caught **before** a decrypt is attempted | on device, header is not secret but content-free |
| **Bundle manifest checksum** | `BackupManifest.checksum` = SHA-256 of the canonical bundle JSON minus the manifest → structural integrity of the decrypted payload | inside the sealed bundle |

What is authenticated / bound:

- **encrypted payload** — GCM tag + `ciphertextSHA256`.
- **manifest** — `checksum` (self-referential exclusion).
- **archive/envelope version** — `EAPB` + `'1'` magic; `encryptionScheme`
  (`"AES-GCM-256"`); `bundleSchemaVersion`; `bundleVersion`.
- **owner tag** — in the envelope header (salted hash) **and** re-checked on
  restore against the importing identity (`PersonalDataImporter` owner match).
- **backup ID / size / createdAt** — in `catalog.json` as `BackupHandle`
  fields; `sizeBytes` is checked against the fetched object on `get`.

Distinctions:
- **AEAD integrity** ≠ **object/transport hash integrity** ≠ **manifest
  integrity** — a failure in any one rejects the restore with local data
  untouched. The remote never needs, receives, or asks for the decryption key
  (`authorizerNeverNeedsDecryptionKey`, `serverSeesOnlyCiphertext`).

The remote `catalog.json` carries **only** `{version, handles:[{id, createdAt,
bundleVersion, sizeBytes, checksum, tier}]}` — proven by
`remoteCatalogCarriesNoPlaintextOrPII`.

---

## 10. RATE LIMITS / ABUSE CONTROLS  (DESIGNED / SPECIFIED — configurable, no billing commitment)

All values are **defaults**, set as Worker vars / Cloudflare rules, tunable
without a code change.

| Control | Default | Enforced by |
|---|---|---|
| `/presign` requests per identity | 60 / 5 min | Cloudflare rate-limiting rule keyed on `sub` hash, or a D1 counter |
| uploads (`put` grants) per identity | 50 / day | D1 counter per `(sub_hash, day)` |
| downloads (`get` grants) per identity | 500 / day | same |
| deletes per identity | 100 / day | same |
| max object size | 25 MB (`MAX_OBJECT_BYTES`) — signed URL carries a `Content-Length` ceiling; Worker rejects a `put` grant request declaring more | Worker + R2 |
| max storage per owner | 250 MB (`MAX_OWNER_BYTES`) — checked from a D1 running total before issuing a `put` grant | Worker + D1 |
| max catalogued backups per owner | 20 (retention 3/7/4/3 keeps it well under) | coordinator + Worker sanity check |
| max pending (uncatalogued) objects per owner | 5 — refuse new `put` grants beyond this until orphan sweep runs | Worker + D1 |
| malformed request | `400`, no grant, counted toward an abuse score | Worker |
| enumeration / brute force | object keys are unguessable (`ownerTag` is a SHA-256 of an unpredictable `sub`); a `get` for a non-existent key returns the same `403`/`404` shape as any other; repeated `403`s from one identity trip the rate limiter | Worker |

No value here implies a paid tier; §15 gates any spend.

---

## 11. RETENTION / CLEANUP  (coordinator: IMPLEMENTED LOCALLY · server sweep: DESIGNED)

| Item | Policy |
|---|---|
| complete-backup retention | `PersonalAIBackupCoordinator`: keep 3 incremental / 7 daily / 4 weekly / 3 monthly; prune oldest-beyond-keep after every successful, finalized backup |
| incomplete-upload TTL | an `uploaded`-not-catalogued object older than **24 h** is an orphan (`ORPHAN_TTL_HOURS`) |
| orphan cleanup | a Worker maintenance route (or Cron Trigger) lists `<ownerTag>/objects/…`, diffs against `catalog.json`, deletes anything not referenced and older than the TTL. **DESIGNED, not implemented** — no Cron/route exists. |
| account-deletion purge | §12 |
| user-requested single delete | `.delete` grant → object removed → catalog entry removed; best-effort on an already-gone object |
| repeated deletion | idempotent — deleting an absent object / handle is a no-op success |
| legal / privacy | deletion is hard (no soft-tombstone in R2); the "never resurrect" guarantee is in the Personal AI import layer, not R2 |
| failure handling | a failed delete is retryable (idempotency key); retention re-run converges |

**Remote backup deletion NEVER deletes local Personal AI source data.**
Removing an R2 object removes one disaster-recovery copy; the live local cache
+ primary cloud are untouched. Proven: `deleteIsolatedPerUser`,
`accountDeletionScoped`, `outageNeverFailsLocalBackup`.

---

## 12. ACCOUNT DELETION  (DESIGNED / SPECIFIED)

```
user requests Personal AI cloud deletion (in-app)
  → app obtains a fresh VERIFIED identity token
  → app calls the Worker's delete-all route (authenticated)
  → Worker derives <ownerTag> from the VERIFIED subject
  → Worker lists backup/v1/<ownerTag>/…  (its OWN authoritative namespace only)
  → Worker deletes every object under that prefix, then catalog.json
  → Worker deletes all idempotency / counter rows for sub_hash
  → Worker adds sub to a local tombstone list (rejects future tokens for it — §3)
  → Worker returns { deleted: <count>, ok: true }
  → app shows the confirmed result
```

- **Cross-user deletion is impossible:** the Worker only ever enumerates and
  deletes under the `<ownerTag>` it derived from the verified token. It never
  accepts an owner tag / user id / prefix from the request body as a deletion
  target.
- The local app **does not** clear local Personal AI data as a side effect of
  a remote purge. Wiping local data is a **separate** explicit user action.
- Partial failure: the operation is resumable (re-run deletes what remains);
  the confirmed count reflects what was actually removed.

---

## 13. KEY MANAGEMENT  (IMPLEMENTED LOCALLY where on-device; rest DESIGNED)

Three **separate** concerns — no key from one class is ever usable for another.

### A. Client encryption key + recovery key

**Device encryption key** — AES-256 in the **Keychain**,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, own service, never shared
with `AuthTokenStore`, **never sent to the Worker or R2** (the server only
ever sees `.eapb` ciphertext).

**Recovery key — IMPLEMENTED LOCALLY + TESTED LOCALLY** (full detail in
`PHASE2_PERSONAL_AI_RECOVERY_KEY.md`):

- A wrapped backup (`"EAPB2"` envelope) seals its payload with a random
  per-backup **data key (DEK)**; the DEK is wrapped (AES-GCM) once for the
  device key and once for a 256-bit **`PersonalAIRecoveryKey`**. A new iPhone
  supplies the recovery key (`recoveryCode` / recovery file, checksum-verified
  before use) and decrypts locally — the device key is not needed.
- The recovery key, the device key, and the DEK **never** appear in a log, the
  `BackupManifest`, the envelope header (only *wrapped* DEK copies +
  non-reversible `keyID` fingerprints), or any remote payload. Tested.
- **Rotation:** the next backup wraps for the new key; older backups keep the
  recovery slot (`keyID`) they were written with. A rotated key against a
  pre-rotation backup → `recoveryKeyMismatch` (no silent wrong-key attempt);
  the correct historical key still works.
- **Still lost key + lost recovery key ⇒ unrecoverable**, by design
  (zero-knowledge to the server).
- **NOT implemented / deferred:** cloud key escrow, iCloud-Keychain sync of the
  recovery key, passphrase-derived keys (need a memory-hard KDF), the recovery
  UI, and wiring into `PersonalAIContainer.live` (a model seam —
  `RecoveryKeyStore` — exists). **Restore on a real new iPhone is NOT
  verified.**
- Scheme rotation: envelope `encryptionScheme` / format digit / `keyWrapping.version`
  make a change detectable; a bare legacy `AES.GCM` blob and the `"EAPB1"`
  direct format still open.

### B. Worker signing / auth secrets

- `AUTH_*` config, `WORKER_OWNER_TAG_KEY` (only if v2 HMAC is adopted) — live
  **only** as Worker secrets (`wrangler secret put`), never in the repo, never
  in the app.
- Rotation: standard secret rotation; JWKS `kid` rollover handled by the
  Worker's key cache (§3).

### C. Cloudflare / R2 service credentials

- R2 S3 Access Key ID + Secret, scoped to exactly the one bucket, Object Read
  & Write only — **only** as Worker secrets.
- **No R2 access secret, no Worker private secret, in iOS. Ever.** Proven for
  the current code: `noStaticStoreSecret`, `changesIntroduceNoSecret`,
  `BackupProviderIndependenceTests`.

### Restore on a new iPhone

`canonicalUserID` (from re-auth) → `ownerTag v1` → list `catalog.json` →
download objects → **decrypt with the Keychain key** → validate → import.
Works iff key class A is available on the new device (see the recovery-mechanism
gap above).

---

## 14. OBSERVABILITY WITHOUT PRIVACY LEAKAGE  (DESIGNED + TESTED LOCALLY as a contract)

### Allow-list — the ONLY fields a log line may carry

`event`, `ts`, `ownerTag`, `operation`, `objectKeySuffix` (last path segment
only), `grantID`, `requestID`, `outcome`, `ciphertextBytes`, `latencyMs`.

Pinned in `R2DeploymentContractTests.auditEventRedactionContract` +
`auditEventAllowlist`.

### Forbidden — must be structurally impossible to emit

memory text · conversation text · plaintext archive · any bundle field ·
identity token / `Authorization` header · presigned URL or any `X-Amz-*`
parameter · encryption key · recovery key · R2 credential · raw user id · email.

The existing Worker `console.log` in `index.ts` already conforms (logs
`event`, `ownerTag`, `operation`, `keySuffix`, `grantID`). Metrics
(success/failure counts, latency histograms, ciphertext-byte totals) are
derived from allow-listed fields only. Log retention: short window
(≤ 7 days, `LOG_RETENTION_DAYS`).

---

## 15. COST / BILLING GATE  (REQUIRES USER APPROVAL — no billing enabled)

**Billing is NOT configured and will not be by this workstream.**

Before **any** real resource is created, a future execution MUST produce a
fresh cost report:

- exact provider resources needed (bucket, Worker, D1 database and/or a
  Durable Object namespace, Cron Trigger, rate-limiting rules)
- **current** free-tier limits for each — fetched from Cloudflare's live
  pricing/docs at that time
- projected volume: requests/day, storage/user, total storage, egress
- expected monthly cost **range** at projected volume
- whether a **payment method / card** is required to open R2 at all
- what happens when a free-tier limit is exceeded (hard stop vs. overage
  billing) per resource
- exact steps to disable / delete every resource

> **PRICING IN THIS DOCUMENT (and in `PHASE2_R2_PRODUCTION_PATH.md`,
> `PHASE2_R2_INDEPENDENT_BACKUP.md`) MUST BE RE-VERIFIED FROM CURRENT
> CLOUDFLARE DOCUMENTATION BEFORE DEPLOYMENT.** Treat any number older than
> this file's own date as stale. In particular: R2 storage/operation/egress
> rates, the Workers free vs. Paid ($5/mo min) split, whether Durable Objects
> require Paid, and D1's free allocation.

No cost commitment is made here.

---

## 16. DEPLOYMENT ORDER  (strict — no gate may be skipped)

| Gate | What | Blocks on |
|---|---|---|
| **A** | Architecture (this doc §§2–14) reviewed and approved | user review |
| **B** | Current Cloudflare pricing + free-tier limits re-verified (§15) | live Cloudflare docs |
| **C** | **User explicitly approves** resource creation + billing implications | user sign-off |
| **D** | Create the R2 bucket (one region, private, no public access, no custom domain). The `backup/v1/` namespace (§7) is already implemented — just confirm the exact form is still right. | Gate C |
| **E** | Stand up the atomic idempotency store (D1 table or Durable Object namespace, §5); wire the `idempotencyKey` wire field (Swift + Worker) | Gate D |
| **F** | `wrangler deploy` to a **dev** environment; R2 binding + S3 credential as Worker secrets; `ALLOW_DEV_IDENTITY` **off** | Gate E |
| **G** | Configure verified auth: real issuer + JWKS + opaque stable `sub`; prove `canonicalUserID` (client) == verified `sub` (Worker); re-run owner-tag vectors against a real subject | a live EvenAI identity provider (§3) |
| **H** | One disposable test backup end-to-end against the dev bucket | Gate G |
| **I** | Verify the stored object is **ciphertext only** (no plaintext markers, no bundle fields) | Gate H |
| **J** | Restore the disposable backup onto a clean install; ids/counts/checksum intact | Gate H |
| **K** | Cross-user security test against the live bucket (user B cannot list/read/delete user A) | Gate J |
| **L** | Account-deletion test: purge removes every object + metadata, cross-user delete impossible, local data untouched | Gate K |
| **M** | Recovery test on a **real second device**: set up a recovery key, back up, lose the first device, restore from the recovery code alone; tombstones/revisions intact, no resurrection, no duplication. (The recovery-key *mechanism* — §13.A — is implemented + unit-tested; this gate is the real-hardware proof.) | Gate L |
| **N** | **Production enablement explicitly approved**; promote dev → production; enable for a limited cohort first | user sign-off + Gates D–M green |

---

## 17. ROLLBACK PLAN

Universal invariant: **local Personal AI data is never touched by a rollback**,
and **the remote backup is never required for app or G2 operation** — the
shipping default (`R2ProductionBackupAdapter.inert`, `LocalDirectoryBackupStore`)
already reaches no network.

| Failure | Rollback |
|---|---|
| Worker auth bug (accepts bad tokens / rejects good ones) | flip the app's credential provider back to `NotConfiguredBackupCredentialProvider` (feature flag) → R2 path goes dormant instantly; fix + redeploy Worker; no client update needed |
| owner-tag mismatch (client ≠ Worker) | vector tests should catch pre-deploy; if it slips, dormant the R2 path; objects under a wrong tag are orphaned ciphertext (harmless), swept later |
| replay / idempotency bug (double-apply) | dormant the R2 path; catalog is id-keyed so duplicates collapse on next clean write; audit D1 for anomalies |
| corrupted backups discovered | mark affected `backupID`s bad in the coordinator; they are already non-selectable if integrity checks fail; retention ages them out |
| R2 outage | transport throws → coordinator fails this run, local + prior verified backup untouched (`outageNeverFailsLocalBackup`); auto-retries next cycle |
| bad Worker deployment | `wrangler rollback` to the previous version; or dormant the client path |
| excessive billing / free-tier blown | dormant the client path (stops new `presign` calls); disable the Worker route; delete/downsize resources per §15's teardown steps |
| identity provider outage | Worker fails closed (503) → client gets `unauthorized`/`network` → R2 run fails safe; local unaffected |
| account-switch bug | grants are per-identity; worst case is an orphan under the wrong namespace; dormant + sweep |

Feature flags needed (DESIGNED): `personalAI.r2Backup.enabled` (client),
Worker route enable/disable, per-cohort allow-list.

---

## 18. LOCAL HARDENING TESTS

### LOCAL CONTRACT TEST (added / present — no infra)

| Contract | Test |
|---|---|
| Swift ↔ Worker owner-tag agreement (9 vectors) | `R2DeploymentContractTests.ownerTagV1CrossLanguageVectors` + `owner-tag-vectors.test.ts` |
| owner tag opaque / no PII / deterministic / distinct | `ownerTagV1Properties` |
| object key: owner-scoped, PII-free, deterministic, well-formed | `objectKeyNamespaceContract` |
| path traversal / malformed keys rejected | `pathTraversalAndMalformedKeysRejected` (+ `scope.test.ts`) |
| remote catalog carries no plaintext / PII / only handle fields | `remoteCatalogCarriesNoPlaintextOrPII` |
| scope binds exactly one operation + object + owner | `scopeBindsOperationObjectOwner` (+ companion suite) |
| expired authorization is unusable client-side | `expiredAuthorizationIsUnusable` |
| account switch → disjoint namespace | `accountSwitchProducesDisjointNamespace` |
| idempotency-key format contract | `idempotencyKeyFormatContract` |
| audit-event redaction allow-list | `auditEventRedactionContract` |
| no secret / endpoint / plaintext in new artifacts | `newArtifactsIntroduceNoSecret` |
| Worker owner-tag derivation is secret-free + server-authoritative | `presign.test.ts` "owner-tag derivation is server-authoritative and secret-free" |
| **versioned `backup/v1/` namespace** — canonical path, determinism, no collisions, no PII, traversal / slash / backslash / percent-encoded-separator / empty-id / malformed-id rejection, **unknown version fails safely**, `R2BackupStore` uses it end-to-end (put / list / delete) | `BackupObjectNamespaceTests` (13) + Worker `object-namespace.test.ts` (7) |
| **recovery key** — 256-bit entropy, versioned, checksum-protected export round-trips; wrong / corrupted / rotated key rejected; new-device open via recovery key; no raw key in header / manifest / remote payload / logs; failed recovery mutates nothing | `PersonalAIRecoveryKeyTests` (18) |

Plus everything already green in `R2ProductionPathSecurityTests` (35),
`R2ProductionPathAuthorizationBypassTests` (12), the 6 backup suites (65 —
incl. `PersonalAIRecoveryKeyTests`, `BackupObjectNamespaceTests`), and the
Worker vitest suite (49). Full `EvenAITests`: **826 / 103 suites / 0 failed**.

### REAL DEPLOYMENT TEST REQUIRED (cannot be faked)

- real presigned-URL behaviour (R2 honouring / rejecting a signature, TTL,
  `Content-Length` ceiling)
- real atomic idempotency consume under concurrency (D1 / Durable Object)
- real token signature verification against a live JWKS
- real cross-user isolation against a live bucket
- real durability
- **real restore on a new iPhone** using the recovery key (the mechanism is
  unit-tested; a two-device round trip is not)
- real orphan-sweep Cron
- real rate-limit enforcement

These map to Gates H–M. **Nothing here is simulated as if it were real.**

---

## 19. (this document)

`PHASE2_R2_DEPLOYMENT_READINESS.md` — the deployment-readiness spec + gate
checklist. Separation of concerns is the §0 legend; the gate checklist is §16.

---

## 20. RELATIONSHIP TO `PHASE2_R2_PRODUCTION_PATH.md`

That document's status block is unchanged and still accurate. Small accuracy
updates made alongside this plan:

- The owner-tag **client/Worker mismatch** the prior audit flagged is now
  resolved: one canonical `ownerTag v1`, byte-identical, cross-language
  vectors on both sides. (Companion doc §14 / §11 checklist item "Per-user
  identity mapping".)
- The Worker no longer references an `OWNER_TAG_SALT` secret (it would only
  have guaranteed disagreement).

Still explicitly true:

```
REAL R2 BUCKET CREATED:            NO
WORKER DEPLOYED:                   NO
REAL KV/D1/DURABLE OBJECT RESOURCE: NO
REAL AUTH CONFIGURED:              NO
REAL CREDENTIALS ADDED:            NO
BILLING CONFIGURED:               NO
REAL NETWORK BACKUP VERIFIED:      NO
REAL OFF-DEVICE DURABILITY VERIFIED: NO
REAL R2 RESTORE VERIFIED:          NO
```

---

## REMAINING DEPLOYMENT BLOCKERS

1. **No live EvenAI identity provider** with an opaque stable `sub` + JWKS
   (Gate G). Everything downstream waits on this.
2. **No atomic idempotency store** — needs D1 or a Durable Object; the
   `idempotencyKey` wire field is unwired (Gate E). R4 is **not** solved.
3. **Recovery-key mechanism is implemented + unit-tested locally**
   (`PHASE2_PERSONAL_AI_RECOVERY_KEY.md`), but **restore on a real new iPhone
   is not verified** (Gate M), and the recovery **UI**, container wiring, and
   any **cloud escrow** are still deferred.
4. **Pricing not re-verified** against current Cloudflare docs (Gate B).
5. ~~Versioned namespace prefix~~ — **done**: `backup/v1/` is implemented in
   `BackupObjectNamespace` + `R2BackupStore` + the Worker, with cross-language
   tests. Confirm the exact form at Gate D.
6. All of R2/R3/R4 as documented in the companion doc (R4 unchanged; R3
   inherent).

## USER APPROVAL REQUIRED BEFORE

- **Gate C** — creating **any** Cloudflare resource (R2 bucket, D1, Durable
  Object, Worker deploy) and accepting the billing implications.
- **Gate N** — enabling the path in production for real users.

Nothing between here and Gate C is reversible-cost-free by assumption; treat
Gate C as the hard stop.
