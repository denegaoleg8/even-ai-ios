# Personal AI Cloud — Production-Safe Cloudflare R2 Backup Path

**Design + local implementation only.** No Cloudflare account, no R2 bucket,
no Worker, no billing, no credentials, no real network. `PersonalAIContainer.live`
is unchanged and still wires no off-device backup.

> **Status (2026-08-31):** §§ 1–13 landed as `ea0ab4f Add production-safe R2
> backup path`. Uncommitted on top: the **§ 14 R1/R2 hardening** (production
> Swift + tests) and the **`cloudflare/backup-worker/`** Worker source (server
> half of the contract — never deployed, KV/R2 simulated in-memory by its
> local vitest). Nothing committed or pushed in this pass.

- **Baseline:** `3376393 Reference CloudKit unlock checklist`
- **This workstream:** the secure production boundary needed *before* a real
  encrypted R2 backup can be turned on — modelled as provider-independent
  seams with fakes, so the shipping app remains structurally unable to reach
  real R2.

---

## 1. EXISTING BACKUP FOUNDATION

Everything below already exists (committed at `fe2bbe1`) and is unchanged by
this workstream except where noted:

| Layer | Type(s) | Role |
|---|---|---|
| Snapshot unit | `PersonalDataBundle` (+ `BackupManifest`) | the one portable dataset: memory, rules, style, conversations, messages, revisions. No tokens/keys — structurally. |
| Integrity | `BackupManifest.checksum` (SHA-256 of the canonical bundle JSON minus the manifest) | truncation / tamper detection at the bundle level |
| Encryption seam | `BackupEncryptionProviding` (Core) → `AESGCMBackupEncryption` | AES-256-GCM, Keychain key (`SymmetricKeyStore`, `…ThisDeviceOnly`), random 96-bit nonce, `EncryptedBackupEnvelope` framing (`"EAPB1"` + header JSON + raw ciphertext). Header carries a **salted owner-tag hash**, scheme id, bundle version, and `ciphertextSHA256` — never content, never the raw id. |
| Object store seam | `BackupStore` (Core): `putBackup` / `listBackups` / `getBackup` / `deleteBackup` | `LocalDirectoryBackupStore` (on-device, live), `R2BackupStore` (dormant), `CompositeBackupStore` (primary + best-effort secondaries) |
| Transport seam | `BackupObjectTransport` (Core) | raw HTTPS over an already-authorised URL, **no credentials of its own**. `DormantBackupObjectTransport` (prod default), `URLSessionBackupObjectTransport` (compiled, unused) |
| Credential seam | `BackupCredentialProviding` (Core): `presign(operation, key, ownerTag)` | `NotConfiguredBackupCredentialProvider` (prod default, `isConfigured == false`), `WorkerBackupCredentialProvider` (compiled, unused) |
| Coordinator | `PersonalAIBackupCoordinator` | seal → upload → **verify-before-publish** (read back, decrypt, re-validate, owner-check) → prune. `loadLatestBackupBundle` iterates newest→oldest and returns the first fully recoverable backup. |
| Restore | `PersonalAICloudRestoreCoordinator` + `PersonalDataImporter` | validate (format / schema / checksum / counts / required fields / owner) **before** any destructive local mutation; `.replaceAll` / `.merge`; tombstone-aware; dedupe by id |
| Portable export | `PersonalDataArchiveBuilder` + `StoredZipArchive` | open `EvenAI-PersonalAI-YYYY-MM-DD/` folder + `.zip`, separate from the encrypted backup |
| Owner tag | `BackupOwnerTag.tag(personalAIUserID)` | salted SHA-256; the only owner identifier that ever appears in an object key or envelope header |
| Fakes | `InMemoryBackupObjectTransport`, `FakePresignProvider`, `FlatInMemoryBackupStore`, `FakeR2` | deterministic, no network |

**What was thin and is filled in by this workstream:** the *authorization*
model. `presign(operation, key, ownerTag)` returned only a URL + expiry, with
no explicit grant scope, no client-side expiry enforcement, no replay model,
and no server-side "derive the owner tag from the verified identity, never
trust the client's claim" contract expressed in code or tests.

---

## 2. PRODUCTION SECURITY MODEL

### Trust boundary

```
 iOS app                    authenticated EvenAI backup authorizer          R2
 ───────                    ────────── (a Cloudflare Worker) ──────         ──
 • holds NO store secret    • holds the scoped R2 credential (binding       • object
 • holds NO Cloudflare        or an Object-Read/Write API token) — the        store
   API token                  ONLY place it exists
 • holds only a short-      • verifies the caller's identity token
   lived identity token       (Sign in with Apple `sub` / EvenAI account)
   for the current user     • DERIVES the owner tag from that identity —
                              never trusts the client's claimed tag
                            • issues one grant = one operation on one key,
                              under `<derivedTag>/…`, expiring in minutes
                            • (deployment requirement) records a request
                              nonce and rejects a repeat
```

**What is modelled/enforced locally vs. deferred to the real authorizer:**

| Property | Enforced in this local implementation | Deferred to the deployed Worker |
|---|---|---|
| identity → owner-tag derivation, client claim ignored | ✅ `FakeBackupAuthorizationServer` | real JWT verification + KDF |
| grant = one operation, one key, one owner | ✅ scope stamped by the provider (`WorkerBackupCredentialProvider` **and** the fakes) + `BackupAuthorizationClient` refuses an unscoped or mismatched grant | signed-URL constraints + a Worker-returned authoritative scope |
| unguarded remote store cannot be constructed | ✅ `R2BackupStore` raw init is `private`; only `.authorized` / `.dormant` (both wrap `BackupAuthorizationClient`) | — |
| out-of-namespace / malformed key refused | ✅ client **and** server (`keyIsInOwnerNamespace` + `keyIsWellFormed`) | server re-check against derived tag |
| grant expiry | ✅ client refuses stale grant; edge refuses stale URL | short signed-URL TTL |
| signed URL single-use for mutation | ✅ modelled at the edge (`409` on reuse) | Worker/R2 nonce-in-signature or a used-URL table |
| **request-body nonce** (a captured `presign` POST cannot be replayed) | ❌ **not modelled** — `BackupCredentialProviding.presign` carries no nonce today | **Worker must** record `(identity, nonce)` and reject repeats |
| rate limiting / abuse ceilings | ❌ | Worker config |

The iOS app therefore **never contains**: an R2 Access Key ID, an R2 Secret
Access Key, a Cloudflare API token, or any account-wide credential. A
decompiled binary yields nothing that touches the bucket.

### Controls

