import { describe, expect, it } from "vitest";
import { ALLOWED_MODELS, DEFAULT_MODEL, MAX_OUTPUT_TOKENS, resolveMaxOutputTokens, resolveModel } from "../src/requestPolicy";

describe("resolveModel — server-side model policy", () => {
  it("no model provided (undefined) -> approved default used", () => {
    expect(resolveModel(undefined)).toBe(DEFAULT_MODEL);
  });

  it("an approved model is accepted as-is", () => {
    expect(resolveModel("gpt-5.4-mini")).toBe("gpt-5.4-mini");
    expect(ALLOWED_MODELS).toContain(resolveModel("gpt-5.4-mini"));
  });

  it("an unapproved/unknown model string safely maps to the default, never itself", () => {
    expect(resolveModel("gpt-5.4")).toBe(DEFAULT_MODEL);
    expect(resolveModel("gpt-5-pro")).toBe(DEFAULT_MODEL);
    expect(resolveModel("some-future-expensive-model")).toBe(DEFAULT_MODEL);
  });

  it("an expensive arbitrary string can never be returned — only ALLOWED_MODELS values ever come back", () => {
    const attempts = ["gpt-5.4", "o1-pro", "claude-opus", "../../etc/passwd", "gpt-5.4-mini; DROP TABLE", ""];
    for (const attempt of attempts) {
      expect(ALLOWED_MODELS).toContain(resolveModel(attempt));
    }
  });

  it("malformed/non-string model values fail safely to the default", () => {
    expect(resolveModel(null)).toBe(DEFAULT_MODEL);
    expect(resolveModel(123)).toBe(DEFAULT_MODEL);
    expect(resolveModel({})).toBe(DEFAULT_MODEL);
    expect(resolveModel([])).toBe(DEFAULT_MODEL);
    expect(resolveModel(true)).toBe(DEFAULT_MODEL);
  });

  it("whitespace-padding is trimmed and still matched exactly", () => {
    expect(resolveModel("  gpt-5.4-mini  ")).toBe("gpt-5.4-mini");
  });

  it("case variants do NOT bypass the allowlist — safely fall back to the default rather than loosely matching", () => {
    expect(resolveModel("GPT-5.4-MINI")).toBe(DEFAULT_MODEL);
    expect(resolveModel("Gpt-5.4-Mini")).toBe(DEFAULT_MODEL);
  });

  it("every value resolveModel can ever return is a member of ALLOWED_MODELS", () => {
    const samples = [undefined, null, "", "gpt-5.4-mini", "GPT-5.4-MINI", "gpt-4o", 42, {}];
    for (const s of samples) {
      expect(ALLOWED_MODELS).toContain(resolveModel(s));
    }
  });
});

describe("resolveMaxOutputTokens — server-side output-token cap", () => {
  it("no value provided -> the cap itself is used", () => {
    expect(resolveMaxOutputTokens(undefined)).toBe(MAX_OUTPUT_TOKENS);
  });

  it("a valid smaller request is honored", () => {
    expect(resolveMaxOutputTokens(500)).toBe(500);
  });

  it("a request above the cap is clamped down to the cap, never passed through", () => {
    expect(resolveMaxOutputTokens(100_000)).toBe(MAX_OUTPUT_TOKENS);
  });

  it("zero, negative, fractional, or non-numeric values fail safely to the cap", () => {
    expect(resolveMaxOutputTokens(0)).toBe(MAX_OUTPUT_TOKENS);
    expect(resolveMaxOutputTokens(-500)).toBe(MAX_OUTPUT_TOKENS);
    expect(resolveMaxOutputTokens(NaN)).toBe(MAX_OUTPUT_TOKENS);
    expect(resolveMaxOutputTokens("500")).toBe(MAX_OUTPUT_TOKENS);
    expect(resolveMaxOutputTokens(null)).toBe(MAX_OUTPUT_TOKENS);
  });

  it("a fractional valid value is floored", () => {
    expect(resolveMaxOutputTokens(499.9)).toBe(499);
  });
});
