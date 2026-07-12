import { expect, test } from "@playwright/test";

import { buildIndependentElementBundles } from "./m8-definition-bundle-copies.js";

test("root definition is explicit, idempotent, and compatible", async ({ page }) => {
  await page.goto("/m8-no-js.html");
  const result = await page.evaluate(async () => {
    const apiPath = "/src/m8-element-browser-api.ts";
    const api = await import(apiPath);
    const before = customElements.get("rendered-motion") ?? null;
    const first = api.defineRenderedMotionElement();
    const second = api.defineRenderedMotionElement();
    const element = document.createElement("rendered-motion");
    return {
      before: before === null,
      same: first === second && second === customElements.get("rendered-motion"),
      upgraded: element.shadowRoot !== null
    };
  });
  expect(result).toEqual({ before: true, same: true, upgraded: true });
});

test("auto entry registers in an otherwise fresh page", async ({ page }) => {
  await page.goto("/m8-no-js.html");
  await page.evaluate(async () => {
    const apiPath = "/src/m8-element-browser-api.ts";
    const api = await import(apiPath);
    await api.importRenderedMotionAuto();
  });
  expect(await page.evaluate(() => customElements.get("rendered-motion") !== undefined)).toBe(true);
});

test("two independently bundled public package copies share one compatible definition", async ({ page }) => {
  const [copyA, copyB] = await buildIndependentElementBundles();
  expect(copyA.bytes).toBeGreaterThan(0);
  expect(copyB.bytes).toBeGreaterThan(0);
  await page.route("**/__m8-element-copy-a.js", (route) => route.fulfill({
    status: 200,
    contentType: "text/javascript; charset=utf-8",
    headers: { "Cache-Control": "no-store" },
    body: copyA.code
  }), { times: 1 });
  await page.route("**/__m8-element-copy-b.js", (route) => route.fulfill({
    status: 200,
    contentType: "text/javascript; charset=utf-8",
    headers: { "Cache-Control": "no-store" },
    body: copyB.code
  }), { times: 1 });
  await page.goto("/m8-no-js.html");
  const result = await page.evaluate(async ([copyAUrl, copyBUrl]) => {
    type ElementPublicEntry = Readonly<{
      defineRenderedMotionElement: () => CustomElementConstructor;
      RENDERED_MOTION_TAG_NAME: string;
    }>;
    const [firstCopy, secondCopy] = await Promise.all([
      import(copyAUrl) as Promise<ElementPublicEntry>,
      import(copyBUrl) as Promise<ElementPublicEntry>
    ]);
    const independentEvaluation = firstCopy.defineRenderedMotionElement !== secondCopy.defineRenderedMotionElement;
    const before = customElements.get(firstCopy.RENDERED_MOTION_TAG_NAME);
    const firstConstructor = firstCopy.defineRenderedMotionElement();
    const secondResult = secondCopy.defineRenderedMotionElement();
    const created = document.createElement(firstCopy.RENDERED_MOTION_TAG_NAME) as HTMLElement & { getDiagnostics?: unknown };
    return {
      before: before === undefined,
      independentEvaluation,
      samePublicTag: firstCopy.RENDERED_MOTION_TAG_NAME === secondCopy.RENDERED_MOTION_TAG_NAME,
      reused: firstConstructor === secondResult && customElements.get(firstCopy.RENDERED_MOTION_TAG_NAME) === firstConstructor,
      genuineConstructor: Array.isArray((firstConstructor as typeof HTMLElement & { observedAttributes?: unknown }).observedAttributes) && typeof created.getDiagnostics === "function",
      upgraded: created.shadowRoot !== null
    };
  }, ["/__m8-element-copy-a.js", "/__m8-element-copy-b.js"] as const);
  expect(result).toEqual({
    before: true,
    independentEvaluation: true,
    samePublicTag: true,
    reused: true,
    genuineConstructor: true,
    upgraded: true
  });
});

test("a foreign definition is rejected without replacing it", async ({ page }) => {
  await page.goto("/m8-no-js.html");
  const result = await page.evaluate(async () => {
    class ForeignElement extends HTMLElement {}
    customElements.define("rendered-motion", ForeignElement);
    const apiPath = "/src/m8-element-browser-api.ts";
    const api = await import(apiPath);
    try {
      api.defineRenderedMotionElement();
      return null;
    } catch (error) {
      return {
        name: error instanceof Error ? error.name : null,
        message: error instanceof Error ? error.message : null,
        unchanged: customElements.get("rendered-motion") === ForeignElement
      };
    }
  });
  expect(result).toEqual({
    name: "NotSupportedError",
    message: "rendered-motion is already defined by incompatible code",
    unchanged: true
  });
});
