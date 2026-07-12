import { fileURLToPath } from "node:url";

import type { UserConfig } from "vite";

import { m7HttpFixturePlugin } from "./m7-http-fixture-plugin.js";
import { m8HttpFixturePlugin } from "./m8-http-fixture-plugin.js";

/** Inputs and local fixture authorities shared by development and release builds. */
export function createPlaygroundConfig(): UserConfig {
  return {
    plugins: [m7HttpFixturePlugin(), m8HttpFixturePlugin()],
    build: {
      rollupOptions: {
        input: {
          playground: fileURLToPath(new URL("./index.html", import.meta.url)),
          element: fileURLToPath(new URL("./m8-dev-entry.html", import.meta.url)),
          bfcache: fileURLToPath(new URL("./m8-bfcache.html", import.meta.url)),
          publicApi: fileURLToPath(new URL("./src/m8-element-browser-api.ts", import.meta.url)),
          noJs: fileURLToPath(new URL("./m8-no-js.html", import.meta.url)),
          strictCsp: fileURLToPath(new URL("./m8-strict-csp.html", import.meta.url)),
          certification: fileURLToPath(new URL("./certification.html", import.meta.url))
        }
      }
    }
  };
}
