import { describe, expect, it } from "vitest";

import { ElementSourceGenerationPublication } from "../src/element-source-generation-publication.js";

describe("ElementSourceGenerationPublication", () => {
  it("does not publish a nonexistent generation when construction throws", () => {
    const publication = new ElementSourceGenerationPublication();
    const first = publication.construct(1, () => Object.freeze({ generation: 1 }));
    expect(first.generation).toBe(1);
    expect(publication.value).toBe(1);
    expect(() => publication.construct(2, () => {
      throw new Error("hostile layer construction");
    })).toThrow("hostile layer construction");
    expect(publication.value).toBe(1);
  });
});
