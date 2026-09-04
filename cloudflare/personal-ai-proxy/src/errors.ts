import type { ProviderNeutralError, ProviderNeutralErrorCategory } from "./types";

/**
 * Maps a provider-neutral error category to the HTTP status this proxy
 * returns to the app — mirrors exactly what iOS's `OpenAIResponsesTransport`
 * already classifies on receipt: 401 → `.unavailable`, 503 → `.transientFailure`
 * (429/5xx/timeout), 422 → `.hardFailure`, 400 → `.unsupported`.
 */
export function statusForCategory(category: ProviderNeutralErrorCategory): number {
  switch (category) {
    case "unavailable":
      return 401;
    case "transientFailure":
      return 503;
    case "hardFailure":
      return 422;
    case "unsupported":
      return 400;
  }
}

/** Never includes the request/response body — only the category and a
 * short, app-authored (or OpenAI status-code-derived) reason string. */
export function errorResponse(err: ProviderNeutralError): Response {
  return new Response(
    JSON.stringify({ error: { category: err.category, message: err.reason } }),
    { status: statusForCategory(err.category), headers: { "content-type": "application/json" } }
  );
}

/**
 * Maps an upstream OpenAI HTTP status to a provider-neutral category —
 * an OpenAI-specific status code never reaches the app unmapped.
 */
export function categorizeOpenAIStatus(status: number): ProviderNeutralErrorCategory {
  if (status === 401 || status === 403) return "unavailable"; // OpenAI rejected the key — a proxy configuration problem, not the app's fault
  if (status === 429) return "transientFailure";
  if (status >= 500) return "transientFailure";
  return "hardFailure";
}
