import { describe, expect, it, vi } from "vitest";
import { callOpenAI, OPENAI_RESPONSES_URL } from "../src/openai";
import type { Env } from "../src/types";

const env: Env = { OPENAI_API_KEY: "sk-test-fake-key-do-not-use" };

describe("callOpenAI (never a real network call — fetchImpl is always fake here)", () => {
  it("calls exactly the Responses API URL with the key attached as Bearer auth", async () => {
    const fakeFetch = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      expect(url).toBe(OPENAI_RESPONSES_URL);
      const headers = new Headers(init?.headers);
      expect(headers.get("authorization")).toBe("Bearer sk-test-fake-key-do-not-use");
      return new Response(JSON.stringify({ output: [] }), { status: 200 });
    });

    const result = await callOpenAI('{"model":"gpt-5.4-mini","input":[]}', env, fakeFetch as unknown as typeof fetch);
    expect(result.status).toBe(200);
    expect(fakeFetch).toHaveBeenCalledOnce();
  });

  it("the returned result never contains the API key", async () => {
    const fakeFetch = vi.fn(async () => new Response(JSON.stringify({ output: [] }), { status: 200 }));
    const result = await callOpenAI("{}", env, fakeFetch as unknown as typeof fetch);
    expect(result.body).not.toContain("sk-test-fake-key-do-not-use");
    expect(JSON.stringify(result)).not.toContain("sk-test-fake-key-do-not-use");
  });

  it("aborts and throws AbortError when the call exceeds the configured timeout", async () => {
    const fakeFetch = vi.fn((_url: string | URL | Request, init?: RequestInit) => {
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          const err = new Error("aborted");
          err.name = "AbortError";
          reject(err);
        });
      });
    });

    await expect(
      callOpenAI("{}", env, fakeFetch as unknown as typeof fetch, 20)
    ).rejects.toMatchObject({ name: "AbortError" });
  });

  it("forwards the exact request body bytes given, unmodified", async () => {
    const body = '{"model":"gpt-5.4-mini","instructions":"ctx","input":[{"role":"user","content":"hi"}]}';
    const fakeFetch = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      expect(init?.body).toBe(body);
      return new Response("{}", { status: 200 });
    });
    await callOpenAI(body, env, fakeFetch as unknown as typeof fetch);
  });
});
