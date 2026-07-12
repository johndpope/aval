import { describe, expect, it } from "vitest";

import { ElementRealmAutomation } from "../src/element-realm-automation.js";
import { ElementOwnershipLedger } from "../src/element-ownership-ledger.js";

describe("ElementRealmAutomation", () => {
  it("invalidates old-realm callbacks before independently draining hostile owners", () => {
    const firstWindow = new FakeWindow();
    const firstDocument = new FakeDocument(firstWindow);
    const secondWindow = new FakeWindow();
    const secondDocument = new FakeDocument(secondWindow);
    let root: Node = {} as Node;
    const host = {
      ownerDocument: firstDocument as unknown as Document,
      getRootNode: () => root
    } as unknown as HTMLElement;
    const publications: string[] = [];
    const ledger = new ElementOwnershipLedger();
    let throwFirstDpr = true;
    const automation = new ElementRealmAutomation({
      host,
      ledger,
      onDocumentVisible: (visible, restored) => {
        publications.push(`document:${String(visible)}:${String(restored)}`);
      },
      onIntersection: (intersecting) => { publications.push(`intersection:${String(intersecting)}`); },
      onObserverSupported: (supported) => { publications.push(`observer:${String(supported)}`); },
      onBox: ({ width, height }) => { publications.push(`box:${String(width)}x${String(height)}`); },
      onDpr: (value) => {
        if (throwFirstDpr) {
          throwFirstDpr = false;
          throw new Error("hostile DPR consumer");
        }
        publications.push(`dpr:${String(value)}`);
      },
      onHostReduced: (value) => { publications.push(`motion:${String(value)}`); },
      onUnsupported: () => { publications.push("unsupported"); }
    });

    expect(automation.enterCurrentRealm()).toEqual({ rootChanged: false, documentChanged: false });
    expect(() => automation.start()).not.toThrow();
    const oldIntersection = firstWindow.intersections[0]!;
    const oldResize = firstWindow.resizes[0]!;
    oldResize.callback([resizeEntry(host, 20, 30)], oldResize.observer);
    expect(firstWindow.frames.size).toBe(1);

    firstDocument.throwOnRemove = true;
    firstWindow.throwOnRemove = true;
    firstWindow.visualViewport.throwOnRemove = true;
    firstWindow.queries.forEach((query) => { query.throwOnRemove = true; });
    oldIntersection.throwOnDisconnect = true;
    oldResize.throwOnDisconnect = true;
    expect(automation.stop()).toBe(false);
    expect(oldIntersection.disconnects).toBe(1);
    expect(oldResize.disconnects).toBe(1);
    expect(firstWindow.cancelledFrames).toHaveLength(1);
    expect(firstDocument.removeAttempts).toBeGreaterThan(0);
    expect(firstWindow.removeAttempts).toBeGreaterThan(0);
    expect(ledger.snapshot()).toMatchObject({
      observerCount: 2,
      brokerSubscriptionCount: 3,
      failedReleaseCount: 5,
      completed: false
    });

    (host as unknown as { ownerDocument: Document }).ownerDocument =
      secondDocument as unknown as Document;
    root = {} as Node;
    expect(automation.enterCurrentRealm()).toEqual({ rootChanged: true, documentChanged: true });
    expect(() => automation.start()).not.toThrow();
    const afterSecondStart = publications.length;

    oldIntersection.callback([intersectionEntry(host, true)], oldIntersection.observer);
    oldResize.callback([resizeEntry(host, 40, 50)], oldResize.observer);
    firstWindow.devicePixelRatio = 3;
    firstWindow.dispatchEvent(new Event("resize"));
    const pageShow = new Event("pageshow");
    Object.defineProperty(pageShow, "persisted", { value: true });
    firstWindow.dispatchEvent(pageShow);
    for (const query of firstWindow.queries) query.emit(true);
    firstWindow.flushFrames();
    expect(publications).toHaveLength(afterSecondStart);

    secondWindow.intersections[0]!.callback(
      [intersectionEntry(host, true)],
      secondWindow.intersections[0]!.observer
    );
    secondWindow.resizes[0]!.callback(
      [resizeEntry(host, 60, 70)],
      secondWindow.resizes[0]!.observer
    );
    secondWindow.flushFrames();
    expect(publications.slice(afterSecondStart)).toEqual([
      "intersection:true",
      "box:60x70"
    ]);
    firstDocument.throwOnRemove = false;
    firstWindow.throwOnRemove = false;
    firstWindow.visualViewport.throwOnRemove = false;
    firstWindow.queries.forEach((query) => { query.throwOnRemove = false; });
    oldIntersection.throwOnDisconnect = false;
    oldResize.throwOnDisconnect = false;
    expect(automation.dispose()).toBe(true);
    expect(ledger.snapshot()).toMatchObject({
      listenerCount: 0,
      observerCount: 0,
      brokerSubscriptionCount: 0,
      timerCount: 0,
      failedReleaseCount: 0,
      completed: true
    });
  });

  it("acquires ownership before constructing any realm-bound physical owner", () => {
    const window = new FakeWindow();
    const document = new FakeDocument(window);
    const host = {
      ownerDocument: document as unknown as Document,
      getRootNode: () => ({} as Node)
    } as unknown as HTMLElement;
    const ledger = new ElementOwnershipLedger({ maximumOwnerId: 1 });
    ledger.acquire("command").complete();
    const automation = new ElementRealmAutomation({
      host,
      ledger,
      onDocumentVisible: () => undefined,
      onIntersection: () => undefined,
      onObserverSupported: () => undefined,
      onBox: () => undefined,
      onDpr: () => undefined,
      onHostReduced: () => undefined,
      onUnsupported: () => undefined
    });
    expect(() => automation.start()).not.toThrow();
    expect(window.intersections).toHaveLength(0);
    expect(window.resizes).toHaveLength(0);
    expect(window.queries).toHaveLength(0);
    expect(ledger.snapshot()).toMatchObject({
      observerCount: 0,
      brokerSubscriptionCount: 0,
      completed: true
    });
    expect(automation.dispose()).toBe(true);
  });

  it("keeps broker ownership when a host installs then throws", () => {
    const window = new FakeWindow();
    const document = new FakeDocument(window);
    document.throwAfterAdd = true;
    document.throwOnRemove = true;
    const host = {
      ownerDocument: document as unknown as Document,
      getRootNode: () => ({} as Node)
    } as unknown as HTMLElement;
    const ledger = new ElementOwnershipLedger();
    const automation = new ElementRealmAutomation({
      host,
      ledger,
      onDocumentVisible: () => undefined,
      onIntersection: () => undefined,
      onObserverSupported: () => undefined,
      onBox: () => undefined,
      onDpr: () => undefined,
      onHostReduced: () => undefined,
      onUnsupported: () => undefined
    });
    automation.start();
    expect(ledger.snapshot()).toMatchObject({
      brokerSubscriptionCount: 3,
      retainedRetryCount: 1,
      completed: false
    });
    document.throwAfterAdd = false;
    document.throwOnRemove = false;
    expect(automation.dispose()).toBe(true);
    expect(ledger.snapshot().completed).toBe(true);
  });
});

