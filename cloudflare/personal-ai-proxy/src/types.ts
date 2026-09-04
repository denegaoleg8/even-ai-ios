/**
 * Worker environment bindings. `OPENAI_API_KEY` is a Cloudflare *secret*
 * (`wrangler secret put OPENAI_API_KEY`), never a plain `vars` entry and
 * never a literal value anywhere in this repo — see `wrangler.jsonc`'s
 * comment. `src/openai.ts` is the only file that reads it.
 */
export interface Env {
  OPENAI_API_KEY: string;
  /**
   * Dev-only, pre-production-identity app→proxy shared secret (see
   * `src/auth.ts`) — a completely different trust domain from
   * `OPENAI_API_KEY`. A real production identity system replaces this
   * later; until then the proxy fails closed whenever it's unset.
   */
  APP_PROXY_SHARED_SECRET?: string;
}

/**
 * The request body this proxy accepts — the OpenAI Responses API shape,
 * built client-side by the iOS app's `OpenAIResponsesTransport`. `model`
 * and `max_output_tokens` are declared `unknown`, not `string`/`number`:
 * this proxy does not trust either from the client at all — both are
 * resolved server-side by `src/requestPolicy.ts` regardless of what (if
 * anything) is present here, and the outbound OpenAI request is *rebuilt*
 * from the resolved values, never forwarded as raw body text (see
 * `buildOutboundBody` in `src/index.ts`). Everything else in this shape
 * (`instructions`, `input`) passes through unchanged — this proxy is
 * otherwise intentionally "thin."
 */
export interface OpenAIResponsesRequestBody {
  model?: unknown;
  instructions?: string;
  input: { role: string; content: string }[];
  max_output_tokens?: unknown;
}

export type ProviderNeutralErrorCategory =
  | "unavailable"
  | "transientFailure"
  | "hardFailure"
  | "unsupported";

export interface ProviderNeutralError {
  category: ProviderNeutralErrorCategory;
  reason: string;
}
