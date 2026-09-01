// Generates an R2 (S3-compatible) presigned URL. This is pure local
// computation via AWS SigV4 signing (aws4fetch) — no network call is made to
// mint the URL. See types.ts's Env doc comment for why an R2 API token
// (Access Key ID / Secret Access Key), not the Worker's R2 binding, is what
// this operation fundamentally requires: a binding only grants this Worker's
// own request-handler code direct object access, it cannot mint a URL an
// external client can use.
import { AwsClient } from "aws4fetch";
import type { BackupObjectOperation } from "./types";

const METHOD_FOR_OPERATION: Record<BackupObjectOperation, string> = {
  put: "PUT",
  get: "GET",
  delete: "DELETE",
  head: "HEAD",
  list: "GET",
};

export interface PresignInput {
  accessKeyId: string;
  secretAccessKey: string;
  /** e.g. https://<account-id>.r2.cloudflarestorage.com */
  s3Endpoint: string;
  bucket: string;
  objectKey: string;
  operation: BackupObjectOperation;
  expiresInSeconds: number;
}

export async function presignR2Url(input: PresignInput): Promise<string> {
  const client = new AwsClient({
    accessKeyId: input.accessKeyId,
    secretAccessKey: input.secretAccessKey,
    service: "s3",
    // R2's S3-compatible endpoint doesn't use AWS regions; "auto" is R2's
    // documented convention for SigV4 signing against it.
    region: "auto",
  });

  const url = new URL(`${input.s3Endpoint.replace(/\/+$/, "")}/${input.bucket}/${encodeKeyPath(input.objectKey)}`);
  url.searchParams.set("X-Amz-Expires", String(input.expiresInSeconds));

  const signed = await client.sign(url.toString(), {
    method: METHOD_FOR_OPERATION[input.operation],
    aws: { signQuery: true },
  });

  return signed.url;
}

function encodeKeyPath(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}