| Control | Where enforced | How |
|---|---|---|
| **User authentication** | authorizer | identity token verified (Sign in with Apple / EvenAI account JWT) before any grant |
| **Authorization** | authorizer | grant issued only for the identity's own derived `ownerTag` namespace |
| **Object ownership** | authorizer + key layout | every key is `<ownerTag>/…`; `ownerTag` is derived server-side from the verified identity |
| **Per-user namespace** | key layout | `BackupOwnerTag.tag()` salted hash — one prefix per user, no collisions, no PII |
| **Replay protection** | edge: single-use mutation grants (modelled) · authorizer: request-nonce table (**deployment requirement, not modelled**) | a captured signed URL cannot be re-used to write; a captured `presign` request body must be rejected by the deployed Worker |
| **Upload authorization** | authorizer | `.put` grant, one key, minutes-long expiry |
| **Download authorization** | authorizer | `.get` grant, one key; the authorizer returns only descriptors for the caller's own namespace |
| **Delete authorization** | authorizer | `.delete` grant, one key, caller's namespace only |
| **Restore authorization** | authorizer + client | list is owner-scoped; each object fetch is a separate `.get` grant; the device validates before mutating |
| **Rate limiting** | authorizer (Worker) | per-identity request ceilings on `/presign` (Cloudflare rate-limiting rules / a KV counter) — **a deployment config, not app code** |
| **Abuse controls** | authorizer | max object size, max objects per owner, max total bytes per owner, reject unknown key shapes |
| **Auditability** | authorizer logs | log `{ identityHash, ownerTag, operation, keySuffix, grantID, ts }` — **never** plaintext, never the full key, never a token |

---

## 3. ENCRYPTION MODEL

Unchanged rule: **the canonical archive is sealed on-device; only ciphertext
leaves the phone.** The authorizer and R2 never need, receive, or ask for a
decryption key.

| Aspect | Design |
|---|---|
| Algorithm | AES-256-GCM (`CryptoKit`), platform-standard, **no custom crypto** |
| Key | `SymmetricKeyStore` — Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, own service, never shared with `AuthTokenStore` |
| Nonce | random 96-bit per seal, inside the GCM combined box |
| Envelope | `EncryptedBackupEnvelope`: `"EAPB" + '1' + UInt32-BE headerLen + headerJSON + raw ciphertext` |
| Envelope header | `encryptionScheme`, `createdAt`, `ownerTag` (salted hash), `bundleSchemaVersion`, `bundleVersion`, `ciphertextSHA256`, `ciphertextLength` — **no content, no counts, no raw id** |
| Manifest integrity | `BackupManifest.checksum` (inside the sealed bundle) + `ciphertextSHA256` (envelope, outside) → truncation / bit-rot caught **before** a decrypt is attempted |
| Backup key identity/version | `schemeIdentifier` (`"AES-GCM-256"`) recorded in the header; a future scheme is a new identifier + a new `BackupEncryptionProviding` conformer |
| Wrong key | `AES.GCM.open` fails → `BackupEncryptionError.openFailed`; the restore is rejected, local data untouched |
| Corruption | `ciphertext.sha256Hex != header.ciphertextSHA256` → `integrityMismatch`; a truncated object → `BackupTransportError.truncated`; both rejected pre-decrypt |
| Key rotation compatibility | `open` tries the envelope path first, then a legacy bare `AES.GCM.SealedBox(combined:)` — old on-device backups still restore. A rotated key would be a new key class + a re-seal of the latest bundle; old objects under the old key are pruned by retention. |
| Old-backup restore | schema migration via `PersonalBundleMigrator` for `schemaVersion <= current`; `schemaTooNew` rejected with a clear message |
| Secrets in logs / metadata | none — envelope header and authorizer logs carry only hashes, sizes, and timestamps |

---

## 4. AUTH / IDENTITY BOUNDARY

New provider-independent Core vocabulary (`BackupAuthorization.swift`, one
type, Foundation only) — names no concrete store:

| Type | Purpose |
|---|---|
| `BackupAuthorizationScope { ownerTag, objectKey, operation }` | **exactly one** operation on **one** key under **one** owner. `authorizes(_ op:key:ownerTag:)` is the least-privilege check — all three must match, *and* the key must be well-formed and in the namespace. `keyIsInOwnerNamespace(_:ownerTag:)` / `keyIsWellFormed(_:)` reject `..` / `.` path segments, `//`, leading / trailing `/`, control characters, empty or > 512-byte keys → block path traversal and canonicalisation ambiguity. |

The **object lifecycle** (staged → committed) is described in the file's doc
comment but is *not* a stored enum: the owner's `catalog.json` is the single
source of truth, and `listBackups` returns only committed entries.

Earlier drafts of this file also declared `BackupObjectDescriptor`,
`BackupObjectState`, `BackupAuthorizationRequest`, and `BackupAuthorizationError`.
They were **removed in the pre-commit audit** — nothing referenced them, and
`BackupCredentialError` carries every outcome the code throws. The
request-body/nonce contract for the future Worker is documented in § 11, not
modelled as a type.

Existing seams, extended additively:

- `PresignedBackupRequest` gains `grantID: String?` and `scope: BackupAuthorizationScope?` (both defaulted `nil` — every existing call site is source-compatible). `covers(_ op:key:ownerTag:)` returns `false` when `scope == nil` — a production grant **must** be scoped.
- `BackupCredentialError` gains `.expired`, `.replayed`, `.scopeMissing`.
- `BackupObjectOperation` gains `Codable` (trivial, additive).
- `WorkerBackupCredentialProvider` **carries the authorizer's server-derived `scope` through to the grant verbatim** (and refuses a response that omits it), is bound at construction to the identity it is authenticated as, and `R2BackupStore`'s raw initializer is **private** with the `authorized` factory gated by a capability only `R2ProductionBackupAdapter` can mint — see § 9 and § 14 (R1/R2 hardening).

Cloudflare-specific code stays at the adapter level:
`R2ProductionBackupAdapter` (Infrastructure) is the **named boundary** — a
composition point with no SDK, no endpoint constant, no credential. It
delegates to `R2BackupStore.authorized(…)`, which is now the *only* way to
build a remotely-capable store (the raw initializer is `private`), so the
client-side guard is **compiler-enforced** in the chain, not merely
recommended.

---

## 5. R2 OBJECT LAYOUT

```
<ownerTag>/catalog.json                          the committed BackupHandle list (source of truth for a restore)
<ownerTag>/objects/<version>-<tier>-<id>.eapb     one sealed backup each
```

- `<ownerTag>` = `BackupOwnerTag.tag(personalAIUserID)` — a salted SHA-256
  hex string. **Never** the raw Personal AI user id, **never** an email or
  username, **never** any memory metadata.
