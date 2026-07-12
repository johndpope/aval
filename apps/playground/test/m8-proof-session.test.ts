import { describe, expect, it } from "vitest";

import { deriveM8ProofSession } from "../src/m8-proof-session.js";

describe("M8 playground proof sessions", () => {
  it("keeps the default stable and isolates complete query identities without exposing them", () => {
    expect(deriveM8ProofSession("")).toBe("m8-page-default");
    const first = deriveM8ProofSession("?presentation&case=alpha");
    const second = deriveM8ProofSession("?presentation&case=beta");
    expect(first).toMatch(/^m8-page-[a-f0-9]{8}$/u);
    expect(second).toMatch(/^m8-page-[a-f0-9]{8}$/u);
    expect(first).not.toBe(second);
    expect(`${first}${second}`).not.toContain("presentation");
    expect(`${first}${second}`).not.toContain("alpha");
  });
});
