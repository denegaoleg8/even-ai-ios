// Unit-tests presignR2Url in isolation: pure local SigV4 computation via
// aws4fetch, fake test credentials, zero network calls (sign() with
// signQuery never contacts R2 — see src/presign.ts's doc comment).
import { describe, it, expect } from "vitest";
import { presignR2Url } from "../src/presign";

describe("presignR2Url", () => {
  it("produces a well-formed SigV4 query-signed URL for the requested bucket/key/method", async () => {
    const url = await presignR2Url({
      accessKeyId: "test-access-key-id",
      secretAccessKey: "test-secret-access-key",
      s3Endpoint: "https://test-account.r2.cloudflarestorage.com",
      bucket: "evenai-personal-ai-backups",
      objectKey: "abc123/objects/1-daily-x.eapb",
      operation: "put",
      expiresInSeconds: 300,
    });

    const parsed = new URL(url);
    expect(parsed.hostname).toBe("test-account.r2.cloudflarestorage.com");
    expect(parsed.pathname).toBe("/evenai-personal-ai-backups/abc123/objects/1-daily-x.eapb");
    expect(parsed.searchParams.get("X-Amz-Algorithm")).toBe("AWS4-HMAC-SHA256");
    expect(parsed.searchParams.has("X-Amz-Credential")).toBe(true);
    expect(parsed.searchParams.has("X-Amz-Signature")).toBe(true);
    expect(parsed.searchParams.get("X-Amz-Expires")).toBe("300");
  });

  it("percent-encodes each path segment of the object key independently", async () => {
    const url = await presignR2Url({
      accessKeyId: "test-access-key-id",
      secretAccessKey: "test-secret-access-key",
      s3Endpoint: "https://test-account.r2.cloudflarestorage.com",
      bucket: "evenai-personal-ai-backups",
      objectKey: "tag/objects/has space.eapb",
      operation: "get",
      expiresInSeconds: 60,
    });
    expect(new URL(url).pathname).toBe("/evenai-personal-ai-backups/tag/objects/has%20space.eapb");
  });

  it("distinct operations produce distinct signatures for the same key", async () => {
    const base = {
      accessKeyId: "test-access-key-id",
      secretAccessKey: "test-secret-access-key",
      s3Endpoint: "https://test-account.r2.cloudflarestorage.com",
      bucket: "evenai-personal-ai-backups",
      objectKey: "abc123/catalog.json",
      expiresInSeconds: 300,
    } as const;
    const putUrl = await presignR2Url({ ...base, operation: "put" });
    const getUrl = await presignR2Url({ ...base, operation: "get" });
    expect(new URL(putUrl).searchParams.get("X-Amz-Signature")).not.toBe(
      new URL(getUrl).searchParams.get("X-Amz-Signature")
    );
  });
});
