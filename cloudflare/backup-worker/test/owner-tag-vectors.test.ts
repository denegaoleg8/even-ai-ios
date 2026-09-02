// CROSS-LANGUAGE OWNER-TAG PROOF (Worker side).
//
// These are the SAME fixed inputs and SAME expected hex outputs as
// EvenAITests/PersonalAICloud/R2DeploymentContractTests.swift
// (`ownerTagV1CrossLanguageVectors`). Both suites independently compute the
// tag and assert it equals the shared constant. If the Worker's
// `deriveOwnerTagV1` and the iOS `BackupOwnerTag.tag(_:)` ever diverge, one of
// these two suites fails — which is the pre-deployment gate the prior audit
// asked for.
//
// Keep OWNER_TAG_VECTORS byte-identical in both files. Non-secret fixtures.
import { describe, it, expect } from "vitest";
import { deriveOwnerTagV1, OWNER_TAG_DOMAIN_V1 } from "../src/ownerTag";

const OWNER_TAG_VECTORS: ReadonlyArray<readonly [input: string, expectedHex: string]> = [
  ["user-A", "d5f24b52433196da1ad2febc17e66dabedc36cb2ffdd9ea6cdcf3f833d1cc97a"],
  ["user-B", "1c32fe9cff154e280ea15e0c5e16c2971bc96d0ed5f11c405826936f70b919be"],
  ["dev:user-A", "07728a26cbf2f8e5f0b46fd2faf83c93c3aa1bbe74f5c5c656b00c6cf0cfca1f"],
  ["00000000-0000-0000-0000-000000000000", "ed31e07852bf2b78a069ed3e1d463cea6ef329897fc2c5df06e13c92ff01b047"],
  ["apple:001234.abcdef0123456789.4242", "d705978cd84758a519aa6be52eb077e3a4cf6eebd6420d3d6da22f454ad81e4f"],
  ["", "4d39a7717a77088a526b6705c8b6df986d4f1f39c2557bb1ddd13930bf9f09a1"],
  ["u", "0bd54f91e37a90c4d1d0392328a932f1490c03fc5d289a614591d61f0683db9e"],
  ["éè-user", "7bf412a428cb37dc7435a1e803038b84868b0f74b97c73a6ae8134e609e039c8"],
  ["a".repeat(256), "91870690d1fdab8952fe0b1214493484d3fb4f350728ff656384bd5bf2036c83"],
];

describe("ownerTag v1 — cross-language vectors", () => {
  it("the domain string is the exact shared constant", () => {
    expect(OWNER_TAG_DOMAIN_V1).toBe("evenai.personal-ai.backup.owner-tag.v1");
  });

  for (const [input, expected] of OWNER_TAG_VECTORS) {
    it(`deriveOwnerTagV1(${JSON.stringify(input.length > 32 ? input.slice(0, 16) + "…" : input)}) === shared vector`, async () => {
      expect(await deriveOwnerTagV1(input)).toBe(expected);
    });
  }

  it("is 64 lowercase hex chars and injective across the sample", async () => {
    const seen = new Set<string>();
    for (const [input] of OWNER_TAG_VECTORS) {
      const tag = await deriveOwnerTagV1(input);
      expect(tag).toMatch(/^[0-9a-f]{64}$/);
      seen.add(tag);
    }
    expect(seen.size).toBe(OWNER_TAG_VECTORS.length);
  });
});
