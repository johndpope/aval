# Grass Rabbit Codec Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a separate grass-rabbit example that compiles the exact authored video and state graph into AV1, VP9, H.265, and H.264 AVAL assets, presents one codec per accessible tab, and reports the real compilation parameters and output size.

**Architecture:** A single schema-1.0 project emits an atomic four-file codec bundle plus `build.json`. The browser reads that report, probes each exact decoder configuration through `createSourceSupportProbe()`, and mounts one single-source `<aval-player>` only when the selected codec is supported; unsupported UI is owned entirely by the example. One shared controller preserves the original intro, hover/focus engagement, state badge, and hotspot behavior across tab changes.

**Tech Stack:** AVAL compiler/runtime/element workspaces, vanilla JavaScript, semantic HTML tabs, Tailwind CSS through Vite, Vitest-format static checks, Playwright Chromium/WebKit tests, and a headed macOS Safari exploratory pass.

---

## File structure

- Create `examples/grass-rabbit-codecs/package.json` — standalone workspace scripts and dependencies.
- Create `examples/grass-rabbit-codecs/motion.json` — unchanged rabbit graph plus four slow/compression-focused encoding policies.
- Copy `examples/grass-rabbit/source/grass-test-with-intro.mp4` to `examples/grass-rabbit-codecs/source/grass-test-with-intro.mp4` — compiler-confined byte-identical source.
- Create `examples/grass-rabbit-codecs/index.html` — page shell, four semantic tabs, four linked tab panels, and detail placeholders.
- Create `examples/grass-rabbit-codecs/main.js` — report parsing, exact support probes, tab controller, player lifecycle, rabbit state tracking, and command/size rendering.
- Create `examples/grass-rabbit-codecs/style.css` — responsive comparison UI, tab/error/player states, focus, touch, and reduced-motion rules.
- Create `examples/grass-rabbit-codecs/vite.config.js` — Tailwind-enabled Vite config.
- Copy `examples/grass-rabbit/public/interaction-hotspot.svg` to `examples/grass-rabbit-codecs/public/interaction-hotspot.svg`.
- Create `examples/grass-rabbit-codecs/README.md` — compile/run instructions and browser-support semantics.
- Generate `examples/grass-rabbit-codecs/public/grass-rabbit/{av1,vp9,h265,h264}.avl` and `build.json`.
- Create `tests/grass-rabbit-codecs/grass-rabbit-codecs.spec.ts` — artifact, tabs, support UI, and full graph interaction checks.
- Create `playwright.grass-rabbit-codecs.config.ts` — Chromium and Desktop Safari/WebKit projects.
- Modify root `package.json` and `package-lock.json` — register workspace and build/dev/compile/test scripts.

### Task 1: Scaffold the independent example and exact source

**Files:**
- Create: `examples/grass-rabbit-codecs/package.json`
- Create: `examples/grass-rabbit-codecs/vite.config.js`
- Create: `examples/grass-rabbit-codecs/motion.json`
- Create: `examples/grass-rabbit-codecs/source/grass-test-with-intro.mp4`
- Create: `examples/grass-rabbit-codecs/public/interaction-hotspot.svg`
- Modify: `package.json`
- Modify: `package-lock.json`

- [ ] **Step 1: Register the workspace and scripts**

Add `examples/grass-rabbit-codecs` to root workspaces and add these root scripts:

```json
{
  "grass-rabbit-codecs": "npm run dev -w @pixel-point/aval-grass-rabbit-codecs-example --",
  "compile:grass-rabbit-codecs": "npm run build:public-packages && npm run compile -w @pixel-point/aval-grass-rabbit-codecs-example",
  "test:grass-rabbit-codecs": "playwright test --config playwright.grass-rabbit-codecs.config.ts"
}
```

Create the example package with `@pixel-point/aval-element` and `@pixel-point/aval-player-web` runtime dependencies, compiler/Tailwind/Vite dev dependencies, and scripts:

```json
{
  "name": "@pixel-point/aval-grass-rabbit-codecs-example",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "vite build --base=/aval/grass-rabbit-codecs/",
    "compile": "avl compile motion.json --out public/grass-rabbit --force",
    "dev": "vite --host 127.0.0.1"
  }
}
```

- [ ] **Step 2: Copy and verify the exact source bytes**

Run:

```sh
mkdir -p examples/grass-rabbit-codecs/source examples/grass-rabbit-codecs/public
cp examples/grass-rabbit/source/grass-test-with-intro.mp4 examples/grass-rabbit-codecs/source/grass-test-with-intro.mp4
cp examples/grass-rabbit/public/interaction-hotspot.svg examples/grass-rabbit-codecs/public/interaction-hotspot.svg
shasum -a 256 examples/grass-rabbit/source/grass-test-with-intro.mp4 examples/grass-rabbit-codecs/source/grass-test-with-intro.mp4
```

Expected: both hashes equal `546acee64cc36c13f8765e215a0a20fb5742026c57364c59560fa86bb68988b1`.

- [ ] **Step 3: Preserve the complete graph and set native slow encodings**

