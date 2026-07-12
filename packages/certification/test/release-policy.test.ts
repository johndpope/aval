import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { PUBLIC_RELEASE_PACKAGES } from "../src/compatibility.js";

describe("release policy", () => {
  it("pins the candidate and trusted-publishing toolchains without conflating them", async () => {
    const policy = JSON.parse(await readFile("config/release/release-policy.json", "utf8")) as {
      publicPackages: readonly string[];
      registry: { url: string };
      toolchain: Record<string, string>;
      trustedPublishing: { minimumNode: string; minimumNpm: string; oidcOperations: readonly string[]; distTagPromotionRequiresSeparateShortLivedAuthorization: boolean };
      ci: { playwrightBrowserManifestSha256: string };
    };
    expect(policy.publicPackages).toEqual(PUBLIC_RELEASE_PACKAGES);
    expect(policy.registry.url).toBe("https://registry.npmjs.org/");
    expect(Object.values(policy.toolchain).every((version) => /^\d+\.\d+\.\d+$/u.test(version))).toBe(true);
    expect(policy.toolchain).toMatchObject({
      minimumNode: "22.12.0",
      minimumNpm: "10.9.0",
      candidateNode: "22.12.0",
      candidateNpm: "10.9.0"
    });
    expect(policy.trustedPublishing.minimumNode).toBe("22.14.0");
    expect(policy.trustedPublishing.minimumNpm).toBe("11.5.1");
    expect(policy.trustedPublishing.oidcOperations).not.toContain("dist-tag");
    expect(policy.trustedPublishing.distTagPromotionRequiresSeparateShortLivedAuthorization).toBe(true);
    const browsers = await readFile("node_modules/playwright-core/browsers.json");
    expect(createHash("sha256").update(browsers).digest("hex")).toBe(policy.ci.playwrightBrowserManifestSha256);
  });
});