class FaultyEventTarget extends EventTarget {
  public throwAfterAdd = false;
  public throwOnRemove = false;
  public removeAttempts = 0;

  public override addEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions
  ): void {
    super.addEventListener(type, callback, options);
    if (this.throwAfterAdd) throw new Error(`hostile add after ${type}`);
  }

  public override removeEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | EventListenerOptions
  ): void {
    this.removeAttempts += 1;
    if (this.throwOnRemove) throw new Error(`hostile remove ${type}`);
    super.removeEventListener(type, callback, options);
  }
}

class FakeDocument extends FaultyEventTarget {
  public visibilityState: "visible" | "hidden" = "visible";
  public constructor(public readonly defaultView: FakeWindow) { super(); }
}

class FakeMediaQuery extends FaultyEventTarget {
  public matches = false;
  public readonly media: string;
  public constructor(media: string) {
    super();
    this.media = media;
  }
  public emit(matches: boolean): void {
    this.matches = matches;
    const event = new Event("change");
    Object.defineProperty(event, "matches", { value: matches });
    this.dispatchEvent(event);
  }
}

class FakeIntersection {
  public disconnects = 0;
  public throwOnDisconnect = false;
  public readonly observer: IntersectionObserver;
  public constructor(public readonly callback: IntersectionObserverCallback) {
    this.observer = {
      observe: () => undefined,
      unobserve: () => undefined,
      takeRecords: () => [],
      disconnect: () => {
        this.disconnects += 1;
        if (this.throwOnDisconnect) throw new Error("hostile intersection disconnect");
      },
      root: null,
      rootMargin: "0px",
      thresholds: [0]
    } as unknown as IntersectionObserver;
  }
}

