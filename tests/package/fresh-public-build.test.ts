import { mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { assertDistributionDerived, installVerifiedDistributions } from "../../scripts/release/fresh-public-build.mjs";

describe("fresh public distribution provenance", () => {
  it("does not emit the TypeScript 7 removed baseUrl option", async () => {
    const source = await readFile("scripts/release/fresh-public-build.mjs", "utf8");
    expect(source).not.toMatch(/\bbaseUrl\s*:/u);
  });

  it("rejects stale removed poster output and accepts only source-derived JS/declarations", async () => {
    const root = await mkdtemp(join(tmpdir(), "rma-fresh-dist-"));
    try {
      const source = join(root, "src");
      const distribution = join(root, "dist");
      await mkdir(source);
      await mkdir(distribution);
      await writeFile(join(source, "index.ts"), "export const current = true;\n");
      await writeFile(join(distribution, "index.js"), "export const current = true;\n");
      await writeFile(join(distribution, "index.d.ts"), "export declare const current = true;\n");
      await writeFile(join(distribution, "element.release.tsbuildinfo"), "{}\n");
      await writeFile(join(distribution, "poster-owner.js"), "export const stale = true;\n");
      await expect(assertDistributionDerived({ source, distribution, packageName: "@rendered-motion/element" })).rejects.toThrow(/poster-owner\.js/u);
      await rm(join(distribution, "poster-owner.js"));
      await expect(assertDistributionDerived({ source, distribution, packageName: "@rendered-motion/element" })).resolves.toMatchObject({ outputs: ["element.release.tsbuildinfo", "index.d.ts", "index.js"] });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rejects an omitted output even when a release tsconfig accidentally excludes its source", async () => {
    const root = await mkdtemp(join(tmpdir(), "rma-fresh-omission-"));
    try {
      const source = join(root, "src");
      const distribution = join(root, "dist");
      await mkdir(source);
      await mkdir(distribution);
      await writeFile(join(source, "index.ts"), "export {};\n");
      await writeFile(join(source, "excluded-by-drift.ts"), "export const required = true;\n");
      for (const path of ["index.js", "index.js.map", "index.d.ts", "index.d.ts.map", "graph.tsbuildinfo"]) await writeFile(join(distribution, path), "{}\n");
      await expect(assertDistributionDerived({ source, distribution, packageName: "@rendered-motion/graph" })).rejects.toThrow(/missing required.*excluded-by-drift/u);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rejects emitted test output even when a similarly named source exists", async () => {
    const root = await mkdtemp(join(tmpdir(), "rma-fresh-test-"));
    try {
      const source = join(root, "src");
      const distribution = join(root, "dist");
      await mkdir(source);
      await mkdir(distribution);
      await writeFile(join(source, "index.ts"), "export {};\n");
      await writeFile(join(source, "behavior.test.ts"), "export {};\n");
      for (const path of ["index.js", "index.d.ts", "behavior.test.js"]) await writeFile(join(distribution, path), "export {};\n");
      await expect(assertDistributionDerived({ source, distribution, packageName: "@rendered-motion/graph" })).rejects.toThrow(/exact release emission contract|test output/u);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("restores every previous dist when a later verified atomic install fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "rma-fresh-install-"));
    try {
      const staged = new Map<string, string>();
      for (const short of ["graph", "format", "player-web", "element", "compiler"]) {
        const current = join(root, "packages", short, "dist");
        const next = join(root, "staged", short);
        await mkdir(current, { recursive: true });
        await mkdir(next, { recursive: true });
        await writeFile(join(current, "identity"), `old-${short}`);
        await writeFile(join(next, "identity"), `new-${short}`);
        staged.set(`@rendered-motion/${short}`, next);
      }
      const renameEntry = async (source: string, target: string) => {
        if (source === staged.get("@rendered-motion/player-web")) throw new Error("injected install failure");
        await rename(source, target);
      };
      await expect(installVerifiedDistributions({ root, staged, backupRoot: join(root, "backup"), renameEntry })).rejects.toThrow(/injected install failure/u);
      for (const short of ["graph", "format", "player-web", "element", "compiler"]) expect(await readFile(join(root, "packages", short, "dist", "identity"), "utf8")).toBe(`old-${short}`);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
