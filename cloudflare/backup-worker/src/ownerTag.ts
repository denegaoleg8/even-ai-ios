// Owner-tag derivation — the ONE canonical algorithm, identical to the iOS
// client's `BackupOwnerTag.tag(_:)` (EvenAI/Infrastructure/PersonalAI/Backup/
// EncryptedBackupEnvelope.swift). The prior audit flagged that the Worker and
// the client MUST derive byte-identical tags before deployment; this file is
// that alignment. Proof lives in fixed cross-language test vectors:
//   - Worker: test/owner-tag-vectors.test.ts
//   - Swift:  EvenAITests/PersonalAICloud/R2DeploymentContractTests.swift
// Both check the SAME expected hex constants. If either implementation drifts,
// its vector test fails.
//
// ## Algorithm — ownerTag v1
//
//   ownerTagV1(canonicalUserID) = lower_hex( SHA-256( DOMAIN || utf8(canonicalUserID) ) )
//
//   DOMAIN = utf8("evenai.personal-ai.backup.owner-tag.v1")   // fixed, ASCII
//
// - `canonicalUserID` is the verified identity's stable subject (see auth.ts /
//   PHASE2_R2_DEPLOYMENT_READINESS.md §3) — the SAME string the client passes
//   as its Personal AI user id. No email, no display name, no PII.
// - No separator byte between DOMAIN and the id: DOMAIN is a fixed known
//   prefix, so `id -> tag` is injective (up to SHA-256) and no two distinct
//   ids collide via the prefix. This exactly mirrors the Swift
//   `Data(domain.utf8) + Data(id.utf8)` construction — keep them in lock-step.
// - **The domain string is NOT a secret.** It is compiled into the iOS binary
//   already, so a Worker-only secret salt here would only guarantee the two
//   sides DISAGREE. Tag unlinkability rests on `canonicalUserID` being
//   unpredictable and the stored objects being ciphertext — not on a secret.
//   A future ownerTag v2 (server-authoritative `HMAC-SHA256(worker_secret,
//   canonicalUserID)`, returned to the client, never recomputed on-device) is
//   specified in the readiness doc as an upgrade path, not implemented here.

export const OWNER_TAG_DOMAIN_V1 = "evenai.personal-ai.backup.owner-tag.v1";

export async function deriveOwnerTagV1(canonicalUserID: string): Promise<string> {
  const domain = new TextEncoder().encode(OWNER_TAG_DOMAIN_V1);
  const id = new TextEncoder().encode(canonicalUserID);
  const preimage = new Uint8Array(domain.length + id.length);
  preimage.set(domain, 0);
  preimage.set(id, domain.length);
  const digest = await crypto.subtle.digest("SHA-256", preimage);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
