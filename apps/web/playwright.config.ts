import { defineConfig } from "@playwright/test";

// Jalankan di: ROOT/apps/web  ->  pnpm build && pnpm test:e2e
export default defineConfig({
  testDir: "tests/e2e",
  timeout: 60_000,
  use: { baseURL: "http://127.0.0.1:3100", channel: "chrome", viewport: { width: 1440, height: 900 } },
  webServer: { command: "pnpm start -p 3100", url: "http://127.0.0.1:3100", reuseExistingServer: true, timeout: 120_000 },
});
