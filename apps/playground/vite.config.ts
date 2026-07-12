import { fileURLToPath } from "node:url";

import { defineConfig } from "vite";

import { createPlaygroundConfig } from "./vite.shared.js";

export default defineConfig({
  ...createPlaygroundConfig(),
  resolve: {
    // The local playground exercises workspace sources without a prior build.
    alias: {
      "@rendered-motion/format": fileURLToPath(
        new URL("../../packages/format/src/index.ts", import.meta.url)
      ),
      "@rendered-motion/graph": fileURLToPath(
        new URL("../../packages/graph/src/index.ts", import.meta.url)
      ),
      "@rendered-motion/player-web": fileURLToPath(
        new URL("../../packages/player-web/src/index.ts", import.meta.url)
      ),
      "@rendered-motion/element/auto": fileURLToPath(
        new URL("../../packages/element/src/auto.ts", import.meta.url)
      ),
      "@rendered-motion/element": fileURLToPath(
        new URL("../../packages/element/src/index.ts", import.meta.url)
      )
    }
  }
});
