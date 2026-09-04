/**
 * Centralized, server-side-only request policy for the Personal AI OpenAI
 * proxy — model selection and the output-token ceiling. This is the ONLY
 * place either is decided; the client-facing request contract carries no
 * trusted value for either (see `src/index.ts`'s `buildOutboundBody`,
 * the one place this policy is applied and the one place the outbound
 * OpenAI request body is assembled). Change the allowlist/default/cap
 * here only — nothing else in this Worker, and nothing on the iOS side,
 * needs to change for a future model swap or cap adjustment.
 */

/** Every model this proxy is willing to forward a request to. */
export const ALLOWED_MODELS: readonly string[] = ["gpt-5.4-mini"];

/**
 * Used whenever the client's requested model is missing or not an exact
 * allowlisted match — which, in practice, is unconditionally the outcome
 * today, since only one model is allowlisted and it equals this default.
 * Kept as a distinct constant (not just `ALLOWED_MODELS[0]`) so a future
 * second allowlisted model doesn't silently change the default by list
 * order.
 */
export const DEFAULT_MODEL: string = "gpt-5.4-mini";

/**
 * Resolves the model this proxy actually sends to OpenAI.
 * `requestedModel` is whatever (if anything) the client's JSON body
 * contained — untrusted, and this is the only function allowed to turn
 * it into something used downstream. Only an *exact* (whitespace-trimmed,
 * case-sensitive) match against `ALLOWED_MODELS` is honored; anything
 * else — missing, unapproved, wrong case, extra whitespace, or any other
 * value/type — safely falls back to `DEFAULT_MODEL` rather than erroring
 * or guessing. Every code path returns a value drawn from
 * `ALLOWED_MODELS`; there is no path that returns the raw input.
 */
export function resolveModel(requestedModel: unknown): string {
  if (typeof requestedModel === "string") {
    const trimmed = requestedModel.trim();
    if (ALLOWED_MODELS.includes(trimmed)) {
      return trimmed;
    }
  }
  return DEFAULT_MODEL;
}

/**
 * Hard ceiling on `max_output_tokens`, independent of whatever the client
 * requests — bounds the single most expensive dimension of one OpenAI
 * call (output tokens cost more per-token than input tokens). Generous
 * relative to this app's own current client-side default
 * (`PersonalAIGenerationRequest.maxOutputTokens = 500`), but real and
 * enforced server-side regardless of what any client sends.
 */
export const MAX_OUTPUT_TOKENS = 1000;

/**
 * Resolves the `max_output_tokens` this proxy actually sends — clamps a
 * valid positive client request down to `MAX_OUTPUT_TOKENS`, and replaces
 * anything invalid (missing, non-number, non-finite, zero, negative,
 * fractional) with `MAX_OUTPUT_TOKENS` outright rather than passing it
 * through unexamined.
 */
export function resolveMaxOutputTokens(requested: unknown): number {
  if (typeof requested === "number" && Number.isFinite(requested) && requested > 0) {
    return Math.min(Math.floor(requested), MAX_OUTPUT_TOKENS);
  }
  return MAX_OUTPUT_TOKENS;
}
