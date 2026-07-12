import { describe, expect, it } from "vitest";

describe("element root", () => {
  it("imports without DOM globals or registration side effects", async () => {
    const before = Reflect.get(globalThis, "customElements");
    const module = await import("../src/index.js");
    expect(module.RENDERED_MOTION_TAG_NAME).toBe("rendered-motion");
    expect(Reflect.get(globalThis, "customElements")).toBe(before);
    expect(() => module.defineRenderedMotionElement()).toThrowError(
      expect.objectContaining({ name: "NotSupportedError" })
    );
  });
});
