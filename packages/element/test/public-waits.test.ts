import { describe, expect, it, vi } from "vitest";

import { waitForPublicOperation } from "../src/public-waits.js";

describe("public wait binding", () => {
  it("caller abort does not cancel the shared operation", async () => {
    let resolveShared!: (value: number) => void;
    const shared = new Promise<number>((resolve) => { resolveShared = resolve; });
    const caller = new AbortController();
    const bounded = waitForPublicOperation(shared, { signal: caller.signal });
    caller.abort(new DOMException("caller left", "AbortError"));
    await expect(bounded).rejects.toMatchObject({ name: "AbortError" });
    resolveShared(42);
    await expect(shared).resolves.toBe(42);
  });

  it("bounds only one caller with a timeout", async () => {
    vi.useFakeTimers();
    try {
      const shared = new Promise<number>(() => undefined);
      const bounded = waitForPublicOperation(shared, { timeoutMs: 10 });
      const rejection = expect(bounded).rejects.toMatchObject({ name: "TimeoutError" });
      await vi.advanceTimersByTimeAsync(10);
      await rejection;
    } finally {
      vi.useRealTimers();
    }
  });

  it("accepts the 30s deadline boundary and rejects timer-overflow values", async () => {
    await expect(waitForPublicOperation(Promise.resolve(7), {
      timeoutMs: 30_000
    })).resolves.toBe(7);
    await expect(waitForPublicOperation(new Promise<number>(() => undefined), {
      timeoutMs: 30_001
    })).rejects.toBeInstanceOf(RangeError);
    await expect(waitForPublicOperation(new Promise<number>(() => undefined), {
      timeoutMs: 2 ** 31
    })).rejects.toBeInstanceOf(RangeError);
  });
});
