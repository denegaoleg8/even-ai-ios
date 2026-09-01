// Closes (partially — see caveat below) R4, the request-level replay gap
// documented as an explicit deployment requirement in
// PHASE2_R2_PRODUCTION_PATH.md § 2 and § 11: "a captured presign POST
// request body must be rejected by the deployed Worker."
//
// SCOPE OF WHAT THIS PROTECTS: a captured `/presign` request being resent to
// mint a fresh valid grant repeatedly. It does NOT, and structurally cannot,
// make the *resulting presigned URL* single-use — R2's S3-compatible API has
// no concept of a one-time-use signature, so once a URL is issued it remains
// a bearer capability until it expires (this is R3, already documented as
// inherent and mitigated via short TTL, not "fixed" here or anywhere).
//
// DESIGN CHOICE — no client nonce field: the existing Swift
// PresignRequestBody (already audited, already committed) carries only
// {operation, key, ownerTag} — no nonce. Adding one would be a real, if
// small and additive, iOS contract change, which is explicitly out of scope
// for this Worker-only pass ("preserve the existing provider-independent
// Swift interfaces"). Instead this uses a coarser heuristic: dedupe on
// (identity, operation, key) within a short time window matching the grant
// TTL. This meaningfully raises the bar — a replay of the exact captured
// request within the window is rejected — without requiring any Swift
// change. A future client-supplied nonce would tighten this further and is
// documented as a real, additive next step, not implemented here.
//
// STORAGE PRIMITIVE — Workers KV, not Durable Objects: KV's free tier
// (100k reads/day, 1,000 writes/day, 1 GB — see
// PHASE2_R2_PRODUCTION_PATH.md's Cloudflare-docs-verified numbers) comfortably
// covers this Worker's expected volume and requires no paid plan. The
// alternative, a Durable Object, would give atomic compare-and-swap (closing
// the narrow get-then-put race noted below) but Durable Objects are a
// separate product decision with their own billing model — not introduced
// here per the explicit "stop before enabling a paid/materially billable
// primitive" instruction. If production traffic ever needs the atomicity, a
// per-owner Durable Object is a documented, deliberate upgrade, not an
// oversight.
//
// KNOWN LIMITATION: KV has no atomic "set if not exists" primitive
// accessible here, so this is get-then-put, not compare-and-swap. Two
// requests for the exact same (identity, operation, key) arriving within
// the same few milliseconds could both pass the check before either write
// lands. This narrows, but does not perfectly close, the replay window —
// consistent with R4 being tracked as a deployment-hardening item, not a
// solved problem.

const REPLAY_WINDOW_SECONDS = 300; // matches the presign grant TTL

export async function checkAndRecordReplay(
  kv: KVNamespace,
  subject: string,
  operation: string,
  key: string
): Promise<boolean> {
  const dedupeKey = await fingerprint(subject, operation, key);
  const existing = await kv.get(dedupeKey);
  if (existing !== null) {
    return false; // replay detected
  }
  await kv.put(dedupeKey, "1", { expirationTtl: REPLAY_WINDOW_SECONDS });
  return true; // first time seen in this window
}

async function fingerprint(subject: string, operation: string, key: string): Promise<string> {
  const data = new TextEncoder().encode(`${subject}\0${operation}\0${key}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `replay:${hex}`;
}
