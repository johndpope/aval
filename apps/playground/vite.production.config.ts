import { defineConfig } from "vite";

import { productionPublicEntriesPlugin } from "./vite.production-entries.js";
import { createPlaygroundConfig } from "./vite.shared.js";

export default defineConfig(() => {
  const shared = createPlaygroundConfig();
  return {
    ...shared,
    // Intentionally no source aliases: package exports must resolve to dist.
    plugins: [...(shared.plugins ?? []), productionPublicEntriesPlugin()]
  };
});
