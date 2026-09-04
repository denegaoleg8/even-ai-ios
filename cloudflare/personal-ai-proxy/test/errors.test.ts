import { describe, expect, it } from "vitest";
import { categorizeOpenAIStatus, errorResponse, statusForCategory } from "../src/errors";

describe("provider-neutral error category <-> HTTP status", () => {
  it("maps every category to a stable status", () => {
    expect(statusForCategory("unavailable")).toBe(401);
    expect(statusForCategory("transientFailure")).toBe(503);
    expect(statusForCategory("hardFailure")).toBe(422);
    expect(statusForCategory("unsupported")).toBe(400);
  });

  it("categorizes OpenAI's own status codes without leaking them raw", async () => {
    expect(categorizeOpenAIStatus(401)).toBe("unavailable");
    expect(categorizeOpenAIStatus(403)).toBe("unavailable");
    expect(categorizeOpenAIStatus(429)).toBe("transientFailure");
    expect(categorizeOpenAIStatus(500)).toBe("transientFailure");
    expect(categorizeOpenAIStatus(503)).toBe("transientFailure");
    expect(categorizeOpenAIStatus(400)).toBe("hardFailure");
  });

  it("errorResponse never includes a request/response body, only category + reason", async () => {
    const res = errorResponse({ category: "transientFailure", reason: "upstream status 500" });
    expect(res.status).toBe(503);
    const json = await res.json();
    expect(json).toEqual({ error: { category: "transientFailure", message: "upstream status 500" } });
  });
});
