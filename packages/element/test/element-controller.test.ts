import { describe, expect, it } from "vitest";

import type { ElementAssetGeneration } from "../src/asset-generation.js";
import { ElementController } from "../src/element-controller.js";

describe("ElementController", () => {
  it("starts only the newest identity after serialized old cleanup", async () => {
    let releaseOld!: () => void;
    const created: number[] = [];
    const disposed: number[] = [];
    const controller = new ElementController({
      create: (generation) => {
        created.push(generation);
        return {
          dispose: async () => {
            disposed.push(generation);
            if (generation === 1) await new Promise<void>((resolve) => { releaseOld = resolve; });
          },
          cleanupReceipt: () => completeReceipt(generation)
        } as unknown as ElementAssetGeneration;
      }
    });
    await controller.replace();
    const second = controller.replace();
    await Promise.resolve();
    const third = controller.replace();
    releaseOld();
    await Promise.all([second, third]);
    expect(created).toEqual([1, 2]);
    expect(disposed).toEqual([1]);
  });

  it("fails closed before request or publication identities can be reused", async () => {
    const requestBound = new ElementController({
      maximumSequence: 1,
      create: () => null
    });
    await requestBound.replace();
    expect(() => requestBound.retire()).toThrow("source request sequence is exhausted");

    const publicationBound = new ElementController({
      maximumRequestSequence: 3,
      maximumGeneration: 1,
      create: () => null
    });
    await publicationBound.replace();
    await expect(publicationBound.replace()).rejects.toThrow(
      "source generation sequence is exhausted"
    );
  });
});

function completeReceipt(sourceGeneration: number) {
  return Object.freeze({ completed: true, sourceGeneration });
}
