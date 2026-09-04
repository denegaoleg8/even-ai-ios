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
 * built client-side by the iOS app's `OpenAIResponsesTransport` (this
 * proxy is intentionally "thin": it authenticates, validates size, adds
 * the OpenAI key, forwards, and maps errors — it does not reshape the
 * payload). Only the fields this proxy actually inspects are declared;
 * everything else passes through in the raw body text untouched.
 */
export interface OpenAIResponsesRequestBody {
  model: string;
  instructions?: string;
  input: { role: string; content: string }[];
  max_output_tokens?: number;
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
