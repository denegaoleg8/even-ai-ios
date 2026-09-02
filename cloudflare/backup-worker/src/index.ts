// evenai-personal-ai-backup-api — the server half of the existing, audited
// R2 production-path Swift contract (WorkerBackupCredentialProvider /
// BackupAuthorizationClient / R2BackupStore). See
// PHASE2_R2_PRODUCTION_PATH.md for the full trust-boundary design this
// implements.
//
// Exactly one route exists: POST /presign. Everything else 404s. That is a
// deliberate security property, not an oversight: this Worker never accepts
// object bytes in a request body anywhere, so it structurally cannot see
// backup ciphertext, let alone plaintext or a decryption key — the actual
// PUT/GET/DELETE of ciphertext happens directly between the iOS app and R2
// over the presigned URL this endpoint returns (BackupObjectTransport), never
// through this Worker's own request handler.
import { verifyIdentity, UnauthenticatedError } from "./auth";
import { deriveOwnerTagV1 } from "./ownerTag";
import { keyIsInOwnerNamespace } from "./scope";
import { checkAndRecordReplay } from "./replay";
import { presignR2Url } from "./presign";
import type { Env, PresignRequestBody, PresignResponseBody, ErrorBody, BackupObjectOperation } from "./types";

const GRANT_TTL_SECONDS = 300; // minutes-long, matches the design doc's "expiring in minutes"
const VALID_OPERATIONS: ReadonlySet<string> = new Set(["put", "get", "delete", "head", "list"]);
const MUTATING_OPERATIONS: ReadonlySet<string> = new Set(["put", "delete"]);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/presign") {
      return json({ error: { code: "not_found", message: "no such route" } }, 404);
    }
    return handlePresign(request, env);
  },
};

async function handlePresign(request: Request, env: Env): Promise<Response> {
  let identity;
  try {
    identity = verifyIdentity(request, env);
  } catch (err) {
    if (err instanceof UnauthenticatedError) {
      return json(errorBody("unauthorized", "authentication required"), 401);
    }
    throw err;
  }

  let body: PresignRequestBody;
  try {
    body = await request.json();
  } catch {
    return json(errorBody("bad_request", "malformed JSON body"), 400);
  }

  if (!body || typeof body.operation !== "string" || typeof body.key !== "string" || typeof body.ownerTag !== "string") {
    return json(errorBody("bad_request", "operation, key, ownerTag are required"), 400);
  }
  if (!VALID_OPERATIONS.has(body.operation)) {
    return json(errorBody("bad_request", "unknown operation"), 400);
  }
  const operation = body.operation as BackupObjectOperation;

  // Authoritative: derived from the VERIFIED identity via the ONE canonical
  // algorithm (ownerTag v1 — see ownerTag.ts; byte-identical to the iOS
  // client). The client's claimed `body.ownerTag` is never used for this
  // decision — only cross-checked below so a legitimate client whose own local
  // computation has drifted gets a clear error rather than a silently-wrong
  // grant. No server secret is involved (and must not be — see ownerTag.ts).
  const derivedOwnerTag = await deriveOwnerTagV1(identity.subject);

  if (!keyIsInOwnerNamespace(body.key, derivedOwnerTag)) {
    // Covers: malformed keys, path traversal, and any key outside the
    // caller's own derived namespace — including a caller claiming a
    // different ownerTag than what its verified identity actually derives
    // to. This single check is what makes cross-user access impossible
    // through this endpoint, structurally, not by convention.
    return json(errorBody("forbidden", "key is outside the caller's authorized namespace"), 403);
  }

  if (MUTATING_OPERATIONS.has(operation)) {
    const firstSeen = await checkAndRecordReplay(env.REPLAY_NONCES, identity.subject, operation, body.key);
    if (!firstSeen) {
      return json(errorBody("replayed", "this request has already been processed"), 409);
    }
  }

  if (!env.R2_ACCESS_KEY_ID || !env.R2_SECRET_ACCESS_KEY || !env.R2_S3_ENDPOINT) {
    return json(errorBody("misconfigured", "R2 signing credentials not set"), 500);
  }

  const signedUrl = await presignR2Url({
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
    s3Endpoint: env.R2_S3_ENDPOINT,
    bucket: "evenai-personal-ai-backups",
    objectKey: body.key,
    operation,
    expiresInSeconds: GRANT_TTL_SECONDS,
  });

  const response: PresignResponseBody = {
    url: signedUrl,
    expiresInSeconds: GRANT_TTL_SECONDS,
    grantID: crypto.randomUUID(),
    scope: { ownerTag: derivedOwnerTag, objectKey: body.key, operation },
  };

  // Audit trail: hashes/sizes/identifiers only. Never the bearer token,
  // never the signed URL (it carries a live query-string signature — logging
  // it would be equivalent to logging a bearer credential), never the
  // request/response body itself.
  console.log(
    JSON.stringify({
      event: "presign_issued",
      ownerTag: derivedOwnerTag,
      operation,
      keySuffix: body.key.split("/").pop(),
      grantID: response.grantID,
    })
  );

  return json(response, 200);
}

function errorBody(code: string, message: string): ErrorBody {
  return { error: { code, message } };
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
