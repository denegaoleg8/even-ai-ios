import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// All bindings/vars here are LOCAL-ONLY test doubles, simulated entirely by
// Miniflare (no network, no real Cloudflare resource touched). The R2/KV
// bindings come from wrangler.jsonc's declared bindings (also
// locally-simulated in this pool — the real bucket/namespace are never
// contacted by `npm test`); the plain vars below stand in for secrets that
// are never set anywhere outside a real deploy.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          ALLOW_DEV_IDENTITY: "true",
          R2_ACCESS_KEY_ID: "test-access-key-id",
          R2_SECRET_ACCESS_KEY: "test-secret-access-key",
          R2_S3_ENDPOINT: "https://test-account.r2.cloudflarestorage.com",
        },
      },
    }),
  ],
});