Copy the existing project and keep every unit, state, edge, binding, range, and 1280×720 canvas unchanged. Replace only `encodings` with:

```json
[
  {
    "codec": "av1",
    "bitDepth": 10,
    "cpuUsed": 0,
    "tiles": { "columns": 4, "rows": 2 },
    "rowMt": true,
    "threads": 32,
    "renditions": [
      { "id": "video.1x", "width": 1280, "height": "auto", "crf": 48 }
    ]
  },
  {
    "codec": "vp9",
    "deadline": "best",
    "cpuUsed": 0,
    "threads": 8,
    "renditions": [
      { "id": "video.1x", "width": 1280, "height": "auto", "crf": 44 }
    ]
  },
  {
    "codec": "h265",
    "preset": "veryslow",
    "threads": 8,
    "renditions": [
      { "id": "video.1x", "width": 1280, "height": "auto", "crf": 34 }
    ]
  },
  {
    "codec": "h264",
    "preset": "veryslow",
    "renditions": [
      { "id": "video.1x", "width": 1280, "height": "auto", "crf": 30 }
    ]
  }
]
```

- [ ] **Step 4: Refresh workspace resolution**

Run `npm install --package-lock-only` and expect the new workspace package to appear in `package-lock.json` without unrelated dependency upgrades.

### Task 2: Compile and certify the four assets

**Files:**
- Generate: `examples/grass-rabbit-codecs/public/grass-rabbit/av1.avl`
- Generate: `examples/grass-rabbit-codecs/public/grass-rabbit/vp9.avl`
- Generate: `examples/grass-rabbit-codecs/public/grass-rabbit/h265.avl`
- Generate: `examples/grass-rabbit-codecs/public/grass-rabbit/h264.avl`
- Generate: `examples/grass-rabbit-codecs/public/grass-rabbit/build.json`
- Test: `tests/grass-rabbit-codecs/grass-rabbit-codecs.spec.ts`

- [ ] **Step 1: Write artifact assertions before compilation**

The static test must parse all four files and assert:

```ts
expect(report.assets.map(({ codec, path }) => ({ codec, path }))).toEqual([
  { codec: "av1", path: "av1.avl" },
  { codec: "vp9", path: "vp9.avl" },
  { codec: "h265", path: "h265.avl" },
  { codec: "h264", path: "h264.avl" }
]);
expect(new Set(manifests.map((manifest) => JSON.stringify({
  units: manifest.units,
  states: manifest.states,
  edges: manifest.edges,
  bindings: manifest.bindings
})))).toHaveSize(1);
```

Also assert the copied source hash, 311 access units per asset, native 1280×720 renditions, exact encoding policies, report byte counts matching `stat`, and no warnings.

- [ ] **Step 2: Confirm the test fails because the bundle is absent**

Run:

```sh
npx vitest run --config vitest.m9.config.ts tests/grass-rabbit-codecs/grass-rabbit-codecs.spec.ts
```

Expected: failure reading `public/grass-rabbit/build.json`.

- [ ] **Step 3: Compile the exact graph into all codecs**

Run:

```sh
npm run compile:grass-rabbit-codecs
```

Expected: one atomic directory containing four `.avl` files and `build.json`; compilation may run for several minutes because AV1 CPU-used 0 and x264/x265 veryslow are intentional.

- [ ] **Step 4: Run artifact assertions**

Run the focused Vitest command again and expect all artifact/graph/size assertions to pass.

### Task 3: Build the accessible tabbed comparison UI

**Files:**
- Create: `examples/grass-rabbit-codecs/index.html`
- Create: `examples/grass-rabbit-codecs/main.js`
- Create: `examples/grass-rabbit-codecs/style.css`

- [ ] **Step 1: Add real tab semantics and stable panels**

Create four `<button role="tab">` controls with `aria-controls`, one selected tab, roving `tabindex`, and four corresponding `<section role="tabpanel">` elements. Each panel contains a fixed-aspect player mount, support message, state badge, exact-size fields, encoding fields, compiler command, and FFmpeg-style equivalent. Panels not selected must use `hidden` and `inert` so their controls cannot receive focus.

- [ ] **Step 2: Parse `build.json` as the only metadata authority**

Validate `reportVersion`, four unique assets, four matching encodings, exact paths, positive byte sizes, codec strings, MIME types, and integrity strings. Render sizes from `asset.bytes`:

```js
function formatBytes(bytes) {
  const mib = bytes / (1024 * 1024);
  return `${mib.toFixed(2)} MiB · ${bytes.toLocaleString("en-US")} bytes`;
}
```

- [ ] **Step 3: Probe support outside the runtime**

Sequentially call the runtime-owned worker probe using the exact config:

```js
const config = {
  codec: asset.codecString,
  codedWidth: encoding.renditions[0].width,
  codedHeight: encoding.renditions[0].height,
  displayAspectWidth: 1280,
  displayAspectHeight: 720,
  colorSpace: {
    primaries: "bt709",
    transfer: "bt709",
    matrix: "bt709",
    fullRange: false
  }
};
```

