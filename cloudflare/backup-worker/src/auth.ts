// Identity verification boundary. This is the one place that is allowed to
// say "this request is authenticated as subject X" — everywhere else in the
// Worker must treat the caller-supplied `ownerTag` in the request body as an
// unverified claim only (see index.ts, which never uses it for the
// authorization decision, only to cross-check it matches what this file
// derives).
//
// PRODUCTION IDENTITY IS NOT IMPLEMENTED HERE. The real mechanism (Sign in
// with Apple / the EvenAI account token, verified against Apple's/the
// backend's JWKS) is a separate, later gate — see
// PHASE2_R2_PRODUCTION_PATH.md § 11 "Production auth provider". Wiring a
// fake identity into a real deployment would be exactly the "invent
// insecure identity" failure this project has repeatedly refused to ship
// (see BackupCredentialProviding's own doc comment: production defaults to
// NotConfiguredBackupCredentialProvider until a real identity source
// exists).
//
// What exists here instead is a DEV-ONLY test identity path, structurally
// incapable of running unless an operator explicitly opts in via
// env.ALLOW_DEV_IDENTITY === "true" (never set by this local-implementation
// pass, and — by design — a value an operator must consciously set, not a
// default). It exists so this Worker's authorization logic (owner-tag
// derivation, namespace isolation, scope, replay) can be built and tested
// end-to-end today without a real identity provider blocking that work.

export class UnauthenticatedError extends Error {}

export interface VerifiedIdentity {
  /** Stable subject identifier for this caller. Never logged in full. */
  subject: string;
}

const DEV_BEARER_PREFIX = "dev-test:";

export function verifyIdentity(request: Request, env: { ALLOW_DEV_IDENTITY?: string }): VerifiedIdentity {
  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    throw new UnauthenticatedError("missing bearer token");
  }
  const token = authHeader.slice("Bearer ".length).trim();
  if (token.length === 0) {
    throw new UnauthenticatedError("empty bearer token");
  }

  if (token.startsWith(DEV_BEARER_PREFIX)) {
    if (env.ALLOW_DEV_IDENTITY !== "true") {
      // Dev-shaped token presented against a Worker that hasn't explicitly
      // opted into dev identity: refuse rather than silently accept it as
      // if it were a real credential.
      throw new UnauthenticatedError("dev identity not enabled");
    }
    const subject = token.slice(DEV_BEARER_PREFIX.length);
    if (subject.length === 0) {
      throw new UnauthenticatedError("empty dev subject");
    }
    return { subject: `dev:${subject}` };
  }

  // No real identity provider is wired yet. Every non-dev-shaped token is
  // refused — never treated as pre-verified, never inspected for a claimed
  // user id.
  throw new UnauthenticatedError("no production identity provider configured");
}
