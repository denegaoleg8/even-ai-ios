import type { Env } from "./types";

/**
 * App → proxy authorization only — a completely different trust domain
 * from `OPENAI_API_KEY` (proxy → OpenAI, see `src/openai.ts`). No
 * production identity system exists yet; this is a deliberately temporary
 * dev-only shared-secret check. Fails closed: unconfigured, missing, or
 * mismatched → rejected. Never "allow by default."
 */
export function isAuthorized(request: Request, env: Env): boolean {
  if (!env.APP_PROXY_SHARED_SECRET) return false;
  const header = request.headers.get("authorization");
  if (!header || !header.startsWith("Bearer ")) return false;
  const token = header.slice("Bearer ".length);
  return token.length > 0 && token === env.APP_PROXY_SHARED_SECRET;
}
