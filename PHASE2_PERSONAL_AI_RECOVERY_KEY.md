# Phase 2 — Personal AI Backup Recovery Key

**Local implementation + local tests only.** No cloud key-escrow service, no
new-device restore verified on real hardware, no change to where backups are
stored (still nowhere off-device in a shipping build). Baseline:
`ce05bf4 Add R2 deployment readiness plan`.

This closes the **recovery-key** gap that `PHASE2_R2_DEPLOYMENT_READINESS.md`
§13.A flagged: an encrypted backup could only be decrypted on the device that
made it, because the key lived only in that device's Keychain
(`…ThisDeviceOnly`, never synced). A backup you cannot restore on a new phone
is not a disaster-recovery backup.

---

## 0. STATUS

| | |
|---|---|
| Recovery-key type + envelope key-wrapping | **IMPLEMENTED LOCALLY** |
| Recovery-key generation / export code / recovery file | **IMPLEMENTED + TESTED LOCALLY** |
| Wrong / corrupted / rotated key rejection | **TESTED LOCALLY** |
| "no key material in header / manifest / remote payload / logs" | **TESTED LOCALLY** |
| Restore-on-a-real-new-iPhone | **NOT VERIFIED** (needs two physical devices + a real backup target) |
| Cloud key escrow / iCloud-Keychain recovery | **NOT IMPLEMENTED — deferred** |
| Passphrase-derived recovery key | **NOT IMPLEMENTED — deferred** (needs a memory-hard KDF) |
| Wiring into `PersonalAIContainer.live` + recovery UI | **NOT DONE — deferred** (model seam only) |
| Real off-device backup / real R2 restore | **NOT VERIFIED** (unchanged — see the R2 docs) |

---

## 1. FOUR INDEPENDENT SECRETS — DO NOT CONFLATE

