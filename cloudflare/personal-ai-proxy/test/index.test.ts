import { describe, expect, it, vi } from "vitest";
import { handle } from "../src/index";
import type { Env } from "../src/types";

const env: Env = { OPENAI_API_KEY: "sk-test-fake-key-do-not-use", APP_PROXY_SHARED_SECRET: "dev-secret" };

function req(body: unknown, opts: { path?: string; method?: string; auth?: string } = {}): Request {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (opts.auth !== undefined) headers["authorization"] = opts.auth;
  else headers["authorization"] = "Bearer dev-secret";
  const method = opts.method ?? "POST";
  const canHaveBody = method !== "GET" && method !== "HEAD";
  return new Request(`https://proxy.example.invalid${opts.path ?? "/personal-ai/generate"}`, {
    method,
    headers,
    ...(canHaveBody ? { body: typeof body === "string" ? body : JSON.stringify(body) } : {})
  });
}

const validBody = { model: "gpt-5.4-mini", input: [{ role: "user", content: "hi" }] };

function fakeOpenAISuccess(text = "hello back") {
  return vi.fn(async () =>
    new Response(
      JSON.stringify({ output: [{ type: "message", content: [{ type: "output_text", text }] }] }),
      { status: 200 }
    )
  );
}

describe("POST /personal-ai/generate — thin proxy contract", () => {
  it("404s on any other path or method", async () => {
    const res1 = await handle(req(validBody, { path: "/something-else" }), env, fakeOpenAISuccess() as unknown as typeof fetch);
    expect(res1.status).toBe(404);
    const res2 = await handle(req(validBody, { method: "GET" }), env, fakeOpenAISuccess() as unknown as typeof fetch);
    expect(res2.status).toBe(404);
  });

  it("rejects (fails closed) with no app credential and never calls OpenAI", async () => {
    const openai = fakeOpenAISuccess();
    const res = await handle(req(validBody, { auth: "Bearer wrong" }), env, openai as unknown as typeof fetch);
    expect(res.status).toBe(401);
    expect(openai).not.toHaveBeenCalled();
  });

  it("rejects when APP_PROXY_SHARED_SECRET itself is unset, even with a bearer header", async () => {
    const unconfigured: Env = { OPENAI_API_KEY: "sk-test" };
    const openai = fakeOpenAISuccess();
    const res = await handle(req(validBody), unconfigured, openai as unknown as typeof fetch);
    expect(res.status).toBe(401);
    expect(openai).not.toHaveBeenCalled();
  });

  it("rejects an oversized request and never calls OpenAI", async () => {
    const openai = fakeOpenAISuccess();
    const huge = { model: "gpt-5.4-mini", input: [{ role: "user", content: "x".repeat(64 * 1024) }] };
    const res = await handle(req(huge), env, openai as unknown as typeof fetch);
    expect(res.status).toBe(422);
    expect(openai).not.toHaveBeenCalled();
  });

  it("rejects malformed JSON", async () => {
    const res = await handle(req("not json {{{"), env, fakeOpenAISuccess() as unknown as typeof fetch);
    expect(res.status).toBe(422);
  });

  it("rejects a body missing required fields", async () => {
    const res = await handle(req({ foo: "bar" }), env, fakeOpenAISuccess() as unknown as typeof fetch);
    expect(res.status).toBe(422);
  });

  it("forwards a valid request to OpenAI with the key attached, and relays the 200 response as-is", async () => {
    const openai = fakeOpenAISuccess("the actual reply");
    const res = await handle(req(validBody), env, openai as unknown as typeof fetch);
    expect(res.status).toBe(200);
    expect(openai).toHaveBeenCalledOnce();
    const returnedJson = await res.json();
    expect(JSON.stringify(returnedJson)).toContain("the actual reply");
    // the key never appears anywhere in what comes back to the app
    expect(JSON.stringify(returnedJson)).not.toContain("sk-test-fake-key-do-not-use");
  });

  it("maps an OpenAI 429 to the provider-neutral 503 category, without leaking the raw upstream body", async () => {
    const openai = vi.fn(async () => new Response(JSON.stringify({ error: { message: "rate limited" } }), { status: 429 }));
    const res = await handle(req(validBody), env, openai as unknown as typeof fetch);
    expect(res.status).toBe(503);
    const json = await res.json();
    expect(json).toMatchObject({ error: { category: "transientFailure" } });
  });

  it("maps an OpenAI 500 to transientFailure (503)", async () => {
    const openai = vi.fn(async () => new Response("internal error", { status: 500 }));
    const res = await handle(req(validBody), env, openai as unknown as typeof fetch);
    expect(res.status).toBe(503);
  });

  it("maps an OpenAI 401 (bad server-side key) to unavailable — a proxy config problem, distinct from the app's own auth 401", async () => {
    const openai = vi.fn(async () => new Response("unauthorized", { status: 401 }));
    const res = await handle(req(validBody), env, openai as unknown as typeof fetch);
    expect(res.status).toBe(401);
    const json = await res.json();
    expect(json).toMatchObject({ error: { category: "unavailable" } });
  });

  it("rejects an oversized upstream response rather than relaying it", async () => {
    const openai = vi.fn(async () => new Response("x".repeat(300 * 1024), { status: 200 }));
    const res = await handle(req(validBody), env, openai as unknown as typeof fetch);
    expect(res.status).toBe(422);
  });

  it("never logs prompt, context, or credential content — only method/path/status/size", async () => {
    const distinctivePrompt = "ZebraQuokkaMarmoset the user's private context";
    const bodyWithContext = {
      model: "gpt-5.4-mini",
      instructions: distinctivePrompt,
      input: [{ role: "user", content: "a private question" }]
    };
    const logs: string[] = [];
    const spy = vi.spyOn(console, "log").mockImplementation((msg: unknown) => { logs.push(String(msg)); });
    try {
      await handle(req(bodyWithContext), env, fakeOpenAISuccess("some reply naming nothing sensitive") as unknown as typeof fetch);
    } finally {
      spy.mockRestore();
    }
    const joined = logs.join("\n");
    expect(joined).not.toContain(distinctivePrompt);
    expect(joined).not.toContain("a private question");
    expect(joined).not.toContain("sk-test-fake-key-do-not-use");
    expect(joined).not.toContain("dev-secret");
  });
});

