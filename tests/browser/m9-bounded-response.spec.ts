import { expect, test } from "@playwright/test";

test("certification config/source readers enforce streaming byte caps and cancel overflow", async ({ page }) => {
  await page.goto("/certification.html");
  const result = await page.evaluate(async () => {
    const moduleUrl = "/src/certification/run-config.ts";
    const { readBoundedResponseBytes } = await import(moduleUrl);
    const exact = await readBoundedResponseBytes(new Response(new ReadableStream({
      start(controller) { controller.enqueue(new Uint8Array([1, 2])); controller.enqueue(new Uint8Array([3, 4])); controller.close(); }
    }), { headers: { "content-length": "4" } }), 4, "exact");
    let cancelled = false;
    let overflow = "";
    try {
      await readBoundedResponseBytes(new Response(new ReadableStream({
        start(controller) { controller.enqueue(new Uint8Array(5)); },
        cancel() { cancelled = true; }
      })), 4, "overflow");
    } catch (error) { overflow = error instanceof Error ? error.message : String(error); }
    let declared = "";
    try { await readBoundedResponseBytes(new Response(new Uint8Array(1), { headers: { "content-length": "5" } }), 4, "declared"); }
    catch (error) { declared = error instanceof Error ? error.message : String(error); }
    let malformed = "";
    try { await readBoundedResponseBytes(new Response(new Uint8Array(1), { headers: { "content-length": "1e9" } }), 4, "malformed"); }
    catch (error) { malformed = error instanceof Error ? error.message : String(error); }
    return { exact: [...exact], cancelled, overflow, declared, malformed };
  });
  expect(result).toEqual({
    exact: [1, 2, 3, 4],
    cancelled: true,
    overflow: "overflow exceeds byte limit",
    declared: "declared exceeds byte limit",
    malformed: "malformed content-length is invalid"
  });
});