- Stable & reproducible: the same user derives the same tag on a new iPhone,
  so recovery can find their own backups; the salt is a fixed app constant
  (defends against trivial rainbow-tabling of short ids, not against someone
  with the app binary — which is acceptable because the objects are
  ciphertext).
- **Multiple snapshots:** many `objects/…` per owner; `catalog.json` lists
  them with tier + version + size + checksum.
- **Tombstone / delete:** removing a backup deletes the object **and** its
  catalog entry. There is no soft-tombstone in R2 — a deleted backup is gone;
  the "never resurrect" guarantee lives in the Personal AI import layer, not
  here.
- **Atomic / manifest-last publication:** `putBackup` uploads the sealed
  object **first**, then rewrites `catalog.json`. A restore only ever reads
  `catalog.json`. Therefore:
  - **object PUT interrupted** → transport throws → catalog untouched → no
    change visible, retry is safe.
  - **object PUT ok, catalog PUT fails** → the object is a `.staged` orphan,
    **not referenced by the catalog**, so `listBackups` never returns it and
    a restore can never select it. It is pruned later.
  - **A partial upload therefore never becomes a valid restore candidate** —
    proven by `R2ProductionPathSecurityTests.stagedObjectNotRestorable` and
    `BackupHardeningTests.interruptedUploadKeepsLastVerified`.
- The coordinator's **verify-before-publish** is the second gate: even a
  fully-uploaded-and-catalogued object is not counted as "the latest backup"
  (`lastBackupSucceededAt` is not advanced) until it has been read back,
  decrypted, re-validated, and owner-checked.

---

## 6. UPLOAD PROTOCOL

Modelled locally end-to-end (`FakeBackupAuthorizationServer` +
`R2ProductionBackupAdapter` + `R2BackupStore` + `BackupAuthorizationClient`):

1. App builds the `PersonalDataBundle`, seals it → `.eapb` bytes.
2. App asks the authorizer: `presign(.put, key: <ownerTag>/objects/…, ownerTag)`.
   - `BackupAuthorizationClient` first refuses locally if `key` is not under
     `<ownerTag>/` (defence in depth).
   - The authorizer verifies the identity, **derives the owner tag itself**,
     denies anything outside that namespace or any malformed key, and returns
     a grant scoped to `(.put, that one key)`, expiring in minutes, with a
     `grantID`. (A deployed Worker also records a request nonce — see § 11.)
   - `BackupAuthorizationClient` refuses to use the grant if it is already
     expired or scoped to anything other than what was asked.
3. Ciphertext uploads over the granted URL (`BackupObjectTransport.put`).
4. The store rewrites `catalog.json` (a second, separate grant) — this is the
   logical publication point.
5. The coordinator reads the object back, decrypts, re-validates, owner-checks
   (**verify-before-publish**).
6. Only then is `lastBackupSucceededAt` advanced and retention pruned.
7. The backup is now a restore candidate.

| Failure | Behaviour |
|---|---|
| retries | id-keyed catalog upsert → a retried `putBackup` with the same handle id does not duplicate |
| duplicate requests | same — `duplicateUploadNoDuplication` |
| idempotency | the object key is derived from `(version, tier, id)`; re-putting overwrites the same key; the catalog dedupes by id |
| partial upload | object without catalog entry = `.staged`, invisible to restore, pruned |
| interrupted upload | transport throws → catalog + `lastBackupSucceededAt` untouched → previous verified backup stays the restore target |
| stale authorization | `BackupAuthorizationClient` rejects an expired grant → caller re-requests |
| expired authorization at the edge | the edge refuses an expired signed URL (`403`) → caller re-requests |
| replayed grant | a `.put`/`.delete` signed URL is single-use → second use `409` |
| server failure (5xx) | `BackupTransportError.http(status:)` with `isRetryable == true` for `>= 500` / `429`; the coordinator fails this run, local data + prior backup untouched |
| network failure | `BackupTransportError.network`, retryable; same safety |

---

## 7. DOWNLOAD / RESTORE PROTOCOL

1. Authenticated user asks for their backup list → `R2BackupStore.listBackups`
   fetches `<ownerTag>/catalog.json` via a `.get` grant.
   - The authorizer only ever issues grants under the caller's own derived
     `ownerTag`, so the list is structurally the caller's own — a different
     user keys off a different tag and sees an empty catalog
     (`crossUserReadDenied`).
2. Server returns only committed descriptors (the catalog holds only
   committed handles).
3. App downloads the chosen ciphertext object (`.get` grant + transport).
4. Device verifies integrity: object size vs handle, `ciphertextSHA256` vs
   envelope header, GCM tag on open.
5. Device decrypts locally with the Keychain key. **The server never has the
   key** (`authorizerNeverNeedsDecryptionKey`, `serverSeesOnlyCiphertext`).
6. `PersonalDataImporter.validate` runs — format, schema, checksum, counts,
   required fields, **owner match** — before any local mutation.
7. `importBundle(strategy:)` applies it: `.replaceAll` for a clean device,
   `.merge` otherwise; stable ids preserved, tombstones honoured, dedupe by
   id → idempotent and non-resurrecting.

---

## 8. DELETE / RETENTION

| Operation | Design |
|---|---|
| Per-backup delete | `deleteBackup(handle)` → `.delete` grant for that one key → object removed → catalog entry removed. Best-effort on the object (already-gone is fine). |
| Account-wide backup deletion | iterate `listBackups` → delete each; also delete `catalog.json`. Distinct from `PersonalCloudService.deleteAllData` (primary store) — the R2 copy is deleted separately and explicitly. |
| Retention policy | `PersonalAIBackupCoordinator`: keep 3 incremental / 7 daily / 4 weekly / 3 monthly; `prune` runs after every successful backup, deleting the oldest beyond each tier's keep-count. |
| Orphan cleanup | a `.staged` object (upload succeeded, catalog write failed) is unreferenced; a future maintenance pass lists `objects/…` via the authorizer and deletes any not in `catalog.json`. Not implemented as a live job yet — documented. |
| Incomplete upload cleanup | same as orphan cleanup; also, the next successful `putBackup` for the same `(version, tier, id)` overwrites the staged bytes. |
| Tombstone / audit | R2 keeps no tombstone. The authorizer **logs** every delete `{ identityHash, ownerTag, keySuffix, grantID, ts }` for audit — no plaintext, no full key. |
| Safe reattempt | every operation is id/key-addressed and idempotent; a failed delete can be retried; a re-run of retention converges. |

**"Deleted from the R2 backup store" ≠ "deleted from Personal AI primary
data".** Removing an R2 object removes one disaster-recovery copy. The user's
live Personal AI memory (local cache + primary cloud) is untouched. Deleting
a *memory record* is a Personal AI domain operation (tombstone, propagated by
sync) and is unrelated to R2 object deletion.

