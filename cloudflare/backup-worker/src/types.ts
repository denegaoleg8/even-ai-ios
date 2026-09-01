// Wire types mirroring EvenAI/Infrastructure/PersonalAI/Backup/BackupCredentialProviders.swift's
// PresignRequestBody / PresignResponseBody exactly. This Worker is the server
// half of that existing, already-audited Swift contract — it must not invent
// a second, incompatible shape.

export type BackupObjectOperation = "put" | "get" | "delete" | "head" | "list";

export interface PresignRequestBody {
  operation: BackupObjectOperation;
  key: string;
  ownerTag: string;
}

export interface GrantScope {
  ownerTag: string;
  objectKey: string;
  operation: BackupObjectOperation;
}

export interface PresignResponseBody {
  url: string;
  headers?: Record<string, string>;
  expiresInSeconds: number;
  grantID?: string;
  scope?: GrantScope;
}

export interface ErrorBody {
  error: { code: string; message: string };
}

// Bindings + secrets this Worker expects. None of these values are created
// or set by this pass — see wrangler.jsonc's comments and
// PHASE2_R2_PRODUCTION_PATH.md § 11 for what remains a deployment gate.
export interface Env {
  BACKUP_BUCKET: R2Bucket;
  REPLAY_NONCES: KVNamespace;

  // Salted-hash secret used to derive the opaque owner namespace from a
  // verified identity subject. Must match the algorithm/salt
  // BackupOwnerTag.tag() uses client-side, or a device's own locally-computed
  // prefix and the Worker's authoritative one will disagree. Never hardcoded;
  // set via `wrangler secret put OWNER_TAG_SALT` at deploy time.
  OWNER_TAG_SALT?: string;

  // R2 S3-compatible API credentials, scoped to exactly the
  // evenai-personal-ai-backups bucket (Object Read & Write only). Required
  // because presigned URLs — the existing client contract — can only be
  // minted via AWS SigV4 signing against R2's S3 API; a binding alone cannot
  // produce a URL usable by an external client. Never set in this pass.
  R2_ACCESS_KEY_ID?: string;
  R2_SECRET_ACCESS_KEY?: string;
  // Account-scoped S3 API endpoint, e.g.
  // https://<account-id>.r2.cloudflarestorage.com
  R2_S3_ENDPOINT?: string;

  // DEV-ONLY test identity mechanism (see auth.ts). Must never be "true" in
  // a real deployment; documented here, not enabled anywhere by this pass.
  ALLOW_DEV_IDENTITY?: string;
}
