// Server-side owner-tag derivation. MUST produce the same value as the
// client's BackupOwnerTag.tag(personalAIUserID) for a device's own
// locally-computed key prefix to agree with what this Worker authoritatively
// grants — but the two sides derive it independently from different inputs
// (the client from its own known user id, the Worker from the *verified*
// identity subject), so they can only agree if fed the same salt and the
// same underlying id. That reconciliation is part of the still-pending
// production identity integration (see auth.ts and
// PHASE2_R2_PRODUCTION_PATH.md § 11) — this function is deliberately generic
// (any string in, salted SHA-256 hex out) so it is correct algorithmically
// today and only needs the right *input* wired later, not a rewrite.
//
// The salt is never hardcoded — it must come from a Worker secret
// (env.OWNER_TAG_SALT), set via `wrangler secret put`, never committed.

export async function deriveOwnerTag(subject: string, salt: string): Promise<string> {
  const data = new TextEncoder().encode(`${salt}:${subject}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