| Secret | What it is | Where it lives | Ever sent to the Worker / R2? |
|---|---|---|---|
| **Device encryption key** | AES-256, `SymmetricKeyStore` | iOS Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, own service | **No** |
| **Recovery key** (this doc) | AES-256, `PersonalAIRecoveryKey` — a *key-encryption key* | the user holds the `recoveryCode` / recovery file; optionally a device copy in `KeychainRecoveryKeyStore` | **No** |
| **Worker signing / auth secrets** | JWKS config, (future) owner-tag HMAC key | Worker secrets (`wrangler secret put`) | n/a (they are the Worker's) |
| **R2 service credentials** | S3 access key + secret | Worker secrets only | **No — never in the app** |

The recovery key never unlocks an auth token; the device key never unlocks
R2; none of them is derived from another.

---

## 2. HOW A BACKUP IS ENCRYPTED NOW

Two envelope formats (`EncryptedBackupEnvelope`, magic `"EAPB"`):

### `"EAPB1"` — direct (unchanged)

No recovery key configured → the payload is sealed **directly** with the
device key. Restorable **only on the same device**. Every pre-existing backup
and every test that doesn't configure a recovery key still uses this — nothing
about it changed.

### `"EAPB2"` — wrapped (new, recovery-capable)

A recovery key is configured →

```
DEK   = SymmetricKey(size: .bits256)                 fresh, per backup
ciphertext = AES-GCM-seal(bundle, using: DEK)
header.keyWrapping.slots = [
  { kind: "device",   keyID: fingerprint(deviceKey),  wrappedKey: AES-GCM-seal(DEK, using: deviceKey)   },
  { kind: "recovery", keyID: recoveryKey.keyID,        wrappedKey: AES-GCM-seal(DEK, using: recoveryKey) },
]
```

- **Standard envelope encryption / key wrapping** — AES-256-GCM throughout, no
  home-grown crypto.
- The header carries **only** wrapped (encrypted) DEK copies and
  **fingerprints** — never a raw key. `keyID` is
  `SHA-256(domain ‖ rawKey).prefix(8)` (16 hex), non-reversible, a slot
  selector.
- An old build that only knows `"EAPB1"` **rejects** an `"EAPB2"` blob cleanly
  (`unsupportedEnvelopeVersion`) instead of a confusing GCM failure.

Same-device open uses the **device** slot. A new phone uses `open(_:using:)`
with the recovery key → the **recovery** slot → the DEK → the payload.

---

## 3. `PersonalAIRecoveryKey`

`EvenAI/Infrastructure/PersonalAI/Backup/PersonalAIRecoveryKey.swift`.

| Property | Value |
|---|---|
| Entropy | **256 bits** — `SymmetricKey(size: .bits256)`. Never passphrase-derived. |
| Version | `currentVersion = 1`; export forms are version-tagged and a future version is *rejected*, never guessed |
| `keyID` | `SHA-256("evenai.personal-ai.recovery-key.v1.id" ‖ rawKey).prefix(8)` → 16 hex. Deterministic, opaque, per-key distinct. |
| Integrity | a truncated SHA-256 **checksum** is embedded in every export form; a mistyped code / corrupted file is rejected **before** any decryption is attempted |
| `recoveryCode` | `EARK1-XXXX-XXXX-…` — RFC 4648 base32 (upper, no padding) of `rawKey(32) ‖ checksum(4)`, dash-grouped. Case-insensitive on import; body dashes / spaces optional; the `EARK<v>-` head separator is required. **This is key material.** |
| `serialized()` / `init(serialized:)` | a small framed binary (`"EARKF"` + version + header + `rawKey` + checksum) for programmatic storage (a Files document, a Mac). Same content, still key material. |

### Rotation / versioning

- **Recovery key version** (`PersonalAIRecoveryKey.currentVersion`) vs **backup
  key wrapping version** (`BackupKeyWrapping.version`) vs **envelope format
  digit** (`"EAPB2"`) vs **bundle schema version** (`BackupManifest`) are all
  independent.
- Rotating the recovery key: the DI wiring returns the *new* key from
  `AESGCMBackupEncryption(recoveryKey:)`; the **next** backup is wrapped for
  it. Older backups keep the recovery slot they were written with — their
  `keyID` records which key opens them.
- `open(_:using:)` matches strictly by `keyID`:
  - the **new** key against a **pre-rotation** backup → `recoveryKeyMismatch`
    (no silent wrong-key attempt);
  - the correct **historical** key → still works.
- `AESGCMBackupEncryption.recoverySlotKeyIDs(in:)` lets a restore UI tell the
  user *which* recovery key a given backup needs, without a decrypt attempt.
- **Lost recovery key + lost device key** → the backup is unrecoverable, by
  design (zero-knowledge to the server). This is why a real product needs
  either (a) the user reliably keeping the code, or (b) escrow — see §6.

---

## 4. EXPORT / RECOVERY UX CONTRACT (design — no UI built)

The model seam exists (`PersonalAIRecoveryKey`, `RecoveryKeyStore`); the UI is
future work. The intended flow:

**Set up (old phone, once):**
1. App generates a `PersonalAIRecoveryKey`.
2. App shows the `recoveryCode` and offers "Save recovery file" (a
   `serialized()` document the user puts in Files / AirDrops to a Mac /
   prints). Clear copy: *"this is like a password — anyone with it can decrypt
   your backups; we cannot recover it for you."*
3. App stores a copy in `KeychainRecoveryKeyStore` (device-only) so future
   backups re-wrap without re-prompting.
4. From now on, backups are `"EAPB2"` wrapped.

**Recover (new phone):**
1. User signs in (identity — separate concern, see the R2 auth contract).
2. App lists / downloads the encrypted backup (R2 path — still unbuilt).
3. App asks for the recovery code (typed) or the recovery file (picked from
   Files).
4. `PersonalAIRecoveryKey(recoveryCode:)` / `(serialized:)` validates it
   (checksum) — a wrong code is rejected here, before any decryption.
5. `AESGCMBackupEncryption.open(sealed, using: recoveryKey)` → bundle →
   `PersonalDataImporter.validate` → `importBundle`.
6. A failure at 4 or 5 changes **nothing** locally.

**Not claimed:** iCloud Keychain sync of the recovery key, iCloud-based
recovery, or any server-side recovery. If those are added later they are a new
section here, tested, before any such claim.

---

## 5. WHAT THE ENVELOPE / MANIFEST CARRIES (Part C)

Safe metadata **outside** the ciphertext (`EncryptedBackupEnvelopeHeader`):

| Field | Why it's safe |
|---|---|
| `encryptionScheme` (`"AES-GCM-256"`) | algorithm id |
| `createdAt`, `bundleVersion`, `bundleSchemaVersion` | ordering / migration |
| `ownerTag` (salted hash) | pre-decrypt owner check |
| `ciphertextSHA256`, `ciphertextLength` | truncation / bit-rot check |
| `keyWrapping.version`, `.algorithm` | wrapping scheme id |
| `keyWrapping.slots[].kind` (`"device"` / `"recovery"`) | slot type |
| `keyWrapping.slots[].keyID` | **fingerprint**, not the key — selects the slot |
| `keyWrapping.slots[].wrappedKey` | AES-GCM **ciphertext** of the DEK |

**Never** in the header, the bundle `BackupManifest`, a log, or any remote
payload: a raw recovery key, a raw device key, the DEK, the `recoveryCode`, or
plaintext memory / conversation data. Proven by
`PersonalAIRecoveryKeyTests`: `headerCarriesNoKeyMaterial`,
`remotePayloadCarriesNoRecoveryKey`, `manifestCarriesNoRecoveryKey`,
`noKeyMaterialLogged`.

`BackupManifest` is **unchanged** — no schema bump. The recovery metadata
belongs in the envelope header (you need it *before* you can decrypt); putting
a recovery-key id in the encrypted manifest would be useless for recovery.

---

## 6. DEFERRED (explicitly not built)

| Item | Why deferred | What it needs |
|---|---|---|
| Passphrase → recovery key | a low-entropy passphrase used as a key is unsafe | Argon2id / scrypt (memory-hard) — not in CryptoKit; a vetted dependency or a careful implementation, plus a UX for the work factor |
| Cloud key escrow | inventing a key-escrow service is exactly the failure this project refuses | a real, audited escrow design + user consent + threat model |
| iCloud Keychain recovery-key sync | not implemented; would change the key's protection class | switch `KeychainRecoveryKeyStore` off `…ThisDeviceOnly`, accept iCloud-Keychain trust, test |
| `PersonalAIContainer.live` wiring + recovery UI | model seam is enough for the gate; UI is a separate workstream | product design + the R2 path being real |
| Real new-iPhone restore verification | needs a real backup target + two devices | Gates H–M of the R2 deployment plan |

---

## 7. TESTS

`EvenAITests/PersonalAICloud/PersonalAIRecoveryKeyTests.swift` (18):

- `generatedKeyShape` — 256-bit, versioned, deterministic opaque id, entropy
- `recoveryCodeRoundTrip`, `serializationRoundTrip` — export forms round-trip, version preserved
- `corruptedCodeRejected`, `corruptedSerializationRejected` — mistyped / corrupted material rejected pre-use
- `unknownVersionRejected` — a future code version is rejected, not guessed
- `correctRecoveryKeyRestores` — the right key restores a wrapped backup with the device key absent
- `wrongRecoveryKeyFails` — wrong key → `recoveryKeyMismatch`, no plaintext
- `recoveryOpenOfDirectBackup` — recovery open of a non-wrapped backup → `recoveryNotAvailable`
- `corruptedWrappedMaterialFails` — flipped ciphertext byte → typed failure, no garbage
- `rotationCompatibility` — rotated key can't open a pre-rotation backup; historical key can; slot-id introspection works
- `headerCarriesNoKeyMaterial`, `remotePayloadCarriesNoRecoveryKey`, `manifestCarriesNoRecoveryKey` — no raw key anywhere it shouldn't be
- `noKeyMaterialLogged` — the recovery code paths contain no logging
- `failedRecoveryIsInert` — a failed recovery mutates / deletes nothing

Regression: every existing backup / encryption / R2 suite stays green — the
direct `"EAPB1"` path is byte-for-byte unchanged.