---

## 9. LOCAL PRODUCTION-BOUNDARY IMPLEMENTATION

All additive, provider-independent, local-testable. **No real HTTP.** The
shipping app cannot reach real R2 because no configured
`BackupCredentialProviding` and no live `BackupObjectTransport` are ever
constructed in `PersonalAIContainer.live`.

### New production files

| File | Layer | Contents |
|---|---|---|
| `EvenAI/Core/Domain/PersonalAI/BackupAuthorization.swift` | Core (Foundation only) | `BackupAuthorizationScope` (+ `keyIsInOwnerNamespace` / `keyIsWellFormed` path-safety) — the provider-neutral authorization scope + key-validity primitive |
| `EvenAI/Infrastructure/PersonalAI/Backup/BackupAuthorizationClient.swift` | Infra | `BackupAuthorizationClient: BackupCredentialProviding` — the single client-side chokepoint. Wraps any provider (unwraps a double-wrap); enforces (1) never ask outside our namespace / for a malformed key, (2) never use an expired grant, (3) **refuse an unscoped grant** (`scopeMissing`) and never use one scoped to a different operation / key / owner tag. Holds no credential, makes no network call. |
| `EvenAI/Infrastructure/PersonalAI/Backup/R2ProductionBackupAdapter.swift` | Infra | `R2ProductionBackupAdapter` — the named production boundary. `makeStore(credentials:transport:)` delegates to `R2BackupStore.authorized`; `inert` → `R2BackupStore.dormant`; `objectNamespaceRoot(ownerTag:)` documents the key layout. |

### Modified production files

