import { defineConfig, devices } from "@playwright/test";
import base from "./playwright.config.js";

const productionBaseUrl =
  `http://127.0.0.1:${process.env.AVL_PLAYWRIGHT_PORT ?? "4173"}`;

export default defineConfig({
  ...base,
  timeout: 90_000,
  reporter: [["list"], ["json", {
    outputFile: "artifacts/browser/production-results.json"
  }]],
  webServer: {
    command: "node scripts/testing/serve-production-playground.mjs",
    url: productionBaseUrl,
    reuseExistingServer: false,
    timeout: 10 * 60_000
  },
  projects: [
    {
      name: "playwright-bundled-chromium-production",
      use: { ...devices["Desktop Chrome"], channel: "chromium" }
    },
    {
      name: "playwright-bundled-firefox-production",
      use: { ...devices["Desktop Firefox"] }
    },
    {
      name: "playwright-bundled-webkit-production",
      use: { ...devices["Desktop Safari"] }
    }
  ]
});
