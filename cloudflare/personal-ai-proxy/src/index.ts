import type { Env, OpenAIResponsesRequestBody } from "./types";
import { isAuthorized } from "./auth";
import { callOpenAI } from "./openai";
import { categorizeOpenAIStatus, errorResponse, statusForCategory } from "./errors";
import { resolveMaxOutputTokens, resolveModel } from "./requestPolicy";

/**
 * `POST /personal-ai/generate` — the app-facing, provider-neutral (in
 * name and error shape) endpoint. Deliberately "thin": it authenticates
 * the app, validates size limits, forwards the OpenAI-shaped body (built
 * by iOS's `OpenAIResponsesTransport`) to OpenAI with the real key
 * attached server-side only, and maps errors. It is *not* a raw
 * pass-through for `model`/`max_output_tokens`: those two fields are
 * always resolved server-side via `src/requestPolicy.ts` and the outbound
 * body is rebuilt from the resolved values — the client cannot select an
 * arbitrary vendor model or an unbounded output-token cap. Everything
 * else in the payload passes through unreshaped. **Never deployed from
 * this codebase** — `wrangler deploy` has not been run; all tests use a
 * fake `fetchImpl`.
 */

const MAX_REQUEST_BYTES = 32 * 1024; // generous for a chat turn + rendered context; far below a memory dump
const MAX_RESPONSE_BYTES = 256 * 1024;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, fetch);
  }
};

/**
 * Exported separately from the default `fetch` so tests can supply a fake
 * `fetchImpl` without needing a real Workers runtime or network access.
 */
export async function handle(request: Request, env: Env, fetchImpl: typeof fetch): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== "POST" || url.pathname !== "/personal-ai/generate") {
    return new Response("not found", { status: 404 });
  }

  if (!isAuthorized(request, env)) {
    // Fails closed: unconfigured or wrong app credential never reaches
    // OpenAI. This is the app→proxy trust boundary — entirely separate
    // from `OPENAI_API_KEY` (proxy→OpenAI), checked next only if this
    // passes.
    return errorResponse({ category: "unavailable", reason: "app authorization rejected or not configured" });
  }

  const bodyText = await request.text();
  if (byteLength(bodyText) > MAX_REQUEST_BYTES) {
    return errorResponse({ category: "hardFailure", reason: "request too large" });
  }

  let parsed: OpenAIResponsesRequestBody;
  try {
    parsed = JSON.parse(bodyText) as OpenAIResponsesRequestBody;
  } catch {
    return errorResponse({ category: "hardFailure", reason: "malformed request body" });
  }
  if (!Array.isArray(parsed.input)) {
    return errorResponse({ category: "hardFailure", reason: "malformed request body" });
  }

  // Server-side request policy applied here, and only here — see
  // src/requestPolicy.ts. `parsed.model`/`parsed.max_output_tokens`
  // (whatever, if anything, the client sent) are read exactly once, by
  // `resolveModel`/`resolveMaxOutputTokens`, and never appear in the
  // outbound body except as their resolved, policy-approved values.
  const outboundBody = buildOutboundBody(parsed);

  const startedAt = Date.now();
  let result;
  try {
    result = await callOpenAI(outboundBody, env, fetchImpl);
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") {
      logSafely(request, statusForCategory("transientFailure"), startedAt, bodyText.length, 0);
      return errorResponse({ category: "transientFailure", reason: "upstream timeout" });
    }
    logSafely(request, statusForCategory("transientFailure"), startedAt, bodyText.length, 0);
    return errorResponse({ category: "transientFailure", reason: "upstream network error" });
  }

  if (byteLength(result.body) > MAX_RESPONSE_BYTES) {
    logSafely(request, statusForCategory("hardFailure"), startedAt, bodyText.length, result.body.length);
    return errorResponse({ category: "hardFailure", reason: "upstream response too large" });
  }

  logSafely(request, result.status, startedAt, bodyText.length, result.body.length);

  if (result.status >= 200 && result.status < 300) {
    return new Response(result.body, { status: 200, headers: { "content-type": "application/json" } });
  }
  return errorResponse({ category: categorizeOpenAIStatus(result.status), reason: `upstream status ${result.status}` });
}

function byteLength(s: string): number {
  return new TextEncoder().encode(s).length;
}

/**
 * The one place the outbound OpenAI request body is assembled — a
 * code-level guard against ever accidentally forwarding the client's raw
 * `model`/`max_output_tokens`. `model` and `max_output_tokens` are
 * destructured out of `parsed` and discarded (`_clientModel`,
 * `_clientMaxOutputTokens` are intentionally unused); `...rest` therefore
 * cannot carry either through even if this function is edited later,
 * and the two fields are re-added immediately after, exclusively from
 * `resolveModel`/`resolveMaxOutputTokens`. `instructions`/`input` (and
 * any other field the client sent) pass through in `rest` unchanged —
 * this proxy stays a thin relay for everything except the two fields
 * server policy owns.
 */
function buildOutboundBody(parsed: OpenAIResponsesRequestBody): string {
  const { model: _clientModel, max_output_tokens: _clientMaxOutputTokens, ...rest } = parsed;
  return JSON.stringify({
    ...rest,
    model: resolveModel(parsed.model),
    max_output_tokens: resolveMaxOutputTokens(parsed.max_output_tokens)
  });
}

/**
 * Safe logging only: method, path, status, duration, byte counts. Never
 * `bodyText`, never `result.body`, never a header value — no prompt, no
 * Personal AI context, no credential, ever logged by this function.
 */
function logSafely(request: Request, status: number, startedAt: number, requestBytes: number, responseBytes: number): void {
  console.log(JSON.stringify({
    event: "PERSONAL_AI_PROXY_REQUEST",
    method: request.method,
    path: new URL(request.url).pathname,
    status,
    durationMs: Date.now() - startedAt,
    requestBytes,
    responseBytes
  }));
}