class FakeResize {
  public disconnects = 0;
  public throwOnDisconnect = false;
  public readonly observer: ResizeObserver;
  public constructor(public readonly callback: ResizeObserverCallback) {
    this.observer = {
      observe: () => undefined,
      unobserve: () => undefined,
      disconnect: () => {
        this.disconnects += 1;
        if (this.throwOnDisconnect) throw new Error("hostile resize disconnect");
      }
    } as unknown as ResizeObserver;
  }
}

class FakeWindow extends FaultyEventTarget {
  public devicePixelRatio = 1;
  public readonly visualViewport = new FaultyEventTarget();
  public readonly queries: FakeMediaQuery[] = [];
  public readonly intersections: FakeIntersection[] = [];
  public readonly resizes: FakeResize[] = [];
  public readonly frames = new Map<number, FrameRequestCallback>();
  public readonly cancelledFrames: number[] = [];
  #nextFrame = 0;
  public readonly IntersectionObserver: typeof IntersectionObserver;
  public readonly ResizeObserver: typeof ResizeObserver;

  public constructor() {
    super();
    const owner = this;
    this.IntersectionObserver = class {
      public readonly delegate: FakeIntersection;
      public readonly root = null;
      public readonly rootMargin = "0px";
      public readonly thresholds = [0];
      public constructor(callback: IntersectionObserverCallback) {
        this.delegate = new FakeIntersection(callback);
        owner.intersections.push(this.delegate);
      }
      public observe(): void { /* fixture */ }
      public unobserve(): void { /* fixture */ }
      public takeRecords(): IntersectionObserverEntry[] { return []; }
      public disconnect(): void { this.delegate.observer.disconnect(); }
    } as unknown as typeof IntersectionObserver;
    this.ResizeObserver = class {
      public readonly delegate: FakeResize;
      public constructor(callback: ResizeObserverCallback) {
        this.delegate = new FakeResize(callback);
        owner.resizes.push(this.delegate);
      }
      public observe(): void { /* fixture */ }
      public unobserve(): void { /* fixture */ }
      public disconnect(): void { this.delegate.observer.disconnect(); }
    } as unknown as typeof ResizeObserver;
  }

  public matchMedia(media: string): MediaQueryList {
    const query = new FakeMediaQuery(media);
    this.queries.push(query);
    return query as unknown as MediaQueryList;
  }

  public requestAnimationFrame(callback: FrameRequestCallback): number {
    const handle = ++this.#nextFrame;
    this.frames.set(handle, callback);
    return handle;
  }

  public cancelAnimationFrame(handle: number): void {
    this.cancelledFrames.push(handle);
    this.frames.delete(handle);
  }

  public flushFrames(): void {
    const frames = [...this.frames];
    this.frames.clear();
    for (const [, callback] of frames) callback(0);
  }
}

function intersectionEntry(target: Element, intersecting: boolean): IntersectionObserverEntry {
  return {
    target,
    isIntersecting: intersecting,
    intersectionRatio: intersecting ? 1 : 0
  } as IntersectionObserverEntry;
}

function resizeEntry(target: Element, width: number, height: number): ResizeObserverEntry {
  return {
    target,
    contentBoxSize: [],
    contentRect: { width, height }
  } as unknown as ResizeObserverEntry;
}
