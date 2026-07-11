# M2 Resident Reversible Interaction Implementation Plan

**Date:** 2026-07-11

**Design:** [M2 Resident Reversible Interaction Design](../specs/2026-07-11-m2-resident-reversible-interaction-design.md)

## 1. Outcome

Add an isolated browser vertical slice that uploads a reversible clip and both
endpoint runways into a bounded WebGL2 texture array, reverses the active clip
on the next content tick, and proves that the sole forward decoder recovers the
selected body before its cached runway expires.

M1 stays unchanged. M2 exposes internal diagnostics only; M3 will replace the
private follow-on seam with the deterministic user-defined graph.

## 2. Execution Order

### Task 1: Freeze and test the resident layout

Create:

- `packages/player-web/src/experimental/resident-frame-plan.ts`
- `packages/player-web/src/experimental/resident-frame-plan.test.ts`

Implement checked RGBA byte arithmetic, semantic frame-key deduplication,
stable logical-frame-to-layer lookup, clip/runway validation, device layer and
dimension constraints, 24 MiB clip, 48 MiB resident-edge, and 64 MiB tracked
player caps. Test exact-limit and one-over-limit cases before any renderer is
involved.

### Task 2: Build the pure reversible controller

Create:

- `packages/player-web/src/experimental/reversible-clip-controller.ts`
- `packages/player-web/src/experimental/reversible-clip-controller.test.ts`

Use explicit `request()` and `tick()` calls with opaque endpoint identifiers.
Implement portal waiting/cancellation, forward and reverse cursors, first/last
frame edge cases, visual commit at runway frame zero, same-tick coalescing,
duplicate intent, one validated opaque follow-on, and immutable trace records.
Add seeded rapid-input property tests with at least 10,000 operations.

### Task 3: Add the generation-aware sequential path decoder

Create:

- `packages/player-web/src/experimental/continuous-path-decoder.ts`
- `packages/player-web/src/experimental/continuous-path-decoder.test.ts`

Keep one decoder configuration across compatible units. Tag submissions with
unit, local frame, purpose, and path generation. Maintain monotonic decoder
timestamps independently from presentation ticks. Bound the submitted horizon,
close stale-generation outputs, skip cached runway duplicates, expose streamed
continuation frames, and publish exact configure/reset/flush/frame ownership
counters. Unit fakes cover route changes, stale output, fatal cleanup, and
idempotent disposal.

### Task 4: Implement the WebGL2 frame renderer

Create:

- `packages/player-web/src/experimental/webgl-frame-renderer.ts`
- `packages/player-web/src/experimental/webgl-frame-renderer.test.ts`

Separate a small GL backend interface from ownership logic so unit tests can
prove allocation, upload order, staging-buffer reuse, partial failure cleanup,
generation invalidation, and idempotent disposal. The browser backend allocates
one immutable `RGBA8` `TEXTURE_2D_ARRAY`, copies each borrowed `VideoFrame` into
one tightly packed RGBA buffer, uploads with `texSubImage3D`, and renders a
resident layer or bounded streaming slot with a full-screen triangle.

### Task 5: Compose the resident reversible player

Create:

- `packages/player-web/src/experimental/resident-reversible-player.ts`
- `packages/player-web/src/experimental/resident-reversible-player.test.ts`

Coordinate controller ticks, decoder generations, renderer handles, and the
rational clock. Begin endpoint recovery when the clip starts, discard obsolete
continuation generations on reversal, use cached runway frames until streamed
frame `R` is ready, and hold the last correct frame on a runtime miss. Reuse
M1's desired-running and lifecycle-generation patterns. Freeze on pause, hide,
context loss, and rebuild; never replay missed wall time.

### Task 6: Add the real browser fixture and playground

Create or update:

- `apps/playground/src/spike/create-synthetic-reversible.ts`
- `apps/playground/src/main.ts`
- `apps/playground/src/style.css`
- `packages/player-web/src/index.ts`

Select one codec once and encode compatible source-body, reversible-clip, and
target-body units with unit-plus-frame tags. Decode resident frames during
preparation, upload them, close their `VideoFrame`s, then run the interactive
path with one decoder. Add a hover/focus engagement card, manual endpoint
controls, phase/direction/memory/recovery diagnostics, and an accelerated
reversal action.

### Task 7: Prove M2 in Chromium

Create:

- `tests/browser/m2-resident-reversal.spec.ts`
- `docs/evidence/2026-07-11-m2-resident-reversal.md`

Use real WebGL2 and real `VideoFrame` upload. Assert persistent layer readback
after source-frame closure, interior/first/last active reversal semantics,
1,000 accelerated cached direction changes, both endpoint runway recoveries,
one decoder, zero runtime reset/flush, zero underflows in passing fixtures, real
`WEBGL_lose_context` rebuild, hide/rebuild/dispose cleanup, and no console or
page errors. Report canvas/GPU correctness separately from physical scan-out.

## 3. Verification Commands

Run after each task's focused tests and again at the milestone gate:

```bash
npm run typecheck
npm run test:unit
npm run build
npm run test:browser
npm audit --audit-level=high
git diff --check
```

Start the playground and inspect it in a real Chromium session. Verify that
hover/focus reversal, diagnostics, context recovery, responsive layout, and the
browser console all behave correctly before recording evidence.

## 4. Commit Boundary

Commit runtime code only when all M1 regressions and M2 gates pass together.
The milestone evidence must state the exercised codec, WebGL renderer limits,
resident and tracked bytes, runway length, measured recovery frames, reversal
count, lifecycle counters, browser version, OS, and the exact claim boundary.
