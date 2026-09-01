// Mirrors EvenAI/Core/Domain/PersonalAI/BackupAuthorization.swift's
// BackupAuthorizationScope.keyIsWellFormed / keyIsInOwnerNamespace exactly —
// same rules, same reasons. The client already enforces this defensively;
// this is the authoritative, server-side copy. Any drift between the two
// implementations is a security bug, not a style choice — keep them in sync
// by inspection, same convention the JS/Swift title-derivation logic already
// uses elsewhere in this project (see CHANGELOG.md Milestone 2).

const MAX_KEY_BYTES = 512;

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

export function keyIsInOwnerNamespace(key: string, ownerTag: string): boolean {
  if (!keyIsWellFormed(key)) return false;
  return key === ownerTag || key.startsWith(ownerTag + "/");
}
