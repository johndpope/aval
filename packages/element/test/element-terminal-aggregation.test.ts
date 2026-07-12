import { describe, expect, it } from "vitest";

import { aggregateElementTerminalCleanup } from "../src/element-terminal-aggregation.js";

describe("aggregateElementTerminalCleanup", () => {
  it("attempts every simultaneous failure and succeeds on a later retry", async () => {
    const attempts = [0, 0, 0, 0];
    let hostile = true;
    const operations = attempts.map((_value, index) => async () => {
      attempts[index] = attempts[index]! + 1;
      if (hostile && index % 2 === 0) throw new Error(`owner ${String(index)}`);
      if (hostile) return false;
      return true;
    });
    await expect(aggregateElementTerminalCleanup(operations)).resolves.toBe(false);
    expect(attempts).toEqual([1, 1, 1, 1]);
    hostile = false;
    await expect(aggregateElementTerminalCleanup(operations)).resolves.toBe(true);
    expect(attempts).toEqual([2, 2, 2, 2]);
  });
});
