// Direct unit coverage of the key-validity primitive, mirroring
// EvenAITests/PersonalAICloud/R2ProductionPathSecurityTests.swift's
// malformedKeysRejected test case-for-case, so drift between the Swift and
// TS copies of this rule is caught here rather than only in production.
import { describe, it, expect } from "vitest";
import { keyIsWellFormed, keyIsInOwnerNamespace } from "../src/scope";

const tagA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const tagB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const CONTROL_CHAR = String.fromCharCode(7); // BEL, mirrors Swift's \u{0007}

describe("keyIsWellFormed", () => {
  it("rejects empty, doubled-separator, leading-slash, trailing-slash, over-long, and dot-segment keys", () => {
    expect(keyIsWellFormed("")).toBe(false);
    expect(keyIsWellFormed(`${tagA}//objects/x`)).toBe(false);
    expect(keyIsWellFormed(`/${tagA}/objects/x`)).toBe(false);
    expect(keyIsWellFormed(`${tagA}/objects/x/`)).toBe(false);
    expect(keyIsWellFormed("a".repeat(513))).toBe(false);
    expect(keyIsWellFormed(`${tagA}/./x`)).toBe(false);
    expect(keyIsWellFormed(`${tagA}/../${tagB}/x`)).toBe(false);
  });

  it("rejects a key containing an ASCII control character", () => {
    expect(keyIsWellFormed(`${tagA}/objects/${CONTROL_CHAR}x`)).toBe(false);
  });

  it("accepts real, machine-generated keys", () => {
    expect(keyIsWellFormed(`${tagA}/objects/7-daily-${crypto.randomUUID()}.eapb`)).toBe(true);
    expect(keyIsWellFormed(`${tagA}/catalog.json`)).toBe(true);
    expect(keyIsWellFormed(tagA)).toBe(true);
  });
});

describe("keyIsInOwnerNamespace", () => {
  it("accepts a key at or under the owner's own prefix", () => {
    expect(keyIsInOwnerNamespace(tagA, tagA)).toBe(true);
    expect(keyIsInOwnerNamespace(`${tagA}/catalog.json`, tagA)).toBe(true);
  });

  it("rejects a key under a different owner's prefix", () => {
    expect(keyIsInOwnerNamespace(`${tagB}/catalog.json`, tagA)).toBe(false);
  });

  it("rejects traversal even when the final resolved path would land back in-namespace", () => {
    expect(keyIsInOwnerNamespace(`${tagA}/objects/../../${tagA}/catalog.json`, tagA)).toBe(false);
  });
});