| File | Change |
|---|---|
| `EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift` | `PresignedBackupRequest` + `grantID` / `scope` (defaulted `nil`) + `covers(_ op:key:ownerTag:)` (false when unscoped); `BackupCredentialError` + `.expired` / `.replayed` / `.scopeMissing`; `BackupObjectOperation: Codable` |
| `EvenAI/Infrastructure/PersonalAI/Backup/R2BackupStore.swift` | **R1 fix** — the raw initializer is `private`; `authorized(...)` additionally requires a `RemoteBackupCompositionAuthority` whose initializer is `fileprivate` to `R2ProductionBackupAdapter.swift`. So `R2ProductionBackupAdapter.makeStore(...)` is the **only** path — production or test — to a remote-capable store, and `.dormant` is the only other form (reaches no network). Compiler-enforced. See § 14. |
| `EvenAI/Infrastructure/PersonalAI/Backup/BackupCredentialProviders.swift` | **R2 fix** — `WorkerBackupCredentialProvider` is constructed bound to `authenticatedUserID` (the identity it is authenticated as, wired from the same session as `identityToken`). It refuses to sign for any other owner, **requires** the Worker to return the `scope` it authoritatively granted (no scope → `scopeMissing`, never synthesised from the request), checks that server scope's owner is the authenticated identity, and carries that server scope through to the grant — so `BackupAuthorizationClient.covers(...)` compares the authoritative grant against caller intent instead of the request against a copy of itself. See § 14. |
| `EvenAI/Infrastructure/PersonalAI/Backup/BackupAuthorizationClient.swift` | **R2 fix** — the scope guard now throws `.scopeMismatch` (distinct from the local namespace guard's `.keyOutsideOwnerScope`) when the authoritative grant scope disagrees with the request. |
| `EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift` | `BackupCredentialError` gains `.scopeMismatch`. |

### New test files

| File | Contents |
|---|---|
| `EvenAITests/TestDoubles/FakeBackupAuthorizationServer.swift` | in-memory model of the Worker + R2 **edge / transport** (not crypto): identity verification, **server-side owner-tag derivation** (ignores the client's claim), malformed/traversal key rejection, least-privilege grants, expiry, single-use mutation grants, and a plaintext-leak detector. `credentialProvider(identityToken:)` and `transport()` share one instance's state. `backupStore(for:)` composes a full store through `R2ProductionBackupAdapter`. **Encryption is not faked** — the tests that check "ciphertext only" and round-trip use the real `AESGCMBackupEncryption` (`CryptoKit`). |
| `EvenAITests/PersonalAICloud/R2ProductionPathSecurityTests.swift` | 33 tests — the authorization boundary properties, incl. the R1/R2 audit-fix regression tests |

Also modified: `EvenAITests/TestDoubles/FakeBackupInfra.swift` — `FakePresignProvider`
now stamps a `scope` + `grantID` and gains `grantTTL` / `omitScope` knobs (so
it faithfully models a scoping authorizer); `FakeR2.store()` builds via
`R2BackupStore.authorized`.

The shipping default is unchanged: `PersonalAIContainer.live` wires
`LocalDirectoryBackupStore()`; `NotConfiguredBackupCredentialProvider().isConfigured == false`;
`R2ProductionBackupAdapter.inert` throws on every call.

---

## 10. SECURITY TESTS

`R2ProductionPathSecurityTests` (33, `.serialized`) — new, authorization-boundary focused:

| Property | Test |
|---|---|
| iOS backup layer embeds no static R2 / Cloudflare / AWS secret | `noStaticStoreSecret` |
| the credential / transport / authorizer APIs never take a decryption key | `authorizerNeverNeedsDecryptionKey` |
| an unknown identity token gets no grant | `unknownIdentityDenied` |
| user B cannot list or read user A's backups | `crossUserReadDenied` |
| the authorizer ignores the client's claimed owner tag | `serverIgnoresClaimedTag` |
| the client refuses to request a key outside its own namespace | `clientNamespaceGuard` |
| a grant authorizes exactly one operation on exactly one key | `grantIsLeastPrivilege` |
| an already-expired grant is rejected before use | `expiredGrantRejected` |
| the edge refuses an expired signed URL | `expiredURLRefusedAtEdge` |
| a mutation grant cannot be replayed | `mutationGrantSingleUse` |
| a `..` path segment is rejected by client and authorizer | `pathTraversalKeyRejected` |
| empty / `//` / leading-`/` / control-char / trailing-`/` / over-long / `.` keys rejected | `malformedKeysRejected` |
| user B cannot get a grant to write user A's catalog (finalize isolation) | `crossUserCatalogWriteDenied` |
| a grant issued to one identity is useless to another (account-switch safety) | `staleGrantAcrossIdentitySwitch` |
| object keys carry only the salted owner tag — no id/email/username | `opaqueObjectKeys` |
| a staged object with no catalog entry is never a restore candidate | `stagedObjectNotRestorable` |
| re-putting the same backup id does not duplicate it | `duplicateUploadNoDuplication` |
| user B's delete cannot address user A's object | `deleteIsolatedPerUser` |
| one user's account deletion cannot touch another user's backups | `accountDeletionScoped` |
| the server never receives the plaintext archive (real `AESGCMBackupEncryption`) | `serverSeesOnlyCiphertext` |
| seal → authorized upload → download → open → validate round-trips | `fullRoundTripThroughAuthorizer` |
| a byte flipped in the object at rest is rejected on open | `corruptedObjectRejected` |
| the inert adapter is the production posture | `inertAdapterPosture` |
| an R2 outage as a composite secondary never fails the local backup | `outageNeverFailsLocalBackup` |
| **R1** — no code constructs `R2BackupStore` via its (private) raw initializer | `noRawR2BackupStoreConstruction` |
| **R1** — the guarded factory always has the authorization client in the chain (expired grant refused, via `.authorized` *and* via the adapter) | `guardedFactoryEnforcesAuthorization` |
| **R2** — an unscoped grant is refused (`scopeMissing`) | `unscopedGrantRefused` |
| **R2** — scope survives provider → client and still matches op / key / owner | `scopeSurvivesProviderToClient` |
| **R2** — an expired *scoped* grant is still rejected | `expiredScopedGrantRejected` |
| **R2** — a valid exact-scope grant is accepted end to end | `validScopeAccepted` |
| **R2** — `WorkerBackupCredentialProvider` binds the grant to the exact requested scope (real HTTP round trip via `StubURLProtocol`) | `workerProviderProducesScopedGrant` |
| **R2** — `WorkerBackupCredentialProvider` rejects a server-returned scope that disagrees with the request | `workerProviderRejectsMismatchedServerScope` |
| the R1/R2 fixes introduce no R2 credential / plaintext | `fixesIntroduceNoSecretOrPlaintext` |

Already covered by existing suites, re-verified green through the new stack:

| Property | Existing test |
|---|---|
| wrong key rejected | `BackupEncryptionTests.wrongKeyRejected`, `BackupHardeningTests.wrongKeyRestoreRejected` |
| corrupted / tampered ciphertext rejected | `BackupEncryptionTests.tamperRejected`, `BackupHardeningTests.corruptNewBackupDiscarded` |
| integrity / truncation mismatch rejected | `BackupEncryptionTests.unsupportedEnvelopeVersion`, `R2BackupStoreTests.truncationDetected` |
| interrupted upload keeps last verified | `BackupHardeningTests.interruptedUploadKeepsLastVerified` |
| retry is idempotent | `BackupHardeningTests.retryIsIdempotent`, `R2BackupStoreTests.idempotentPut` |
| failed / unavailable backup never clears local data | `BackupHardeningTests.failedBackupNeverClears`, `providerUnavailableIsSafe` |
| restore validates before mutation | `BackupHardeningTests.validateBeforeMutation` |
| no resurrection / no duplication on restore | `BackupHardeningTests.noResurrectionNoDuplication` |
| nothing in a backup looks like a secret | `BackupHardeningTests.noSecretsInBackup` |
| production defaults dormant / provider-neutral | `BackupProviderIndependenceTests` (5) |

---

## 11. PRODUCTION DEPLOYMENT CONTRACT

Everything still required before a real R2 backup can be turned on. **None of
this is done. Each item creating a paid or account-level resource needs
explicit user approval first.**

- [ ] **Cloudflare account** (free tier to start; a card may be required to
      open R2 — verify at signup).
- [ ] **R2 bucket** (e.g. `evenai-personal-ai-backups`), one region.
- [ ] **R2 credential** scoped to that bucket (Object Read & Write) — stored
      **only** in the Worker's secrets. Prefer an R2 *binding* over an API
      token where possible.
- [ ] **Worker (or equivalent secure API)** — one `POST /presign` route:
      verify the identity token → derive `ownerTag` server-side → reject any
      key not under `<ownerTag>/` → record the request nonce (KV / D1) and
      reject replays → sign a URL for one verb + one key, expiring in ~5 min →
      return `{ url, headers, expiresInSeconds, grantID }`. ~50–80 lines.
- [ ] **Production auth provider** — a real identity-token source in the app
      (`WorkerBackupCredentialProvider.identityToken` closure) fed by Sign in
      with Apple / the EvenAI account token.
- [ ] **Per-user identity mapping** — the Worker's identity → `ownerTag`
      derivation must match `BackupOwnerTag.tag()` exactly (same salt, same
      hash), so a device and the Worker agree on the namespace.
- [ ] **Worker ↔ R2 binding** configured in `wrangler.toml`.
- [ ] **Rate limits** on `/presign` per identity (Cloudflare rules / a KV
      counter); per-owner object-count and total-byte ceilings.
- [ ] **Logging / privacy configuration** — log only hashes, sizes,
      timestamps, key suffixes, grant ids; never a token, never a full key,
      never plaintext; set a short log-retention window.
- [ ] **Backup retention** — confirm the coordinator's 3/7/4/3 schedule is
      right for real storage cost; add an orphan-cleanup pass.
- [ ] **Disaster-recovery procedure** — written runbook: how a user recovers
      from R2 alone if CloudKit and the device are both gone (identity →
      list → download → decrypt → validate → import).
- [ ] **Real upload** verified against the live bucket.
- [ ] **Real download** verified.
- [ ] **Real restore** verified onto a clean install.
- [ ] **Recovery test** — full backup→loss→restore cycle, ids / revisions /
      tombstones intact, no duplication, no resurrection.
- [ ] **Cost verification** against R2's published rates
      (`PHASE2_R2_INDEPENDENT_BACKUP.md` → storage/request model) before
      enabling.
- [ ] **Explicit user approval** before creating any paid or billable
      resource.

This item set is mirrored, at a higher level, in
`PHASE2_APPLE_DEVELOPER_CLOUDKIT_UNLOCK_CHECKLIST.md` § 10 and
`PHASE2_PERSONAL_AI_CLOUD_ROADMAP.md` → NOT YET CONFIGURED / FUTURE.

---

## 12. REPORT

| Field | Value |
|---|---|
| **EXISTING BACKUP FOUNDATION** | `PersonalDataBundle` + `BackupManifest` (checksum), `BackupEncryptionProviding`/`AESGCMBackupEncryption` (AES-256-GCM, Keychain key, `EncryptedBackupEnvelope`), `BackupStore` (`LocalDirectoryBackupStore` live, `R2BackupStore` dormant, `CompositeBackupStore`), `BackupObjectTransport` + `BackupCredentialProviding` seams (both dormant in prod), `PersonalAIBackupCoordinator` (verify-before-publish), `PersonalAICloudRestoreCoordinator` + `PersonalDataImporter` (validate-before-mutate), `PersonalDataArchiveBuilder` (portable export). All unchanged except the additive edits in § 9. |
| **PRODUCTION TRUST BOUNDARY** | iOS app (no store secret) → authenticated authorizer / Cloudflare Worker (holds the scoped R2 credential, derives the owner tag from the verified identity, issues one-op/one-key minute-long grants, rejects replays) → R2. |
| **IOS SECRET EXPOSURE** | none. No R2 Access Key ID, R2 Secret Access Key, Cloudflare API token, or account credential in the app or repo. `noStaticStoreSecret` + `BackupProviderIndependenceTests` enforce it. The app holds only a short-lived identity token for the current user. |
| **AUTHORIZATION MODEL** | `BackupAuthorizationScope` (one operation, one key, one owner) + server-side owner-tag derivation (client claim ignored) + malformed/traversal key rejection + minute-long expiry + single-use mutation grants (edge). Client-side `BackupAuthorizationClient` refuses out-of-namespace, malformed, expired, or mis-scoped grants before use. **Request-body nonce dedup is a deployed-Worker requirement, not modelled locally** (see § 11). |
| **ENCRYPTION MODEL** | AES-256-GCM on-device before upload; Keychain device-only key; random nonce; `EncryptedBackupEnvelope` framing; content-free header; 4 integrity layers (envelope hash+length, GCM tag, bundle checksum, structural validate); typed rejection on wrong key / tamper / truncation / unsupported version; legacy-blob fallback for old backups. Server never has the key. No custom crypto. |
| **R2 OBJECT LAYOUT** | `<ownerTag>/catalog.json` + `<ownerTag>/objects/<version>-<tier>-<id>.eapb`. `<ownerTag>` = salted SHA-256, never the id/email/username. Multiple snapshots; catalog is the restore source of truth; manifest-last publication → a partial upload is a `.staged` orphan, never a restore candidate. |
| **UPLOAD FLOW** | build → seal → `presign(.put, key)` (client namespace+well-formed guard → authorizer identity+scope+namespace → client expiry/scope guard) → `transport.put` ciphertext → rewrite catalog → coordinator verify-before-publish → advance state + prune. Retry/duplicate/idempotent-safe; interrupted/partial upload never replaces the last verified backup. |
| **DOWNLOAD FLOW** | owner-scoped `listBackups` (catalog) → `presign(.get, key)` per object → `transport.get` → size + `ciphertextSHA256` + GCM checks → decrypt on-device → `PersonalDataImporter.validate` (incl. owner match) → `importBundle`. Server never needs the key. |
| **DELETE FLOW** | per-backup: `.delete` grant → object + catalog entry removed. Account-wide: iterate + delete each + delete catalog. Retention prune (3/7/4/3) after each backup. Orphan/incomplete cleanup documented (not yet a live job). "Deleted from R2" ≠ "deleted from Personal AI primary data". |
| **RETENTION MODEL** | `PersonalAIBackupCoordinator`: 3 incremental / 7 daily / 4 weekly / 3 monthly; prune oldest-beyond-keep after every successful backup; orphan sweep documented for the Worker era. |
| **FAILURE SAFETY** | seal fail / put fail / verify fail / dormant provider / 5xx×N / network / corrupt object / wrong key / truncation / expired grant / replayed grant / R2 outage as a composite secondary — every path leaves the local encrypted cache byte-identical and the previous verified backup recoverable; `lastBackupSucceededAt` is never advanced on failure. |
| **NEW PRODUCTION FILES** | 3 — `EvenAI/Core/Domain/PersonalAI/BackupAuthorization.swift`, `EvenAI/Infrastructure/PersonalAI/Backup/BackupAuthorizationClient.swift`, `EvenAI/Infrastructure/PersonalAI/Backup/R2ProductionBackupAdapter.swift`. Plus 1 modified: `EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift` (+37/−1, additive). |
| **NEW TEST FILES** | 2 — `EvenAITests/TestDoubles/FakeBackupAuthorizationServer.swift`, `EvenAITests/PersonalAICloud/R2ProductionPathSecurityTests.swift`. |
| **TEST COUNTS** | See § 14 for the current run. `R2ProductionPathSecurityTests` 35/35 + `R2ProductionPathAuthorizationBypassTests` 12/12; existing backup suites 34/34; full `EvenAITests` **100 suites / 784 tests / 0 failed** (incl. the pre-existing untracked `ProductionEndpointContractTests`, not modified). |
| **R1 (raw-store bypass)** | **FIXED (§ 14)** — `R2BackupStore` raw init is `private`; `authorized(...)` needs a `RemoteBackupCompositionAuthority` mintable only inside `R2ProductionBackupAdapter.swift`, so `R2ProductionBackupAdapter.makeStore(...)` is the sole path to a remote-capable store and `BackupAuthorizationClient` is unconditionally in the chain. Compiler-enforced. Tests: `noRawR2BackupStoreConstruction`, `compositionAuthorityIsConfined`, `authorizedFactoryNotCalledDirectly`, `normalProductionAPICannotBypassGuard`, `guardedFactoryEnforcesAuthorization`. |
| **R2 (scope no-op in prod path)** | **FIXED (§ 14)** — the earlier version synthesised the grant scope from the same `(operation, key, ownerTag)` the client then checked it against, so `covers(...)` was a tautology on the production `WorkerBackupCredentialProvider` path. Now the scope is the authorizer's server-derived scope, carried through verbatim; the provider is bound to its authenticated identity and refuses a foreign owner or a scope-less response; `BackupAuthorizationClient.covers(...)` is a real check against an independent source. Tests: `missingScopeFails`, `wrongOperationFails`, `wrongObjectFails`, `wrongOwnerFails`, `expiredScopedGrantFails`, `exactValidScopeSucceeds`, `scopeSurvivesEndToEnd`, `workerProviderRefusesUnscopedResponse`, `workerProviderRejectsMismatchedServerScope`, `workerProviderRefusesForeignOwnerRequest`. |
| **R3 (presigned URL is a bearer capability)** | **INHERENT — DOCUMENTED, NOT FIXABLE CLIENT-SIDE.** A signed URL grants whoever holds it until it expires or is spent. Mitigations, all present: short TTL (minutes), single-use for mutation (edge `409`), HTTPS-only, no logging of the URL / token / grant id, and the guarantee that a user can never *obtain* a grant outside its own derived namespace. Full mitigation (per-request binding, IP/again-scoping) is server-side. |
| **R4 (request-body nonce / replay dedup)** | **REQUIRES A DEPLOYED WORKER — NOT PRODUCTION-VERIFIED.** The `cloudflare/backup-worker/` code includes a coarse KV-backed dedup on `(identity, operation, key)` within the grant-TTL window (`src/replay.ts`) — a *get-then-put*, not an atomic compare-and-swap, and with no client-supplied nonce (the Swift `PresignRequestBody` carries none). This narrows but does not close the window, and **none of it runs anywhere**: the Worker is not deployed, no KV namespace exists, and local tests simulate KV in memory. Replay protection remains a deployment-hardening item, not a solved problem. |
| **REAL R2 BUCKET** | **NOT CREATED** |
| **WORKER** | **NOT DEPLOYED** |
| **REAL AUTH** | **NOT CONFIGURED** |
| **REAL NETWORK CALLS ENABLED** | NO — every transport in a shipping build is `DormantBackupObjectTransport`; the fakes are in-memory. |
| **REAL CREDENTIALS ADDED** | NO |
| **BILLING CONFIGURED** | NO |
| **REAL NETWORK R2 BACKUP** | **NOT VERIFIED** |
| **REAL OFF-DEVICE DURABILITY** | **NOT VERIFIED** |
| **REAL R2 RESTORE** | **NOT VERIFIED** |
| **CLOUDKIT CHANGED** | NO — no CloudKit file touched; the Step 2 stash and Desktop patch are untouched. |
| **G2 RUNTIME CHANGED** | NO — `AIConversationEngine`, Voice, Glasses, Conversations, backend/Railway all `git diff`-clean. |
| **SAFE TO REVIEW** | YES — additive / access-tightening only; shipping default unchanged; builds + full regression green; not committed, not pushed. |

---

## 13. RE-VERIFICATION — 2026-08-31

A follow-up audit re-examined this same uncommitted working tree against R1
(raw-store bypass) and R2 (scope no-op) specifically, expecting to find them
still open. They were not: both fixes described in § 9 and § 12 above were
already present and already correct — `R2BackupStore`'s raw initializer was
already `private`, `WorkerBackupCredentialProvider` was already stamping and
validating `scope`, and every adversarial test category (bypass prevention,
missing scope, wrong user/owner, wrong operation, wrong object, expired
scoped grant, valid exact scope, provider→client scope propagation) already
existed in `R2ProductionPathSecurityTests`. **No production or test code was
changed in this pass** — the existing implementation was re-verified, not
re-fixed.

Fresh full test run (`xcodebuild test-without-building`, iPhone 17 /
iOS 26.5 simulator, after a clean `build` + `build-for-testing`):

| Scope | Result |
|---|---|
| `R2ProductionPathSecurityTests` (all 33, incl. the 9 R1/R2-specific tests) | 33/33 |
| Existing pre-workstream backup suites (`R2BackupStoreTests`, `BackupEncryptionTests`, `BackupHardeningTests`, `BackupProviderIndependenceTests`) | 34/34 |
| All Personal AI tests (`EvenAITests/PersonalAI/` + `EvenAITests/PersonalAICloud/`, 35 suites) | 280/280 |
| Critical SwiftData / `AIConversationEngine` suites (8 `AIConversationEngine*` + `CloudKitAdapterStatePersistenceTests`) | 142/142 |
| Full `EvenAITests` (99 suites, incl. the pre-existing unrelated `ProductionEndpointContractTests`) | 770/770 |
| `xcodebuild build` | BUILD SUCCEEDED |
| `xcodebuild build-for-testing` | TEST BUILD SUCCEEDED |

Zero failures anywhere. Guardrails re-checked and intact: `git status`
unchanged from before this pass (same 4 modified + 7 untracked files, nothing
added or staged); CloudKit Step 2 stash still present at
`7efa6d4869353833e4ca02c6ae3baf315b0d9598`; `~/Desktop/cloudkit-step2.patch`
MD5 still `a80809f705cf73ad24cdf513e41b673a`; `ProductionEndpointContractTests.swift`
still untracked and untouched. Nothing committed or pushed.

> **Superseded by § 14.** This re-verification's conclusion — "both fixes were
> already present and already correct, no code changed" — was **wrong about
> R2**. On the production `WorkerBackupCredentialProvider` path the grant scope
> was synthesised from the same `(operation, key, ownerTag)` the client then
> checked it against, making `grant.covers(...)` a tautology. That is the
> no-op R2 names, and it was still open. § 14 is the pass that actually
> closed it. (The workstream was later committed as
> `ea0ab4f Add production-safe R2 backup path`; the § 14 hardening and the
> `cloudflare/backup-worker/` Worker are the remaining uncommitted work.)

---

## 14. R1 / R2 HARDENING — 2026-08-31 (uncommitted)

Baseline for this pass: `ea0ab4f Add production-safe R2 backup path` (= `HEAD`
= `origin/main`). This pass changes production Swift + tests only. **No
Cloudflare account, bucket, Worker deploy, KV namespace, credential, billing,
or network activation.** Not committed, not pushed.

### R1 — the safe composition path is the *only* path

**Before:** `R2BackupStore`'s raw initializer was `private`, but its
`static authorized(credentials:transport:)` factory was module-visible, so any
code could compose a remote-capable store without going through the audited
`R2ProductionBackupAdapter` boundary. (Every path still wrapped
`BackupAuthorizationClient`, so it was not a client-guard bypass — but it was
not a *compositionally* enforced single entry either.)

**Now:**

- `R2BackupStore.authorized(credentials:transport:authority:ownerTagger:)`
  requires a `RemoteBackupCompositionAuthority`.
- `RemoteBackupCompositionAuthority`'s initializer is `fileprivate` to
  `R2ProductionBackupAdapter.swift`. Nothing else in the module — production or
  test — can mint one.
- Therefore `R2ProductionBackupAdapter.makeStore(...)` is the **only** way to
  obtain a remote-capable `R2BackupStore`; `.dormant` (reaches no network) is
  the only other form. `BackupAuthorizationClient` is unconditionally in the
  chain of every store that can touch a network.
- `FakeR2.store` and the security tests were updated to compose via
  `R2ProductionBackupAdapter.makeStore`.

Enforced by: the compiler (the capability type), plus source-scanning tests
`compositionAuthorityIsConfined` (the authority is constructed only in the
adapter file) and `authorizedFactoryNotCalledDirectly` (no other file calls
`R2BackupStore.authorized(`), plus the runtime test
`normalProductionAPICannotBypassGuard` (a store from `makeStore` refuses
expired / unscoped grants).

### R2 — the grant scope is a server-authoritative binding, not a copy of the request

**Before:** on the production `WorkerBackupCredentialProvider` path,
`presign(op, key, ownerTag)` built
`scope = BackupAuthorizationScope(ownerTag, key, operation)` from its **own
arguments**, and any server-returned scope was validated then discarded. The
client then called `grant.covers(op, key, ownerTag)` with the **same
arguments** — a tautology. The `covers` / `scope` check was a no-op on the one
path that matters in production. The scope's owner also came from the
caller-supplied `ownerTag`, not from an authenticated identity.

**Now `WorkerBackupCredentialProvider`:**

1. is constructed with `authenticatedUserID` — the identity it is
   authenticated as, wired by the DI container from the **same** signed-in
   session as `identityToken`. It derives `authenticatedOwnerTag` from that.
2. treats the per-call `ownerTag` as *intent*: a call for any owner other than
   `authenticatedOwnerTag` is refused (`scopeMismatch`) before any network
   call. Caller-supplied identity never overrides authenticated identity.
3. sends the **authenticated** owner tag to the Worker, not the caller's.
4. **requires** the Worker response to carry the `scope` it authoritatively
   granted (server-derived from the verified identity). No scope →
   `scopeMissing`. The client never synthesises one.
5. checks that server scope's `ownerTag` is `authenticatedOwnerTag`
   (`scopeMismatch` otherwise) — a real check: response vs. construction-time
   identity, independent sources.
6. carries the **server's** scope (operation + key + owner) through to
   `PresignedBackupRequest.scope` verbatim.

**And `BackupAuthorizationClient`:** `grant.covers(operation, key, ownerTag)`
now compares the *server-derived* grant scope against the caller's request —
two independent inputs — and throws `.scopeMismatch` on any disagreement
(operation, key, or owner). Missing scope is still `.scopeMissing`; expiry is
still checked first.

Rejections proven by adversarial tests (`R2ProductionPathAuthorizationBypassTests`,
plus additions to `R2ProductionPathSecurityTests`): missing scope
(`missingScopeFails`, `workerProviderRefusesUnscopedResponse`), wrong
operation (`wrongOperationFails`), wrong object/backup (`wrongObjectFails`),
wrong owner (`wrongOwnerFails`, `workerProviderRejectsMismatchedServerScope`,
`workerProviderRefusesForeignOwnerRequest`), expired scoped grant
(`expiredScopedGrantFails`, `workerExpiredGrantRejected`), exact valid scope
(`exactValidScopeSucceeds`, `workerProviderProducesScopedGrant`), and
end-to-end scope survival credential-provider → request → authorization
(`scopeSurvivesEndToEnd`). No secret / plaintext introduced
(`changesIntroduceNoSecret`, `fixesIntroduceNoSecretOrPlaintext`).

### R3 / R4 — unchanged, still honest

- **R3** — a presigned URL is a bearer capability for whoever holds it until it
  expires or (for a mutation) is spent. Inherent to S3/R2 presigned URLs; not
  fixable client-side. Mitigations unchanged: short TTL, single-use for
  mutation, HTTPS-only, never logged, and the guarantee a caller can never
  obtain a grant outside its own derived namespace.
- **R4** — request-body replay dedup is a **deployed-Worker** requirement. The
  `cloudflare/backup-worker/src/replay.ts` code is a coarse, non-atomic,
  nonce-less KV heuristic that **runs nowhere** (Worker not deployed, no KV
  namespace, tests simulate KV in memory). Not implemented as a real control,
  not production-verified.

### Files changed in this pass

| File | Change |
|---|---|
| `EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift` | `+ BackupCredentialError.scopeMismatch` |
| `EvenAI/Infrastructure/PersonalAI/Backup/BackupAuthorizationClient.swift` | scope-guard failure → `.scopeMismatch`; comment |
| `EvenAI/Infrastructure/PersonalAI/Backup/BackupCredentialProviders.swift` | `WorkerBackupCredentialProvider`: `authenticatedUserID` binding; server-authoritative scope; `scopeMissing` on no scope; `409 → replayed` |
| `EvenAI/Infrastructure/PersonalAI/Backup/R2BackupStore.swift` | `private guarded(...)`; `authorized(...)` requires `RemoteBackupCompositionAuthority`; `.dormant` unchanged behaviour |
| `EvenAI/Infrastructure/PersonalAI/Backup/R2ProductionBackupAdapter.swift` | `+ RemoteBackupCompositionAuthority` (fileprivate init); `makeStore` mints it |
| `EvenAITests/PersonalAICloud/R2ProductionPathSecurityTests.swift` | reshaped R1/R2 tests for the new API; `+ R2ProductionPathAuthorizationBypassTests` suite |
| `EvenAITests/TestDoubles/FakeBackupInfra.swift` | `FakeR2.store` composes via `R2ProductionBackupAdapter.makeStore` |
| `cloudflare/backup-worker/wrangler.jsonc` | comment corrected: no R2 bucket has been created (it had claimed one existed) |

### Verification (iPhone 17 / iOS 26 simulator, after clean `build` + `build-for-testing`)

| Scope | Result |
|---|---|
| `R2ProductionPathSecurityTests` | 35/35 |
| `R2ProductionPathAuthorizationBypassTests` (new) | 12/12 |
| Existing backup suites (`R2BackupStoreTests`, `BackupEncryptionTests`, `BackupHardeningTests`, `BackupProviderIndependenceTests`) | 34/34 |
| Personal AI — `EvenAITests/PersonalAI/` (13 suites) + `EvenAITests/PersonalAICloud/` non-backup (17 suites) + backup/R2 (6 suites) | 70/70 + 143/143 + 81/81 = 294/294 |
| Critical SwiftData / `AIConversationEngine` (8 `AIConversationEngine*` + `CloudKitAdapterStatePersistenceTests`) | 132/132 |
| Full `EvenAITests` | **100 suites / 784 tests / 784 passed / 0 failed** |
| `xcodebuild build` | ** BUILD SUCCEEDED ** |
| `xcodebuild build-for-testing` | ** TEST BUILD SUCCEEDED ** |
| `cloudflare/backup-worker` `npm test` (Miniflare, no network) | 31/31 |

Guardrails: `git status` = 2 untracked (`cloudflare/`, `EvenAITests/ProductionEndpointContractTests.swift`)
before this pass; after, the same 2 plus the modified Swift/doc files above —
nothing staged, nothing committed, nothing pushed. `HEAD` = `origin/main` =
`ea0ab4f689192e25ca0ee9223396d1a4cefd31e8`. CloudKit Step 2 stash intact at
`7efa6d4869353833e4ca02c6ae3baf315b0d9598`; `~/Desktop/cloudkit-step2.patch`
MD5 `a80809f705cf73ad24cdf513e41b673a`; `ProductionEndpointContractTests.swift`
untracked and untouched. No CloudKit, G2 runtime, backend, or Railway file
changed.
