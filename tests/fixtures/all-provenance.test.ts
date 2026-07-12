import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const execFileAsync = promisify(execFile);

describe("all fixture provenance", () => {
  it("is path-safe and digest-linked without native tools", async () => {
    const { stdout } = await execFileAsync(process.execPath, ["scripts/fixtures/verify-provenance.mjs"], {
      cwd: process.cwd(),
      maxBuffer: 1024 * 1024
    });
    const result = JSON.parse(stdout) as { status: string; files: readonly { references: number }[] };
    expect(result.status).toBe("passed");
    expect(result.files.length).toBeGreaterThanOrEqual(5);
    expect(result.files.every((file) => file.references > 0)).toBe(true);
  }, 30_000);
});
