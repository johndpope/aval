import { describe, expect, it } from "vitest";

import { PresentationObserver } from "../src/presentation-observer.js";
import { ElementOwnershipLedger } from "../src/element-ownership-ledger.js";

describe("PresentationObserver", () => {
  it("coalesces resize bursts to one animation frame", () => {
    let callback!: ResizeObserverCallback;
    let frame!: FrameRequestCallback;
    const boxes: unknown[] = [];
    const ledger = new ElementOwnershipLedger();
    const target = {} as Element;
    const observer = new PresentationObserver({
      target,
      ledger,
      createObserver: (next) => {
        callback = next;
        return { observe: () => undefined, disconnect: () => undefined } as unknown as ResizeObserver;
      },
      requestFrame: (next) => { frame = next; return 1; },
      cancelFrame: () => undefined,
      onBox: (box) => boxes.push(box)
    });
    callback([
      { target, contentBoxSize: [], contentRect: { width: 10, height: 20 } },
      { target, contentBoxSize: [], contentRect: { width: 30, height: 40 } }
    ] as unknown as ResizeObserverEntry[], {} as ResizeObserver);
    expect(boxes).toEqual([]);
    frame(0);
    expect(boxes).toEqual([{ width: 30, height: 40 }]);
    observer.dispose();
    expect(ledger.snapshot().completed).toBe(true);
  });

  it("retains failed observer/frame releases and retries without stale publication", () => {
    const setupLedger = new ElementOwnershipLedger();
    let disconnects = 0;
    expect(() => new PresentationObserver({
      target: {} as Element,
      ledger: setupLedger,
      createObserver: () => ({
        observe: () => { throw new Error("observe failed"); },
        disconnect: () => { disconnects += 1; }
      } as unknown as ResizeObserver),
      requestFrame: () => 1,
      cancelFrame: () => undefined,
      onBox: () => undefined
    })).toThrow("observe failed");
    expect(disconnects).toBe(1);
    expect(setupLedger.snapshot().completed).toBe(true);

    let callback!: ResizeObserverCallback;
    let cancelled = 0;
    let throwDisconnect = true;
    let throwCancel = true;
    const ledger = new ElementOwnershipLedger();
    const boxes: unknown[] = [];
    const target = {} as Element;
    const observer = new PresentationObserver({
      target,
      ledger,
      createObserver: (next) => {
        callback = next;
        return {
          observe: () => undefined,
          disconnect: () => {
            if (throwDisconnect) throw new Error("disconnect failed");
          }
        } as unknown as ResizeObserver;
      },
      requestFrame: () => 7,
      cancelFrame: (handle) => {
        cancelled = handle;
        if (throwCancel) throw new Error("cancel failed");
      },
      onBox: (box) => boxes.push(box)
    });
    callback([
      { target, contentBoxSize: [], contentRect: { width: 2, height: 3 } }
    ] as unknown as ResizeObserverEntry[], {} as ResizeObserver);
    expect(observer.dispose()).toBe(false);
    expect(cancelled).toBe(7);
    expect(ledger.snapshot()).toMatchObject({
      observerCount: 1,
      timerCount: 1,
      failedReleaseCount: 2,
      completed: false
    });
    callback([
      { target, contentBoxSize: [], contentRect: { width: 5, height: 6 } }
    ] as unknown as ResizeObserverEntry[], {} as ResizeObserver);
    expect(boxes).toEqual([]);
    throwDisconnect = false;
    throwCancel = false;
    expect(observer.dispose()).toBe(true);
    expect(ledger.snapshot()).toMatchObject({
      observerCount: 0,
      timerCount: 0,
      failedReleaseCount: 0,
      completed: true
    });
  });

  it("retains an unknown frame until a callback queued before throw fires", () => {
    let resize!: ResizeObserverCallback;
    let queued!: FrameRequestCallback;
    const target = {} as Element;
    const boxes: unknown[] = [];
    const ledger = new ElementOwnershipLedger();
    const observer = new PresentationObserver({
      target,
      ledger,
      createObserver: (callback) => {
        resize = callback;
        return { observe: () => undefined, disconnect: () => undefined } as unknown as ResizeObserver;
      },
      requestFrame: (callback) => {
        queued = callback;
        throw new Error("frame scheduled before throw");
      },
      cancelFrame: () => undefined,
      onBox: (box) => boxes.push(box)
    });
    expect(() => resize([
      { target, contentBoxSize: [], contentRect: { width: 8, height: 9 } }
    ] as unknown as ResizeObserverEntry[], {} as ResizeObserver)).toThrow(
      "frame scheduled before throw"
    );
    expect(ledger.snapshot()).toMatchObject({ timerCount: 1, retainedRetryCount: 1 });
    expect(observer.dispose()).toBe(false);
    queued(0);
    expect(boxes).toEqual([]);
    expect(observer.dispose()).toBe(true);
    expect(ledger.snapshot().completed).toBe(true);
  });

  it("retains observer cleanup when observe and disconnect both throw", () => {
    const ledger = new ElementOwnershipLedger();
    let throwDisconnect = true;
    expect(() => new PresentationObserver({
      target: {} as Element,
      ledger,
      createObserver: () => ({
        observe: () => { throw new Error("observe installed before throw"); },
        disconnect: () => {
          if (throwDisconnect) throw new Error("disconnect failed");
        }
      } as unknown as ResizeObserver),
      requestFrame: () => 1,
      cancelFrame: () => undefined,
      onBox: () => undefined
    })).toThrow("observe installed before throw");
    expect(ledger.snapshot()).toMatchObject({
      observerCount: 1,
      retainedRetryCount: 1,
      completed: false
    });
    throwDisconnect = false;
    expect(ledger.retryAll()).toBe(true);
    expect(ledger.snapshot().completed).toBe(true);
  });
});