describe("POST /personal-ai/generate — server-side model/output-cap policy applied to the outbound OpenAI request", () => {
  function capturingOpenAI(text = "ok") {
    const calls: RequestInit[] = [];
    const fn = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      calls.push(init ?? {});
      return new Response(
        JSON.stringify({ output: [{ type: "message", content: [{ type: "output_text", text }] }] }),
        { status: 200 }
      );
    });
    return { fn, calls };
  }

  it("no model in the client body -> the outbound OpenAI request uses the approved default", async () => {
    const { fn, calls } = capturingOpenAI();
    const body = { input: [{ role: "user", content: "hi" }] }; // no `model` at all
    const res = await handle(req(body), env, fn as unknown as typeof fetch);
    expect(res.status).toBe(200);
    const sent = JSON.parse(String(calls[0]?.body ?? "{}"));
    expect(sent.model).toBe("gpt-5.4-mini");
  });

  it("an unapproved/expensive model string in the client body never reaches the outbound OpenAI request", async () => {
    const { fn, calls } = capturingOpenAI();
    const body = { model: "gpt-5.4-EXPENSIVE-UNAPPROVED", input: [{ role: "user", content: "hi" }] };
    const res = await handle(req(body), env, fn as unknown as typeof fetch);
    expect(res.status).toBe(200);
    const sentBody = String(calls[0]?.body ?? "");
    expect(sentBody).not.toContain("EXPENSIVE-UNAPPROVED");
    const sent = JSON.parse(sentBody);
    expect(sent.model).toBe("gpt-5.4-mini");
  });

  it("the approved model, explicitly sent, is honored as-is in the outbound request", async () => {
    const { fn, calls } = capturingOpenAI();
    const res = await handle(req(validBody), env, fn as unknown as typeof fetch);
    expect(res.status).toBe(200);
    const sent = JSON.parse(String(calls[0]?.body ?? "{}"));
    expect(sent.model).toBe("gpt-5.4-mini");
  });

  it("a huge client-requested max_output_tokens is clamped in the outbound OpenAI request, never passed through", async () => {
    const { fn, calls } = capturingOpenAI();
    const body = { model: "gpt-5.4-mini", max_output_tokens: 1_000_000, input: [{ role: "user", content: "hi" }] };
    const res = await handle(req(body), env, fn as unknown as typeof fetch);
    expect(res.status).toBe(200);
    const sent = JSON.parse(String(calls[0]?.body ?? "{}"));
    expect(sent.max_output_tokens).toBeLessThanOrEqual(1000);
    expect(sent.max_output_tokens).not.toBe(1_000_000);
  });

  it("instructions and input pass through to the outbound request unchanged — only model/max_output_tokens are policy-controlled", async () => {
    const { fn, calls } = capturingOpenAI();
    const body = { model: "gpt-5.4-mini", instructions: "known facts block", input: [{ role: "user", content: "the question" }] };
    await handle(req(body), env, fn as unknown as typeof fetch);
    const sent = JSON.parse(String(calls[0]?.body ?? "{}"));
    expect(sent.instructions).toBe("known facts block");
    expect(sent.input).toEqual([{ role: "user", content: "the question" }]);
  });
});
