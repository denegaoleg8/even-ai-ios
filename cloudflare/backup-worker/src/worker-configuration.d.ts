// Augments the ambient `Cloudflare.Env` namespace (consumed by `cloudflare:test`'s
// `env` export) with this Worker's actual Env shape, so `env.R2_S3_ENDPOINT`
// etc. type-check in tests without duplicating the interface.
import type { Env as WorkerEnv } from "./types";

declare global {
  namespace Cloudflare {
    // eslint-disable-next-line @typescript-eslint/no-empty-object-type
    interface Env extends WorkerEnv {}
  }
}

export {};
