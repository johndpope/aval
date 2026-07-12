import { describe, expect, it } from "vitest";

import type { ElementAssetGeneration } from "../src/asset-generation.js";
import type { ElementController } from "../src/element-controller.js";
import { ElementDesiredState } from "../src/element-desired-state.js";
import {
  ElementSourceEffectState,
  beginElementSourceInvalidation
} from "../src/element-source-effects.js";

describe("element source effects", () => {
  it("captures context recovery before synchronous active-source invalidation", async () => {
    let active: ElementAssetGeneration | null = {
      runtime: () => ({
        snapshot: () => ({ contextRecoveryCount: 3 })
      })
    } as unknown as ElementAssetGeneration;
    const controller = {
      get active() { return active; },
      retire: () => {
        active = null;
        return Promise.resolve();
      }
    } as unknown as ElementController;
    const result = beginElementSourceInvalidation({
      desired: new ElementDesiredState(),
      controller,
      state: new ElementSourceEffectState()
    });
    expect(result).toMatchObject({
      hadActive: true,
      retiredContextRecoveryCount: 3
    });
    await result.operation;
    expect(active).toBeNull();
  });
});
