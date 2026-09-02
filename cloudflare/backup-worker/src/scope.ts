// Mirrors EvenAI/Core/Domain/PersonalAI/BackupAuthorization.swift's
// BackupAuthorizationScope.keyIsWellFormed / keyIsInOwnerNamespace and
// EvenAI/Core/Domain/PersonalAI/BackupObjectNamespace.swift's version-prefix
// handling — same rules, same reasons. The client enforces this defensively;
// this is the authoritative, server-side copy. Any drift between the two
// implementations is a security bug, not a style choice — keep them in sync by
// inspection (same convention the JS/Swift title-derivation logic uses; see
// CHANGELOG.md Milestone 2). The cross-language namespace test vectors in
// test/object-namespace.test.ts pin the shapes both sides must agree on.

const MAX_KEY_BYTES = 512;

/// The namespace versions this Worker recognises. An UNKNOWN version's
/// `backup/vX/` prefix is NOT stripped, so such a key can never match an owner
/// namespace — unknown versions fail safely, they are never reinterpreted.
/// Keep in sync with `BackupObjectNamespace.recognisedVersions` (Swift).
export const RECOGNISED_NAMESPACE_VERSIONS: ReadonlySet<number> = new Set([1]);
export const CURRENT_NAMESPACE_VERSION = 1;

export function keyIsWellFormed(key: string): boolean {
  if (key.length === 0) return false;
  if (new TextEncoder().encode(key).length > MAX_KEY_BYTES) return false;
  for (const ch of key) {
    const code = ch.codePointAt(0)!;
    if (code < 0x20 || code === 0x7f) return false;
  }
  if (key.startsWith("/") || key.includes("//")) return false;
  const segments = key.split("/");
  if (segments.some((s) => s === "." || s === ".." || s === "")) return false;
  return true;
}

/// If `key` begins `backup/v<N>/` for a RECOGNISED N, return the remainder;
/// otherwise return `key` unchanged (an unknown version keeps its prefix).
export function strippingRecognisedVersionPrefix(key: string): string {
  const slash1 = key.indexOf("/");
  if (slash1 < 0) return key;
  const slash2 = key.indexOf("/", slash1 + 1);
  if (slash2 < 0) return key;
  const root = key.slice(0, slash1);
  const versionSeg = key.slice(slash1 + 1, slash2);
  if (root !== "backup" || !versionSeg.startsWith("v")) return key;
  const n = Number(versionSeg.slice(1));
  if (!Number.isInteger(n) || !RECOGNISED_NAMESPACE_VERSIONS.has(n)) return key;
  return key.slice(slash2 + 1);
}

export function keyIsInOwnerNamespace(key: string, ownerTag: string): boolean {
  if (!keyIsWellFormed(key)) return false;
  const body = strippingRecognisedVersionPrefix(key);
  return body === ownerTag || body.startsWith(ownerTag + "/");
}
