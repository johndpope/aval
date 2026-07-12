import { fileURLToPath } from "node:url";

import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["packages/**/*.test.ts", "apps/**/*.test.ts", "tests/**/*.test.ts"],
    exclude: ["**/node_modules/**", "**/dist/**"],
    pool: "threads",
    maxWorkers: 1,
    testTimeout: 30_000
  },
  resolve: {
    // Match the workspace suite's single source-module identity. Packed and
    // registry consumer tests address built artifacts by explicit file path.
    alias: {
      "@rendered-motion/compiler": fileURLToPath(
        new URL("./packages/compiler/src/index.ts", import.meta.url)
      ),
      "@rendered-motion/format": fileURLToPath(
        new URL("./packages/format/src/index.ts", import.meta.url)
      ),
      "@rendered-motion/graph": fileURLToPath(
        new URL("./packages/graph/src/index.ts", import.meta.url)
      ),
      "@rendered-motion/player-web": fileURLToPath(
        new URL("./packages/player-web/src/index.ts", import.meta.url)
      ),
      "@rendered-motion/element/auto": fileURLToPath(
        new URL("./packages/element/src/auto.ts", import.meta.url)
      ),
      "@rendered-motion/element": fileURLToPath(
        new URL("./packages/element/src/index.ts", import.meta.url)
      )
    }
  }
});
