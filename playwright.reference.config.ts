import { defineConfig, devices } from "@playwright/test";
import base from "./playwright.config.js";

export default defineConfig({
  ...base,
  reporter: [["list"], ["json", { outputFile: "artifacts/browser/reference-results.json" }]],
  projects: [
    {
      name: "playwright-chromium-reference",
      use: {
        ...devices["Desktop Chrome"],
        channel: "chromium",
        launchOptions: { ignoreDefaultArgs: ["--disable-back-forward-cache"] }
      }
    },
    { name: "playwright-firefox-reference", use: { ...devices["Desktop Firefox"] } },
    { name: "playwright-webkit-reference", use: { ...devices["Desktop Safari"] } }
  ]
});
