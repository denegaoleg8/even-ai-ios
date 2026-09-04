import type { Env } from "./types";

export const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";

export interface OpenAICallResult {
  status: number;
  body: string;
}

/**
 * The only function in this codebase that reads `env.OPENAI_API_KEY` — it
 * attaches the key to the outbound request and nowhere else; the key
 * never appears in this function's return value, in a log line, or in
 * anything that reaches the app. `fetchImpl` is injected so tests never
 * perform a real network call (production passes the Worker's global
 * `fetch`). Enforces a timeout via `AbortController`, converting a
 * timeout into a distinct `AbortError` the caller maps to
 * `.transientFailure`.
 */
export async function callOpenAI(
  body: string,
  env: Env,
  fetchImpl: typeof fetch,
  timeoutMs: number = 20_000
): Promise<OpenAICallResult> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(OPENAI_RESPONSES_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${env.OPENAI_API_KEY}`
      },
      body,
      signal: controller.signal
    });
    const text = await response.text();
    return { status: response.status, body: text };
  } finally {
    clearTimeout(timeout);
  }
}