Map `false` to `unsupported`; map a thrown probe to `unavailable`; always dispose the probe in `finally`. Unsupported selection must show “This codec is not supported in your browser.” and must not create `<aval-player>`.

- [ ] **Step 4: Mount exactly one supported codec source**

On supported activation, remove the prior player and create:

```html
<aval-player width="640" height="360" tabindex="0" aria-label="Interactive grass rabbit encoded with AV1">
  <source
    src="/grass-rabbit/av1.avl"
    type='application/vnd.aval; codecs="av01..."'
    integrity="sha256-...">
</aval-player>
```

Use the selected report asset values rather than hardcoded codec strings. Guard asynchronous prepare results with an activation serial so rapid tab changes are latest-wins and disconnected players cannot mutate the new panel.

- [ ] **Step 5: Preserve all rabbit interactions**

Reuse the original behavior: trace the one-shot `intro`, then display `idle`; pointer or focus engagement must traverse `entering → hover`; disengagement must traverse `exiting → idle`; early leave must finish `hover-in`, skip `hover-loop`, and play `hover-out`. Recreate the hotspot for each mounted player and keep reduced-motion behavior.

- [ ] **Step 6: Render honest compiler information**

Show `avl compile motion.json --out public/grass-rabbit --force`, the full encoding object from `build.json`, and a readable FFmpeg-style equivalent generated per codec. Label it explicitly as per-unit equivalent because FFmpeg writes elementary unit payloads and the AVAL compiler packages the final `.avl`.

### Task 4: Add cross-browser and graph behavior tests

**Files:**
- Create: `playwright.grass-rabbit-codecs.config.ts`
- Test: `tests/grass-rabbit-codecs/grass-rabbit-codecs.spec.ts`

- [ ] **Step 1: Configure Chromium and WebKit**

Use one worker, a 1280×900 viewport, DPR 2, and projects based on bundled Chromium plus `devices["Desktop Safari"]` for WebKit. Keep codec expectations capability-driven.

- [ ] **Step 2: Test tab accessibility and example-owned errors**

Assert exactly one selected tab, linked panels, roving focus with Left/Right/Home/End, Enter/Space activation, one visible panel, and no player in an unsupported panel. Assert the exact unsupported message and no runtime `error` event for that path.

- [ ] **Step 3: Exercise every supported codec**

For each tab whose exact support probe returns supported:

```ts
await expect.poll(() => player.evaluate((node) => node.readiness))
  .toBe("interactiveReady");
await expect.poll(() => currentUnit(player)).toBe("intro");
await expect.poll(() => currentVisualState(player)).toBe("idle");
await player.hover();
await expect.poll(() => currentVisualState(player)).toBe("entering");
await expect.poll(() => currentVisualState(player)).toBe("hover");
await page.mouse.move(4, 4);
await expect.poll(() => currentVisualState(player)).toBe("exiting");
await expect.poll(() => currentVisualState(player)).toBe("idle");
```

Assert selected codec family, `lastFailure: null`, no added underflow, no console errors, and cleanup after changing tabs.

- [ ] **Step 4: Exercise the authored early-leave edge**

For each supported codec, enter during/after intro, leave while `hover-in` is in progress, and inspect runtime trace to assert every `hover-in` frame, zero `hover-loop` frames, and every `hover-out` frame.

- [ ] **Step 5: Run both engines**

Run:

```sh
npm run test:grass-rabbit-codecs
```

Expected: Chromium and WebKit pass; unsupported codecs pass through the example-owned error branch rather than the runtime.

### Task 5: Document and visually verify the example

**Files:**
- Create: `examples/grass-rabbit-codecs/README.md`

- [ ] **Step 1: Document source, graph, encodings, and support behavior**

Include the source SHA-256, exact five ranges, four encoding policies, compile/run/test commands, explanation that CRF values are not cross-codec quality equivalents, and the difference between a deterministic unsupported result and a runtime failure.

- [ ] **Step 2: Build the example**

Run:

```sh
npm run build -w @pixel-point/aval-grass-rabbit-codecs-example
```

Expected: Vite production build succeeds with no missing assets.

- [ ] **Step 3: Perform headed browser verification**

Use the Playwright CLI to open the local example, snapshot before each interaction, activate every tab, capture a screenshot under `output/playwright/`, and inspect console output. Then use actual macOS Safari for an exploratory pass, explicitly distinguishing it from automated WebKit evidence.

- [ ] **Step 4: Final repository checks**

Run focused artifact tests, both browser projects, relevant workspace typechecks/build, `git diff --check`, and ensure only the requested long-running example server remains active.

## Self-review

- Spec coverage: separate example, exact source, four `.avl` files, compilation parameters, exact output sizes, all rabbit states/triggers, tabs, Chrome, Safari/WebKit, and example-owned unsupported errors are each mapped to a task.
- Placeholder scan: no TBD/TODO/similar-step placeholders remain.
- Type consistency: codec keys are `av1 | vp9 | h265 | h264`; report asset and encoding lookup share those keys; support states are `supported | unsupported | unavailable`; panels and tabs share codec-derived IDs.
- Git commits are intentionally omitted because the user requested implementation but did not authorize committing.
