import { describe, expect, it } from "vitest";
import { isAuthorized } from "../src/auth";
import type { Env } from "../src/types";

function req(authHeader?: string): Request {
  const headers: Record<string, string> = {};
  if (authHeader !== undefined) headers["authorization"] = authHeader;
  return new Request("https://proxy.example.invalid/personal-ai/generate", { method: "POST", headers });
}

describe("app -> proxy authorization (fails closed)", () => {
  it("rejects when APP_PROXY_SHARED_SECRET is not configured, even with a bearer token", () => {
    const env: Env = { OPENAI_API_KEY: "unused-in-this-test" };
    expect(isAuthorized(req("Bearer anything"), env)).toBe(false);
  });

  it("rejects a missing Authorization header", () => {
    const env: Env = { OPENAI_API_KEY: "unused", APP_PROXY_SHARED_SECRET: "dev-secret" };
    expect(isAuthorized(req(undefined), env)).toBe(false);
  });

  it("rejects a non-Bearer scheme", () => {
    const env: Env = { OPENAI_API_KEY: "unused", APP_PROXY_SHARED_SECRET: "dev-secret" };
    expect(isAuthorized(req("Basic dev-secret"), env)).toBe(false);
  });

  it("rejects a mismatched token", () => {
    const env: Env = { OPENAI_API_KEY: "unused", APP_PROXY_SHARED_SECRET: "dev-secret" };
    expect(isAuthorized(req("Bearer wrong-token"), env)).toBe(false);
  });

  it("accepts an exact matching bearer token", () => {
    const env: Env = { OPENAI_API_KEY: "unused", APP_PROXY_SHARED_SECRET: "dev-secret" };
    expect(isAuthorized(req("Bearer dev-secret"), env)).toBe(true);
  });
});
