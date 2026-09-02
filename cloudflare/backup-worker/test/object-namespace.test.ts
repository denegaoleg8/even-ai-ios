// CROSS-LANGUAGE NAMESPACE PROOF (Worker side).
//
// These pin the exact key shapes the Worker's `keyIsInOwnerNamespace` must
// accept / reject, mirroring the Swift `BackupObjectNamespace` +
// `BackupAuthorizationScope.keyIsInOwnerNamespace` and their tests
// (BackupObjectNamespaceTests.swift). If the versioned-namespace handling
// drifts between the two implementations, one side fails.
import { describe, it, expect } from "vitest";
import {
  keyIsInOwnerNamespace,
  keyIsWellFormed,
  strippingRecognisedVersionPrefix,
  RECOGNISED_NAMESPACE_VERSIONS,
  CURRENT_NAMESPACE_VERSION,
} from "../src/scope";

const TAG_A = "a".repeat(64);
const TAG_B = "b".repeat(64);
const BACKUP_ID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";

describe("versioned object namespace", () => {
  it("recognises exactly version 1 today", () => {
    expect(CURRENT_NAMESPACE_VERSION).toBe(1);
    expect([...RECOGNISED_NAMESPACE_VERSIONS]).toEqual([1]);
  });

  it("accepts a canonical v1 catalog and object key for the owner", () => {
    expect(keyIsInOwnerNamespace(`backup/v1/${TAG_A}/catalog.json`, TAG_A)).toBe(true);
    expect(keyIsInOwnerNamespace(`backup/v1/${TAG_A}/objects/7-daily-${BACKUP_ID}.eapb`, TAG_A)).toBe(true);
  });

  it("still accepts a bare (pre-v1, test-only) key for the owner", () => {
    expect(keyIsInOwnerNamespace(`${TAG_A}/catalog.json`, TAG_A)).toBe(true);
  });

  it("rejects a v1 key under a different owner", () => {
    expect(keyIsInOwnerNamespace(`backup/v1/${TAG_B}/catalog.json`, TAG_A)).toBe(false);
  });

  it("an UNKNOWN version fails safely — the prefix is not stripped, so it can't match the owner", () => {
    for (const key of [
      `backup/v2/${TAG_A}/catalog.json`,
      `backup/v99/${TAG_A}/objects/1-daily-${BACKUP_ID}.eapb`,
      `backup/vx/${TAG_A}/catalog.json`,
    ]) {
      expect(strippingRecognisedVersionPrefix(key)).toBe(key); // unchanged
      expect(keyIsInOwnerNamespace(key, TAG_A)).toBe(false);
    }
  });

  it("strips only a recognised version prefix", () => {
    expect(strippingRecognisedVersionPrefix(`backup/v1/${TAG_A}/catalog.json`)).toBe(`${TAG_A}/catalog.json`);
    expect(strippingRecognisedVersionPrefix(`${TAG_A}/catalog.json`)).toBe(`${TAG_A}/catalog.json`);
    expect(strippingRecognisedVersionPrefix(`backup/v2/${TAG_A}/x`)).toBe(`backup/v2/${TAG_A}/x`);
  });

  it("rejects traversal even inside a valid version prefix", () => {
    expect(keyIsWellFormed(`backup/v1/${TAG_A}/../${TAG_B}/catalog.json`)).toBe(false);
    expect(keyIsInOwnerNamespace(`backup/v1/${TAG_A}/../${TAG_B}/x`, TAG_A)).toBe(false);
    expect(keyIsInOwnerNamespace(`backup/v1/${TAG_A}//objects/x`, TAG_A)).toBe(false);
    expect(keyIsInOwnerNamespace(`/backup/v1/${TAG_A}/x`, TAG_A)).toBe(false);
  });
});
