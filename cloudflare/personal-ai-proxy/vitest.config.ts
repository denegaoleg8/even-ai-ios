import { defineConfig } from "vitest/config";

// Plain Node-based vitest — this Worker has no R2/KV/DO bindings to
// simulate (unlike ../backup-worker, which needs the Workers runtime
// pool for that), so its `fetch(request, env)` handler and pure helper
// functions are tested directly, with a fake `fetch` standing in for the
// network. No real network call, no Cloudflare account, nothing deployed.
export default defineConfig({
  test: {
    environment: "node"
  }
});
