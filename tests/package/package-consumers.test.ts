import { access, readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

describe("packed consumer fixtures", () => {
  it("declare only public package-root imports and no workspace source paths", async () => {
    for (const fixture of ["node-esm/index.mjs", "typescript-nodenext/index.ts", "typescript-bundler/index.ts", "browser-vite/src/main.ts"]) {
      await expect(access(`tests/consumers/${fixture}`)).resolves.toBeUndefined();
      const source = await readFile(`tests/consumers/${fixture}`, "utf8");
      expect(source).not.toMatch(/\.\.\/\.\.\/packages\//u);
    }
  });
});
