import { describe, expect, it } from "vitest";

import {
  RENDERED_MOTION_ELEMENT_API_MAJOR,
  RENDERED_MOTION_TAG_NAME
} from "../src/index.js";

describe("public element API", () => {
  it("freezes the prototype tag and API major", () => {
    expect(RENDERED_MOTION_TAG_NAME).toBe("rendered-motion");
    expect(RENDERED_MOTION_ELEMENT_API_MAJOR).toBe(1);
  });
});
