# AVAL Flutter Port — Master Architecture Plan

**v2 — Rust decode core.** This revision replaces the v1 decode strategy
(FFI to `libavcodec`, with VideoToolbox/MediaCodec as fallback) with a
Rust decode core (crate `aval_decode`, using the BSD-licensed `openh264`
decoder) as the primary strategy, compiled natively for iOS/Android/macOS/
Windows/Linux and to WASM for Flutter Web. See §2 (decode strategy), the
new §3.3 (YUV pixel-format consequence for the renderer), §4 (concurrency
— Rust-owned thread pool instead of a hand-rolled Dart isolate protocol),
§6 (package layout — new `flutter/rust/aval_decode` crate), §7 (Phase 3
now targets Rust/openh264, with a new Phase 3b WASM spike), and §8 (risk
register additions/updates for openh264, WASM build maturity, and the new
YUV→RGB conversion step). All other sections are unchanged from v1.

Status: design document, no Dart implementation code included.
Scope: produce a production-grade Flutter port of the AVAL web player
(`packages/player-web`, `packages/element`) with 100% behavioral parity,
validated against `examples/grass-rabbit`.

This document is the contract subsequent implementation sessions execute
against. It cites real file paths, type names, and line counts from the
TypeScript sources so that porting decisions can be checked against the
original rather than re-derived from memory.

Sources analyzed (see per-section citations):
- `packages/player-web/src` — 63,969 LOC non-test (99,115 incl. tests), 195 files
- `packages/element/src` — 7,952 LOC non-test
- `packages/graph/src` — 3,437 LOC (pure state-graph engine, ported separately as `aval_graph`)
- `packages/format/src` — 11,077 LOC (pure container/AVC/PNG codec, ported separately as `aval_format`)
- `docs/format/0.1.md`, `docs/superpowers/specs/*`, `examples/grass-rabbit/*`
- `flutter/packages/aval_graph`, `flutter/packages/aval_format` — existing scaffolds (see §6)

---

## 1. Runtime Anatomy of the Web Player

### 1.1 Module graph

```
packages/graph        (pure)          @pixel-point/aval-graph
        │  MotionGraphEngine, portal-search, route-plan, model.ts
        ▼
packages/format        (pure)         @pixel-point/aval-format
        │  container parser, avc/ (Annex-B, SPS/PPS, inspector), png/ (strict decoder)
        ▼
packages/player-web/src/decoder-worker  (thin platform shim over pure core)
        │  protocol.ts, frame-credit-ledger.ts, core.ts, client.ts, sample-sequence.ts
        │  ── Worker boundary ──
        ▼
packages/player-web/src/runtime        (the bulk of the system, mostly pure)
        │  path-scheduler*, decode-timeline, edge-lead, rational-time, submission-horizon
        │  model.ts, motion-policy, cut-presentation-coordinator, reversible-presentation
        │  frame-renderer(.ts) + frame-renderer-browser.ts (WebGL2), presentation-ring/-geometry
        │  asset-catalog, avc-candidate-factory, verified-blob-store, page-resource-manager
        │  integrated-player.ts (facade over ~15 collaborators)
        ▼
packages/element/src                   (DOM custom element)
        │  aval-element.ts, element-reconciler.ts, engagement-controller.ts,
        │  shadow-layers.ts, diagnostics.ts, public-types.ts
        ▼
examples/grass-rabbit/main.js          (reference consumer)
```

`packages/graph` is the deterministic reducer that decides **what** state to
be in and **when** a transition is logically due (portal/finish/cut/reversal),
with zero DOM/codec/GL awareness — `MotionGraphEngine.request/send/tick`
return plain `MotionGraphResult { presentation, effects[], snapshot }` values.
`packages/player-web/src/runtime` consumes those results and decides **how**
to make pixels appear for them (decode-ahead, GPU compositing, resource
budgets). `packages/element` is the thinnest layer: DOM attribute
reflection, event dispatch, and desired/current-state reconciliation.

### 1.2 LOC buckets (pure logic vs. platform-bound)

Based on full reads of the decoder-worker, path-scheduler, renderer, and
element subsystems, plus directory-wide `wc -l`:

| Bucket | Approx. LOC | Files (representative) | Portability |
|---|---|---|---|
| **A. Pure state-machine / algorithmic logic** | ~45,000–48,000 | `path-scheduler*.ts` (3,080), `decode-timeline.ts`, `edge-lead.ts`, `rational-time.ts`, `submission-horizon.ts` (599), `model.ts` (647), `motion-policy.ts`, `reversible-presentation.ts`, `cut-presentation-coordinator.ts` (946), `readiness-evaluator.ts`, `presentation-geometry.ts`, `presentation-ring.ts` (485), `frame-renderer.ts`'s orchestration shell (1,008, backend-agnostic), decoder-worker's `core.ts`/`client.ts`/`frame-credit-ledger.ts`/`sample-sequence.ts` (behind adapter interfaces), `integrated-player.ts` (1,029) and its ~15 collaborators, `packages/graph` (3,437), `packages/format` incl. `avc/` and `png/` (11,077) | Near-mechanical port to Dart |
| **B. Networking / fetch-bound** | ~8,000–9,000 | `range-asset-session.ts` (995), `verified-blob-store.ts` (967), `full-asset-fetch.ts` (615), `bounded-body-reader.ts` (711), `blob-assembly.ts`, `http-content-range.ts`, `http-entity-tag.ts`, `sha256-verifier.ts`, `load-watchdogs.ts` (719), `asset-catalog.ts` (743) | Moderate — rewrite against `dart:io`/`package:http` streaming + Range requests, algorithms port as-is |
| **C. GPU/WebGL2-bound** | ~1,000–1,500 | `frame-renderer-browser.ts` (905), `opaque-frame-renderer-browser.ts` (8, re-export shim), DOM-listener slice of `browser-context-recovery.ts` (469) | Hard — full rewrite as Flutter `FragmentProgram` (§3) |
| **D. WebCodecs/decoder-bound** | ~600–800 direct LOC, but unbounded architectural risk | `decoder-worker/entry.ts` (5), `factory.ts` (118), `host.ts` (98), `core.ts`'s default `VideoDecoder`/`EncodedVideoChunk` adapters (~50), `client-support.ts`'s frame wrapper (~80), `core-validation.ts`'s decoded-frame field reads (~100) | Hard — no Dart equivalent exists; needs new native decode engine (§2) |
| **E. Worker/threading plumbing** | ~250 | `factory.ts`, `host.ts`, `entry.ts`, `protocol.ts` message shapes | Maps to Dart isolates (§4) |
| **F. DOM/custom-element-bound** | ~2,000 of the element package's 7,952 | `shadow-layers.ts`, `shadow-style.ts`, `dom-event-bridge.ts`, `interaction-target.ts`, `automatic-inputs.ts`, `document-visibility-broker.ts`, `dpr-broker.ts`, `motion-preference-broker.ts`, `presentation-observer.ts` | Replace with Flutter widgets/gestures (§5); the remaining ~6,000 LOC (`element-desired-state.ts`, `element-current-predicates.ts`, `element-reconciler.ts`, `diagnostics.ts`, `public-types.ts`, error taxonomy) is pure reducer logic |
| `packages/player-web/src/experimental` | 5,820 | continuous-loop-decoder, resident-* prototypes, `webgl-frame-renderer.ts` | **Excluded from port** — superseded prototypes, not consumed by `integrated-player.ts`; skip unless a specific module is later found load-bearing |

**Headline number: of the ~63,969 non-test LOC in `player-web` + the
7,952 in `element`, roughly 85–90% is pure TypeScript logic with no
browser-API dependency, already isolated behind a small number of adapter
interfaces** (`PathSchedulerWorkerAdapter`, `ManagedDecoderWorkerFrame`,
`FrameRendererBackend`, `DecoderWorkerClientPort`/`MessagePort`,
`WorkerVideoDecoderAdapter`, `CutPresentationRenderer`). This is the single
most important architectural fact for the port: the codebase was already
built adapter-first, so the Dart port can preserve almost the entire
class/module structure and only needs new implementations of ~7 narrow
interfaces against isolates/FFI/platform-channels/FragmentProgram.

---

## 2. Flutter Decode Strategy

### Requirement recap
AVAL needs **frame-accurate decode of arbitrary AVC access-unit ranges from
a custom container** (the `.avl` format, `docs/format/0.1.md` §6), driven
by a frame-credit backpressure protocol (`decoder-worker/frame-credit-ledger.ts`),
feeding a continuous monotonic decode timeline even across seekless loops
(`decode-timeline.ts`). This is **not** "play an mp4" — there is no
`AVAssetReader`/`MediaExtractor`-friendly file on disk; the runtime hands
individual access units (`DecoderWorkerSample { unitId, unitFrame, type:
"key"|"delta", data: ArrayBuffer }`) to the decoder one batch at a time and
expects RGBA frames back with strict FIFO/ordinal contiguity
(`presentation-ring.ts`'s underflow checks). `video_player` and any
MediaSource/HLS-oriented plugin are structurally unable to do this — they
own the demux/seek model; AVAL owns it and needs raw decoder access.

The content itself is deliberately narrow: **Constrained Baseline AVC
(`avc1.42E020`, level 3.2), no B-frames, one reference frame, closed GOP per
unit** (`docs/superpowers/specs/2026-07-11-m5-opaque-avc-compiler-worker-design.md`).
This materially reduces decode-engine risk versus "general H.264."

### (a) Rust decode core (`aval_decode` crate, `openh264`) — **PRIMARY (v2)**
A single Rust crate, `aval_decode` (location: `flutter/rust/aval_decode`,
§6), wraps the `openh264` crate — a safe Rust binding to Cisco's
**BSD-2-Clause-licensed** OpenH264 decoder — and exposes a small,
protocol-shaped API (`configure`, `submit_access_unit`, `take_frame`,
`release_frame`, `dispose`) that is a near-1:1 port of
`decoder-worker/core.ts` + `frame-credit-ledger.ts`, just running in Rust
instead of a JS Worker. This crate compiles to:
- native `cdylib`/staticlib per target triple for iOS, Android, macOS,
  Windows, Linux (via `flutter_rust_bridge` + `cargokit`, or plain
  `cbindgen`-generated C headers + `dart:ffi`), and
- **WASM** (`wasm32-unknown-unknown`, via `flutter_rust_bridge`'s web
  codegen, which emits `wasm-bindgen` glue) for Flutter Web — the same
  Rust source, one build matrix, satisfying the directive that "Flutter
  web can run the same Rust core compiled to WASM."

**Profile coverage check**: AVAL's format requires exactly Constrained
Baseline AVC, `avc1.42E020`, level 3.2, no B-frames, one reference frame,
closed GOP per unit (`docs/superpowers/specs/2026-07-11-m5-opaque-avc-compiler-worker-design.md`).
OpenH264 was built by Cisco specifically around Constrained Baseline
Profile (its *encoder* is CBP-only; WebRTC/Chrome uses it precisely for
CBP interop), and its *decoder* fully implements Baseline-profile syntax —
this is a clean, complete match with no missing syntax elements. Because
AVAL's units carry **no B-frames and a single reference frame**, decode
order equals display order — `Decoder::decode(&mut self, packet: &[u8])`
returns the decoded picture (or `None` while priming) synchronously per
submitted access unit, with **no internal reordering buffer**, which maps
even more directly onto "submit one AU, get one frame" than WebCodecs'
async-callback model did.

- **Frame accuracy**: exact, same reasoning as v1's ffmpeg option — one
  access unit from the `.avl` index maps to exactly one `decode()` call, no
  seeking.
- **Decode-ahead control**: full — the ported `FrameCreditLedger` now runs
  *inside Rust*, gating how many access units are outstanding before
  `submit_access_unit` is called again, identical semantics to
  `hasSubmissionCredit`.
- **Licensing**: OpenH264's source is BSD-2-Clause (no GPL/LGPL exposure at
  all, resolving v1's biggest packaging risk outright — see Risk §8.2's
  updated status). One nuance to document for legal review: Cisco's
  *prebuilt* binary distribution carries MPEG-LA patent-royalty coverage
  for redistributors; a from-source build (as this crate does, cross-compiled
  per target) does not automatically carry that coverage, so patent
  licensing should be confirmed with counsel independent of the (clean)
  copyright licensing.
- **Binary size**: OpenH264 is small relative to a full ffmpeg build,
  materially better for a WASM bundle's download-size budget.
- **All-platform + web coverage**: one Rust codebase across all six
  targets (5 native + web), the strongest "one engine, one behavior"
  story of any option evaluated, and it directly satisfies the new
  Rust/WASM directive.

**Pixel-format consequence** (new vs. v1): OpenH264 decodes to planar
**I420 (YUV 4:2:0)**, not RGBA — WebCodecs' `VideoFrame` did the YUV→RGB
conversion invisibly before this codebase's renderer ever saw a pixel.
With a Rust core, that conversion must now be designed explicitly. See
§3.3.

**Isolate/thread boundary** (new vs. v1, see §4 for full detail): decode
no longer runs in a Dart `Isolate` running a hand-rolled worker protocol —
it runs on a **Rust-owned thread** (or thread pool), because
`flutter_rust_bridge`'s generated async bindings already dispatch blocking
Rust calls off the Dart UI thread automatically. Only Annex-B access-unit
bytes cross the FFI boundary inbound, and decoded frame planes cross it
outbound as Rust-owned buffers exposed to Dart as **external typed
data** (zero-copy `Uint8List` views backed by a `NativeFinalizer` that
frees the Rust allocation once Dart is done with it) — no manual
`Isolate.spawn`/`SendPort`/`TransferableTypedData` plumbing is needed the
way v1 assumed for a from-scratch Worker-protocol port (that plumbing is
now internal to `flutter_rust_bridge`, not hand-written).

### (b) FFI to ffmpeg/libav via `package:ffi` — demoted to alternative
Still architecturally sound (as detailed in v1), but no longer recommended
as primary now that (a) exists: ffmpeg/libavcodec is a much larger
dependency (worse for WASM bundle size), carries GPL/LGPL build-config
risk that openh264 simply doesn't have, and offers no decode-quality or
frame-accuracy advantage for Constrained-Baseline-only content. Retain as
a documented alternative only if a future rendition profile needs decoder
features OpenH264 doesn't cover (e.g. a hypothetical higher-profile
rendition) — not needed for AVAL's current format.

### (c) Platform channels to AVFoundation/VideoToolbox (iOS/macOS) + MediaCodec (Android) — optional efficiency backend
v1 kept this as a *fallback* motivated by ffmpeg's licensing/packaging
risk; with (a) resolving that risk via a BSD-licensed decoder, this option
is **no longer necessary as a hedge** — but it remains worth keeping as an
**optional, opt-in high-efficiency backend** for a different reason:
OpenH264 is a **software** decoder with no dedicated video-decode silicon
path, so for AVAL's actual usage pattern (small, often long-running hover/
idle loops) a hardware decoder is meaningfully better for battery/thermal
on mobile, even though OpenH264 is plenty fast for correctness and even
modest real-time margins. Recommendation: ship OpenH264 as the default on
all platforms for v1 parity work, and treat a VideoToolbox/MediaCodec
backend behind the same `DecoderAdapter` interface as a **post-parity
efficiency optimization**, selectable per build or per device-capability
probe, not a day-one requirement. Windows/Linux still have no equivalent
first-party surface, so this was never going to be a five-platform
solution on its own.

### (d) `media_kit`/libmpv — still rejected
Unchanged from v1: `media_kit` wraps `libmpv`, a general-purpose *player*
abstraction (open a URL/file, seek, get position), not a transactional
"decode this exact access unit, hold credit, return exactly this frame"
surface. Useful only as a reference for FFI/native-library packaging
patterns; never as the production decode engine.

### (e) Pure-Dart H.264 decode — still rejected
Unchanged from v1: a spec-compliant software H.264 decoder in Dart is a
multi-thousand-hour effort with no hardware acceleration, unable to
sustain real-time decode-ahead on mobile CPUs. Firmly rejected regardless
of decode-engine language choice elsewhere.

### Recommendation (v2)
**Primary: a single Rust crate (`aval_decode`) wrapping `openh264`**,
compiled natively for iOS/Android/macOS/Windows/Linux via
`flutter_rust_bridge`/`cargokit`, and to WASM for Flutter Web via
`flutter_rust_bridge`'s web codegen (`wasm-bindgen`). This resolves v1's
licensing risk outright (BSD vs. GPL/LGPL), gives one engine and one
behavior across all six targets including web, and is a clean profile
match for AVAL's Constrained-Baseline-only content.

**Web decode backend — a deliberate choice, not automatic**: Flutter Web
runs inside a real browser that already has hardware-accelerated
WebCodecs available. Two viable configurations:
- **Default/recommended: `VideoDecoder`/`EncodedVideoChunk` via
  `dart:js_interop`** — hardware-accelerated, zero new WASM-toolchain risk,
  and literally the reference implementation this whole port is validated
  against. Port the decoder-worker's WebCodecs adapter near-verbatim
  behind `dart:js_interop` rather than recompiling a software decoder to
  WASM to redo work the browser already does natively and faster.
- **Optional fallback: the same `aval_decode` Rust core compiled to WASM**
  — satisfies "one identical decode core everywhere," useful if a
  deployment needs pixel-identical output across native and web for a
  certification pipeline, or must support browsers/embeddings without
  WebCodecs. Treat `openh264-sys2`'s `wasm32` C-toolchain build path as
  **unvalidated until the Phase 3b spike** (§7) — WASM builds of OpenH264
  exist in the wider ecosystem (e.g. WebCodecs polyfills), but the Rust
  crate's own `wasm32` target support has not been confirmed against this
  project's toolchain and should not be assumed solved.

Ship WebCodecs-via-interop as the default web backend; keep the
WASM-compiled Rust core as a documented, spiked-and-validated optional
path. **Fallback/alternative for native: ffmpeg FFI (b)** if a future
profile needs it. **Optional efficiency backend: VideoToolbox/MediaCodec
(c)**, post-parity. **Reject pure-Dart decode (e) and `media_kit` (d) as
the primary engine**, unchanged from v1.

---

## 3. Rendering Strategy

### 3.1 The web renderer, verbatim

The WebGL2 packed-alpha compositor lives entirely in
`packages/player-web/src/runtime/frame-renderer-browser.ts` (905 lines);
`frame-renderer.ts` (1,008 lines) is a platform-neutral orchestration shell
around an injected `FrameRendererBackend` interface
(`allocate/upload/uploadFrame?/draw/readPixels?/dispose`), and
`opaque-frame-renderer.ts`/`opaque-frame-renderer-browser.ts` are literal
`@deprecated` re-export shims — **there is exactly one renderer
implementation**; "opaque" vs. "packed-alpha" is a data-driven branch
(`u_has_alpha`), not a second code path.

**Vertex shader** (full-screen triangle, no VBO):
```glsl
#version 300 es
precision highp float;
const vec2 positions[3] = vec2[](
  vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0)
);
void main() {
  vec2 position = positions[gl_VertexID];
  gl_Position = vec4(position, 0.0, 1.0);
}
```

**Fragment shader** (`FRAME_FRAGMENT_SHADER_SOURCE`):
```glsl
#version 300 es
precision highp float;
precision highp sampler2DArray;
uniform sampler2DArray u_frames;
uniform float u_layer;
uniform vec4 u_color_uv;
uniform vec4 u_alpha_uv;
uniform vec4 u_output_rect;
uniform float u_has_alpha;
out vec4 out_color;
void main() {
  vec2 output_index = gl_FragCoord.xy - u_output_rect.xy - vec2(0.5);
  vec2 output_span = max(u_output_rect.zw - vec2(1.0), vec2(1.0));
  vec2 sample_uv = output_index / output_span;
  sample_uv.y = 1.0 - sample_uv.y;
  if (u_output_rect.z <= 1.0) sample_uv.x = 0.5;
  if (u_output_rect.w <= 1.0) sample_uv.y = 0.5;
  sample_uv = clamp(sample_uv, vec2(0.0), vec2(1.0));
  vec2 color_uv = u_color_uv.xy + sample_uv * u_color_uv.zw;
  vec3 color = texture(u_frames, vec3(color_uv, u_layer)).rgb;
  float alpha = 1.0;
  if (u_has_alpha > 0.5) {
    vec2 alpha_uv = u_alpha_uv.xy + sample_uv * u_alpha_uv.zw;
    alpha = clamp(texture(u_frames, vec3(alpha_uv, u_layer)).r, 0.0, 1.0);
  }
  out_color = vec4(color * alpha, alpha);
}
```

**Packing layout — vertical stacking, one decoded picture.** Derived in
`packages/format/src/avc/rendition-geometry.ts`
(`deriveAvcRenditionGeometryFromVisibleAtPath`): color occupies the top
pane (`visibleColorRect = [0,0,w,h]`), an 8px neutral gutter follows
(`PACKED_ALPHA_GUTTER = 8`), then the alpha pane sits directly below
(`visibleAlphaRect = [0, paneHeight+8, w, h]`), stored as luma broadcast
into RGB (shader reads only `.r`). Total decoded canvas height =
`2*paneHeight + 8`, padded to a multiple of 16 (`align16`). Color and alpha
are **guaranteed frame-synchronous because they occupy one AVC picture** —
this is the M6 design's core invariant ("color and alpha cannot drift
because they occupy one decoded picture"), eliminating dual-decoder sync
entirely.

Fragment-shader logic, step by step: (1) convert `gl_FragCoord` into a
normalized 0..1 index within the drawn output rect (supports letterboxed
sub-rect draws with one draw call); (2) flip V (texture-space vs. top-down
frame convention); (3) clamp degenerate 1px spans to texel center; (4)
affine-remap the same normalized coordinate into two different UV
sub-rects of the *same* texture layer — one for color, one for alpha
(precomputed CPU-side via texel-center-to-texel-center mapping in
`frame-renderer-validation.ts`'s `deriveUvTransform`); (5) sample color
`.rgb` (no YUV→RGB math in-shader — the browser's WebCodecs `VideoFrame` →
`texSubImage3D` fast path or `copyTo(..., {format:"RGBA"})` already
produced RGBA; BT.709 limited-range is asserted upstream, not converted
here); (6) sample alpha from the alpha pane's `.r` channel if
`u_has_alpha`, else hardcode `1.0`; (7) **premultiply in-shader**:
`out_color = vec4(color * alpha, alpha)`. GL state is
`blendFunc(ONE, ONE_MINUS_SRC_ALPHA)` with a `premultipliedAlpha: true`
context — standard premultiplied "over" compositing end to end.

Texture storage is `TEXTURE_2D_ARRAY` (`texStorage3D`, single mip, `LINEAR`
filter, `CLAMP_TO_EDGE`), split into a **resident** array (persistent
cached loop/portal/reversible frames) and a small **streaming** array
(`STREAMING_TEXTURE_LAYER_COUNT = 3` ring slots for fresh decode
continuation); `u_layer` selects which array layer to sample, `kind`
(`"resident"|"stream"`) selects which texture object is bound.

`presentation-geometry.ts`'s `computePresentationGeometry` (100% pure
arithmetic) implements exactly the CSS `object-fit` vocabulary
(`contain|cover|fill|none`) plus non-square-pixel handling and DPR-aware
backing-size clamping — this maps directly onto Flutter's `BoxFit` model
and is portable near-verbatim.

`browser-context-recovery.ts` treats a lost WebGL2 context as **terminal in
production** (`contextLossPolicy: "terminal"`) — it covers with the static
fallback and never attempts GPU recovery mid-session. Port this policy
as-is; do not build context-recovery machinery the web version itself
doesn't rely on.

### 3.2 Flutter rendering options evaluated

**Texture widget (platform `SurfaceTexture`/`IOSurface`/GL texture via
`TextureRegistry`)**: gives zero-copy GPU display, but the packed-alpha
unpack/premultiply math must run natively *before* the texture is
registered — i.e., duplicate the GLSL logic once per platform graphics API
(Metal for iOS/macOS, OpenGL ES/Vulkan for Android, D3D/ANGLE for
Windows). Fastest at steady state, highest implementation surface, and
risks the exact "shader drifts between platforms" failure mode the M6 spec
was designed to prevent for color/alpha sync.

**`dart:ui.Image` upload + `Canvas.drawImage`**: simplest, one Dart/C code
path, but requires the unpack+premultiply to happen on CPU (in the FFI
decode boundary, in C, immediately after `avcodec_receive_frame`) before
`ui.decodeImageFromPixels`/`ImmutableBuffer`. Wastes the GPU's shader ALU
and adds one CPU memory-bandwidth pass per frame; acceptable at 720p/24–60fps
on modern hardware but throws away the entire reason the web version does
this compositing on GPU.

**`FragmentProgram` (dart:ui `FragmentProgram`, `.frag` compiled to SkSL via
Impeller) driving a `CustomPainter`**: **recommended.** Upload the *raw*
packed decoded frame (one `ui.Image`, still vertically stacked
color/gutter/alpha, straight out of the decoder, no CPU compositing) and
run a fragment shader that is a near-verbatim transliteration of
`FRAME_FRAGMENT_SHADER_SOURCE`:
- Replace `gl_FragCoord` with the `FlutterFragCoord()` builtin.
- Drop `precision` qualifiers (not present in the Impeller GLSL-ES subset).
- `sampler2DArray` has **no Flutter/Impeller equivalent** — Impeller
  fragment shaders take a fixed, statically-declared set of `sampler2D`
  uniforms, no dynamic array indexing. Since color and alpha are already
  packed into **one** decoded picture per frame, this is not a blocker:
  the shader needs only **one** `sampler2D` per draw (the current frame's
  image) plus the same `u_color_uv`/`u_alpha_uv`/`u_output_rect`/`u_has_alpha`
  uniforms — the UV-remap-into-two-regions-of-one-texture logic ports
  unchanged.
- The web's resident/streaming **texture array layer** selection
  (`u_layer`) has no Impeller equivalent either — port it as: allocate N
  separate `ui.Image` objects (Flutter holds many `Image`s cheaply; no
  array-texture trick needed) and bind whichever `Image` is "the current
  layer" as the shader's sampler input for that draw call, rather than
  indexing a layer uniform. This is a clean 1:1 behavioral substitution,
  not a compromise — GPU texture arrays exist in WebGL primarily to allow
  one bind call to serve many logical frames; Flutter's per-draw image
  binding achieves the identical visible result with a different resource
  model.
- Blending: SkSL/Impeller's default `Paint.blendMode = BlendMode.srcOver`
  over a premultiplied-alpha destination is the direct analog of
  `blendFunc(ONE, ONE_MINUS_SRC_ALPHA)`; keep the shader's own
  `color * alpha` premultiply exactly as written so the two agree.

### 3.3 Pixel-format consequence of the Rust decode core (v2)

The v1 renderer design assumed an RGBA buffer arriving at the FFI/upload
boundary, because WebCodecs' `VideoFrame` performs YUV→RGB conversion
invisibly on the web side before this codebase's shader ever runs. The
`openh264`-based Rust core (§2(a)) decodes to **planar I420 (YUV 4:2:0)**
— one full-resolution Y (luma) plane and two quarter-resolution U/V
(chroma) planes — so the Flutter port must add an explicit conversion step
that has no analog in the original GLSL.

Two placements were evaluated:

- **GPU-side (in the `FragmentProgram` shader)**: bind the Y and U/V planes
  as separate `sampler2D` inputs, apply the standard BT.709 conversion
  matrix per-pixel (chroma upsampling comes "for free" via `LINEAR` texture
  filtering on the half-resolution U/V planes), then proceed with the same
  packed-alpha UV-remap/premultiply logic. Lower CPU cost, but it *extends*
  the shader beyond what was validated in v1 and introduces new surface
  (colorspace-matrix correctness, chroma-siting/upsampling choices) right
  where the M6 spec's tightest quality gate (mean alpha error ≤2/255, p99
  ≤8/255) lives.
- **CPU-side (in Rust, immediately after `decode()`, before crossing FFI)**:
  convert I420→RGBA in Rust (SIMD-accelerated — e.g. a hand-rolled NEON/
  AVX2 kernel or a small crate such as `yuvutils-rs`) so the buffer
  crossing the FFI boundary is shape-identical to what WebCodecs produced
  in v1. **Recommended.** This keeps the Flutter `FragmentProgram` an
  *unchanged* transliteration of `FRAME_FRAGMENT_SHADER_SOURCE` (the
  already-analyzed, lower-risk piece from §3.2), at the cost of one CPU
  conversion pass per frame — comfortably inside budget at AVAL's typical
  resolutions (grass-rabbit is 1280×720) on every target platform,
  including WASM (where SIMD is available via the `wasm32` SIMD128
  target feature).

Treat GPU-side YUV conversion as a legitimate **future optimization** once
the CPU-conversion path is shipped and certified, not a v1-parity
requirement — minimizing new, unvalidated shader surface during the
initial port.

### Recommendation
Native/FFI decode produces a raw packed RGBA buffer per frame — with the
Rust core (§2(a)/§3.3), that means I420→RGBA conversion happens in Rust,
SIMD-accelerated, immediately after `openh264::Decoder::decode()` — then
that buffer is uploaded as one `ui.Image` per decoded frame (via
`ImmutableBuffer`/`ImageDescriptor`, zero *additional* CPU compositing) →
`CustomPainter` binds it into a `FragmentProgram` shader that is a direct
line-by-line port of the GLSL above. This preserves the exact per-pixel
math (UV remap, dual-region sampling, in-shader premultiply) that the M6
design doc's alpha-quality gate (mean error ≤2/255, p99 ≤8/255) was built
to protect, while replacing only the two constructs (`sampler2DArray`,
`gl_FragCoord`) that have no Impeller equivalent with behaviorally
identical Flutter-native substitutions.

---

## 4. Concurrency Model

### The web model
`decoder-worker/protocol.ts` defines a versioned, structured-clone-safe
message union (`DecoderWorkerCommand`/`DecoderWorkerEvent`) between main
thread and a dedicated `Worker`, transported through the minimal
`DecoderWorkerMessagePort`/`DecoderWorkerClientPort` interfaces
(`postMessage(message, transfer?)`, `addEventListener`) — **not** `Worker`/
`MessagePort` directly, which is exactly the seam a Dart port replaces.
`ArrayBuffer`s (access-unit bytes, command → worker) and `VideoFrame`s
(decoded output, worker → main) are transferred, not copied
(`postMessage(msg, [transferable])`).

`FrameCreditLedger` (`decoder-worker/frame-credit-ledger.ts`, 89 lines, zero
platform dependency) is the backpressure primitive: it tracks every
transferred `VideoFrame` as a `FrameLease {generation, decodedBytes}` keyed
by an incrementing `frameId`. `hasSubmissionCredit(submittedFrames, max)`
gates whether the worker may decode another chunk
(`submittedFrames + leases.size < maxOutstandingFrames`, ≤12 per
`DECODER_WORKER_HARD_LIMITS`); `lease()` additionally enforces a decoded-byte
budget. `release(frameId)` is called when the main thread finishes with (and
closes) a frame, replenishing credit. This is the sole flow-control
mechanism bounding in-flight decoded frames, independent of WebCodecs'
own internal `decodeQueueSize`.

### Rust-core concurrency model (v2, recommended)

With the Rust decode core (§2(a)), the decoder-worker's Worker/postMessage
protocol is superseded by `flutter_rust_bridge`'s own concurrency model
rather than hand-rolled onto a Dart `Isolate`:

| Web construct | Rust/Flutter equivalent (v2) |
|---|---|
| `Worker` (dedicated decoder worker) | A Rust-owned thread (or small thread pool) inside `aval_decode`, scheduled by `flutter_rust_bridge`'s generated async runtime — Dart calls an `async` FRB binding function, which the FRB runtime automatically dispatches off the Dart UI isolate onto a native thread; no manual `Isolate.spawn` needed for this purpose |
| `postMessage(msg, [transferable])` | A direct FRB-generated async function call (e.g. `await api.submitAccessUnit(handle, bytes, timestamp)`), or an FRB `StreamSink`-backed stream for push-style frame delivery |
| `addEventListener("message", ...)` | `Stream<FrameEvent>` returned by an FRB-generated streaming API (FRB v2 supports Rust→Dart streams natively) |
| `DecoderWorkerMessagePort`/`DecoderWorkerClientPort` interfaces | Not needed as hand-written seams — FRB generates the binding layer from `#[frb]`-annotated Rust functions; the *protocol shape* (configure/submit/take-frame/release/dispose) is still ported deliberately to match `protocol.ts`'s command/event vocabulary, just expressed as ordinary async Rust functions rather than a message union |
| Transferred `ArrayBuffer` (access-unit bytes, in) | A Dart `Uint8List` passed into the FRB call; FRB marshals it to Rust with as few copies as its codec allows (a `ZeroCopyBuffer`-style wrapper where supported) |
| Transferred `VideoFrame` (decoded output, out) | **Rust-owned buffer exposed as Dart external typed data**: the decoded (post-YUV→RGB, §3.3) RGBA buffer stays allocated in Rust; Dart receives a `Uint8List` view over that native memory (`Pointer<Uint8>.asTypedList(length)` or FRB's equivalent zero-copy wrapper) with a `NativeFinalizer` registered so the Rust allocation is freed automatically once the Dart-side `Uint8List`/`ui.Image` upload is done with it — no bytes are copied across the boundary, and lifetime is GC-safe rather than manually managed |
| `DecoderWorkerCommand`/`Event` unions | Ordinary Rust function signatures + an FRB-generated Dart API class; the command/event *vocabulary* (configure, activate-generation, submit, abort-generation, release-frame, snapshot, dispose) is preserved as the shape of that API, not reimplemented as a message-passing union |
| `FrameCreditLedger` | Ported to **Rust**, running inside `aval_decode` alongside the decoder itself — credit accounting now lives in the same language/runtime as the hot path it gates, eliminating one full cross-language round trip per credit check that a Dart-side ledger would have required |
| `AbortSignal`/`DOMException` (generation cancellation, `path-scheduler-generation.ts`) | A `CancellationToken`-equivalent still lives in the **Dart** `aval_player` package (it gates the pure-Dart path-scheduler, which is unaffected by the decode-engine language choice) and is threaded into FRB calls as a generation/epoch parameter the Rust side checks before acting — not itself ported into Rust |

For Flutter Web, the same `aval_decode` crate's FRB-generated **web**
bindings use `wasm-bindgen`/`dart:js_interop` under the hood instead of
`dart:ffi` — from the `aval_player`/`aval_flutter` call sites, the async
API surface is identical on native and web; only the binding
implementation differs, which is exactly the point of building on
`flutter_rust_bridge` rather than a bespoke per-target FFI layer. (If the
default WebCodecs-via-interop web backend from §2 is used instead, this
Rust-core concurrency section does not apply on web at all — see the
plain-FFI alternative below for that case's shape.)

### Alternative: plain-FFI Dart isolate mapping (if not using `flutter_rust_bridge`)

If the team instead chooses `cbindgen` + hand-written `dart:ffi` bindings
over `flutter_rust_bridge` (more control, more manual glue, no generated
async/stream layer), the v1-style explicit isolate protocol still applies
and should be built deliberately rather than assumed away:

| Web construct | Dart equivalent |
|---|---|
| `Worker` (dedicated decoder worker) | `Isolate` spawned via `Isolate.spawn`, making the FFI calls into `aval_decode`'s `cdylib` from within that isolate |
| `postMessage(msg, [transferable])` | `SendPort.send(msg)` |
| `addEventListener("message", ...)` | `ReceivePort.listen(...)` |
| Transferred `ArrayBuffer` (access-unit bytes) | `TransferableTypedData.fromList([bytes])` on the sending side, `.materialize()` on the receiving side |
| Transferred `VideoFrame` (decoded output) | Rust-owned buffer wrapped as external typed data (`NativeFinalizer`-backed `Uint8List`, as above), sent isolate-to-isolate via `TransferableTypedData` if a copy-free hop is needed, or read directly if the FFI calls already happen on the UI-adjacent isolate that owns the texture upload |
| `FrameCreditLedger` | Still best implemented in Rust (adjacent to the decoder) even in this configuration; the Dart isolate is a thin caller, not a reimplementation site |

Run FFI decode on a **dedicated `Isolate`**, never the UI isolate, in this
configuration — the point is identical to why the web uses a `Worker`:
keep heavy decode work off the thread that must hit 60fps compositing
deadlines. (Under the recommended `flutter_rust_bridge` configuration
above, this guarantee comes from FRB's own threading rather than a
manually spawned isolate.)

---

## 5. Widget API

### 5.1 Full public surface to mirror

From `packages/element/src/public-types.ts` / `element-public-events.ts`
(tag `aval-player`, API major version 1):

**Configuration** (constructor params / settable properties on
`AvalPlayerController`):
`src: String`, `integrity: String?` (`sha256-<base64>`), `crossOrigin`
(not meaningful in Flutter — replace with an HTTP-headers/auth callback,
see below), `motion: AvalMotion` (`auto|reduce|full`), `autoplay`
(`visible|manual`), `fit: AvalFit?` (`contain|cover|fill|none`),
`bindings` (`auto|none`), `state: String?` (declarative initial/target
state name), `interactionFor`/`interactionTarget` equivalent (a Flutter
`FocusNode`/`GlobalKey` naming the widget subtree that receives
engagement input, defaulting to the `AvalPlayer` widget itself), `width`/
`height`.

**Read-only staged state** (`ValueListenable`/getters on the controller):
`readiness`, `mode` (`animated|static|null`), `assurance`
(`"best-effort"|null`), `staticReason`, `requestedState`, `visualState`,
`isTransitioning`, `paused`, `effectivelyVisible`, `stateNames`,
`eventNames`, `inputBindings`.

**Methods** (mirror exactly):
```
Future<RuntimeReadinessResult> prepare({Duration? timeout, /* cancellation */});
Future<void> setState(String name);
bool send(String event);
bool readyFor(String state);
void pause();
Future<void> resume();
AvalDiagnostics getDiagnostics({bool trace = false});
Future<void> dispose();
```
Semantics carry over exactly: `setState()` returns the graph-authored
settlement future; `send()` is synchronous fire-and-forget (`true` only if
accepted); `state` remains declarative — calling `setState()` imperatively
does not rewrite the widget's `state` constructor argument (consistent with
Flutter's own "controller state can diverge from widget config" pattern).

**Events** (`Stream<T>` per event, or one discriminated `Stream<AvalEvent>`
— recommend per-event broadcast streams to match the DOM `addEventListener`
ergonomics developers coming from the web version will expect):
`readinesschange {generation, from, to, reason?}`,
`requestedstatechange {generation, from, to, sequence}`,
`visualstatechange {generation, from, to}`,
`transitionstart {generation, edge, from, to, sequence?}`,
`transitionend {generation, edge, from, to, sequence?}`,
`underflow {generation, incident, heldPresentationOrdinal, cumulativeCount}`,
`fallback {generation, reason, requestedState, visualState}`,
`error {generation, failure: AvalPublicFailure, fatal}`.
Every payload carries `generation` and must never leak source
URLs/tokens/bodies/ETags/credentials (same contract as the web docs).

### 5.2 Readiness lifecycle

Port `RuntimeReadiness` exactly: `unready → metadataReady → visualReady →
{interactiveReady | staticReady} → disposed | error` (terminal from any
phase). Port `element-public-state.ts`'s `stageReadiness` derivation rule
verbatim: on `interactiveReady`, `mode="animated"`,
`assurance="best-effort"`; on `staticReady`, `mode="static"` and
`staticReason` derives from (in order) explicit reason →
`motion=="reduce"` or (`motion=="auto"` && OS reduced-motion) →
not-effectively-visible → previous reason → `"readiness-failed"`.

### 5.3 Diagnostics API

Port `AvalDiagnostics` (`public-types.ts`) as an immutable Dart data class
with the same nested groups: `runtime{}` (selected rendition/profile,
transport mode, byte accounting, decoder-lease state, reclamation/context-loss
counters), `motion{}`, `playIntent{}`, `visibility{}`, `presentation{}` (fit,
CSS vs. backing size, effective DPR, clamp reasons), `counters`
(`AvalDiagnosticsCounters`), `cleanup`/`elementOwnership`/`terminalCleanup`
(port as-is — these are pure bookkeeping, valuable for leak detection in
Flutter too), and `elementTrace`/`runtimeTrace` (only populated when
`trace: true`, capped at 512 records). Diagnostics must remain a pure
read — never trigger fetch/retry/prepare/graph-advance as a side effect.

### 5.4 Engagement bindings

The web's `automatic-inputs.ts` listens to `pointerenter/pointerleave/
focusin/focusout/click` and explicitly **suppresses touch from hover
semantics** (`isTouchPointer` check on `PointerEvent.pointerType`), routing
touch taps to `click → activate` instead. **Flutter's `MouseRegion`
already implements this exact distinction natively** — `onEnter`/`onExit`
fire only for mouse-class pointers; touch does not generate hover events in
Flutter's gesture arena at all. This means the hard part of the web's
engagement logic (touch/hover disambiguation) is essentially free in
Flutter:

- `pointer.enter`/`pointer.leave` → `MouseRegion(onEnter, onExit)`.
- `focus.in`/`focus.out` → `Focus(onFocusChange: ...)` wrapping the
  interaction target subtree.
- `activate` (native `click`, which is also how the web handles touch taps)
  → `GestureDetector(onTap: ...)`.
- `engagement.on`/`engagement.off` → OR-aggregate of the above three (port
  `EngagementController.sample(pointer, focus)`'s edge-triggered emit logic
  verbatim — emit only on boolean transitions, not on every input event).
- `visible`/`hidden` bindings → Flutter `VisibilityDetector`-style
  intersection/`AppLifecycleState` observation, mirroring
  `document-visibility-broker.ts`/`presentation-observer.ts`.

**Proposed touch engagement mapping** (the web has no "hover" concept for
touch at all — it only maps taps to `activate`): default to the same
behavior for exact parity (`bindings="auto"` on touch = `activate` only,
no synthetic hover). Optionally expose a Flutter-only opt-in
`touchEngagementMode: none | tapToggle` where `tapToggle` maps a tap to
toggling `engagement.on`/`engagement.off` (useful for hover-only-authored
content on touch devices) — **default `none`** to keep byte-for-byte parity
with the web's documented behavior, and treat `tapToggle` as an explicitly
non-default, documented deviation.

### 5.5 Fallback / two-layer model

Port `shadow-layers.ts`'s invariant exactly: a persistent fallback/poster
layer beneath the animated layer, where the animated layer is **only ever
revealed after a first frame has actually been drawn**
(`markAnimatedDrawn` before `revealAnimated`, else throw) — in Flutter,
implement as a `Stack` with the poster `Image`/placeholder always mounted
underneath the `CustomPainter`-driven animated layer, gated by a
`ValueNotifier<bool> animatedDrawn` that the renderer sets exactly once per
generation after its first successful paint. Reduced-motion, fatal error,
and visibility-suspended all force the poster layer back to front,
mirroring `showFallbackAfterFatal`/`coverFallback`/`resetSource`.

---

## 6. Package Layout

```
flutter/
├── rust/
│   └── aval_decode/            (Rust crate, workspace member — NEW in v2)
│         Wraps the `openh264` crate (BSD-licensed H.264 decoder). Exposes
│         a small async API — configure/submit_access_unit/take_frame/
│         release_frame/dispose — that is a near-1:1 port of
│         decoder-worker/{protocol.ts, core.ts, frame-credit-ledger.ts,
│         sample-sequence.ts}, plus the I420→RGBA SIMD conversion step
│         (§3.3). Annotated with `#[frb]` for flutter_rust_bridge codegen.
│         Build targets: native cdylib/staticlib per platform triple
│         (iOS/Android/macOS/Windows/Linux) via cargokit, and wasm32 (via
│         flutter_rust_bridge's web codegen / wasm-bindgen) as an optional
│         web backend (§2). Depends on no other package in this tree — it
│         only needs raw Annex-B access-unit bytes in and SPS/PPS
│         parameters (extracted by aval_format) to configure the decoder.
│
└── packages/
    ├── aval_graph/              (pure Dart, no Flutter dep) — ported in parallel
    │     Deterministic state-graph reducer. Port of packages/graph/src:
    │     MotionGraphEngine, model.ts (GraphStateDefinition, GraphEdgeDefinition,
    │     GraphStartPolicy, GraphTransitionDefinition, GraphPresentation),
    │     portal-search.ts, route-plan.ts, intent-router.ts, engine-state.ts.
    │     Existing scaffold: pubspec.yaml, lib/src/errors.dart, lib/src/limits.dart.
    │
    ├── aval_format/             (pure Dart, depends on aval_graph) — ported in parallel
    │     Container parser + codec inspection. Port of packages/format/src:
    │     header.ts, layout.ts, access-unit-index.ts, sample-plan.ts, model.ts,
    │     manifest-*-schema.ts, reference-frame.ts,
    │     avc/ (annex-b.ts, inspector.ts, parameter-sets.ts, rendition-geometry.ts,
    │           canonicalize.ts, slice-header.ts, bit-reader.ts),
    │     png/ (strict decode.ts, deflate*, unfilter.ts, crc32.ts, chunks.ts).
    │     Existing scaffold: pubspec.yaml (depends on aval_graph via path),
    │     lib/src/errors.dart. lib/src/avc/ and lib/src/png/ are empty — full
    │     surface still to be ported.
    │
    ├── aval_player/             (pure Dart + dart:ffi; NO Flutter/dart:ui dep)
    │     The runtime engine. Port of packages/player-web/src/{decoder-worker,runtime}
    │     minus anything WebGL2/DOM-specific. Depends on aval_graph + aval_format.
    │     Defines the platform-seam interfaces a concrete backend must implement:
    │       - DecoderAdapter          (≈ WorkerVideoDecoderAdapter / PathSchedulerWorkerAdapter
    │                                    — the concrete implementation calls into
    │                                    flutter_rust_bridge-generated bindings for aval_decode)
    │       - RendererBackend<TImage> (≈ FrameRendererBackend, generic over the
    │                                    concrete image/texture type so this package
    │                                    stays dart:ui-free)
    │       - NetworkAdapter          (≈ range-asset-session.ts's fetch abstraction)
    │     Contains: path-scheduler family, decode-timeline, edge-lead, rational-time,
    │     submission-horizon, model.ts equivalent, motion-policy, reversible-presentation,
    │     cut-presentation-coordinator, readiness-evaluator, presentation-geometry,
    │     presentation-ring, frame-renderer orchestration shell, asset-catalog,
    │     avc-candidate-factory, verified-blob-store, page-resource-manager,
    │     integrated-player facade. Headless-testable (no widget tests needed for
    │     ~90% of this package's logic). Note: the `FrameCreditLedger` itself now
    │     lives in Rust (flutter/rust/aval_decode, §4), not here — aval_player's
    │     DecoderAdapter only needs a thin async caller.
    │
    └── aval_flutter/            (Flutter package; depends on aval_player, aval_format, aval_graph)
          Platform bindings + widget layer.
            - AvalPlayer widget, AvalPlayerController (ChangeNotifier)
            - FragmentProgram-based CustomPainter implementing RendererBackend<ui.Image>
            - flutter_rust_bridge-generated DecoderAdapter implementation calling
              flutter/rust/aval_decode (native FFI on iOS/Android/macOS/Windows/Linux;
              wasm-bindgen/dart:js_interop on web if the WASM backend is selected),
              plus a default dart:js_interop WebCodecs DecoderAdapter for web (§2),
              and an optional platform-channel (VideoToolbox/MediaCodec) adapter
              as a post-parity efficiency backend (§2(c))
            - dart:io/package:http NetworkAdapter implementation (Range requests,
              ETag/integrity verification ported from format's checked-integer style)
            - MouseRegion/Focus/GestureDetector engagement wiring (§5.4)
            - getDiagnostics() surface, error-event Stream plumbing
            - cargokit build-script integration (per-platform native builds) and
              flutter_rust_bridge codegen invocation (`flutter_rust_bridge_codegen generate`)
              wired into this package's build
```

**Dependency graph**: `aval_graph ← aval_format ← aval_player ← aval_flutter`,
with `flutter/rust/aval_decode` sitting *outside* that Dart dependency
chain entirely (it has no Dart-side dependency of its own; it is only
depended *on*, via generated bindings, from `aval_flutter`). `aval_flutter`
also depends directly on `aval_graph`/`aval_format` for type reuse, which
is transitively available anyway.

Because `aval_graph` and `aval_format` are being ported by parallel
workers, `aval_player`'s implementation must bind against a **frozen Dart
interface contract**, not the TypeScript source directly: specifically
`MotionGraphEngine`'s public methods (`install/beginAnimated/resumeAnimated/
request/send/tick/dispose/failStatic/recoverStatic`) and its `model.ts`
types, plus `aval_format`'s parsed manifest/access-unit-index types and the
`AvcIncrementalInspector`/PNG decoder outputs. Recommend a short contract
freeze meeting before Phase 2 (§7) begins, validated by cross-running the
TypeScript packages' own golden test fixtures translated 1:1 into the Dart
packages' test suites (not reinvented from scratch). Similarly, freeze
`aval_decode`'s FRB-exposed async API surface (configure/submit_access_unit/
take_frame/release_frame/dispose signatures and error/result types) before
`aval_player`'s `DecoderAdapter` implementation is written against it, so
the Rust crate and its Dart caller can be built in parallel too.

---

## 7. Phased Implementation Plan

Each phase lists exit criteria and the exact source modules it ports.
Session estimates assume focused agent-driven implementation sessions (not
wall-clock days) and **exclude** `aval_graph`/`aval_format` work already
covered by the parallel porting effort, though several phases gate on that
work being complete.

| # | Phase | Ports from | Exit criteria | Est. sessions |
|---|---|---|---|---|
| 0 | **Scaffolding & contracts** | n/a | `flutter analyze` green across all 4 packages; `DecoderAdapter`/`RendererBackend`/`NetworkAdapter` abstract interfaces defined in `aval_player`; empty `AvalPlayer` widget compiles in a demo app | 1 |
| 1 | **Parse grass-rabbit.avl** | (integration checkpoint on `aval_format`/`aval_graph`) | Dart parses `examples/grass-rabbit/public/grass-rabbit.avl` header+manifest+access-unit-index; unit/state/edge/rendition lists match the TS parse of the same file (cross-check against `grass-rabbit.avl.build.json`) | 1 |
| 2 | **Path scheduler ported (no real decode/render)** | `rational-time.ts`, `decode-timeline.ts`, `edge-lead.ts`, `submission-horizon.ts`, `path-scheduler*.ts` (all), `path-sequence.ts` | Given a fake `DecoderAdapter`, the scheduler produces the identical `PathFramePlan` sequence as the TS version for grass-rabbit's `motion.json` edges (golden-trace diff), including loop wrap and portal boundary selection | 2–3 |
| 3 | **Native AVC decode of one access unit (Rust core)** | New `aval_decode` Rust crate (`flutter/rust/aval_decode`) wrapping `openh264`; `avc/annex-b.ts`+`parameter-sets.ts` (from `aval_format`, for SPS/PPS extraction); the I420→RGBA SIMD conversion step (§3.3) | `openh264::Decoder` decodes one IDR access unit from grass-rabbit's packed-alpha rendition; the Rust-side I420→RGBA conversion output visually/PSNR-matches a browser-captured reference frame at the same index; native FFI call from Dart via `flutter_rust_bridge` round-trips successfully on at least one desktop platform | 2–3 |
| 3b | **WASM decode spike (validation only)** | Same `aval_decode` crate, `wasm32-unknown-unknown` target via `flutter_rust_bridge` web codegen | `openh264-sys2`'s C build compiles for `wasm32` and decodes the same access unit as Phase 3 in a browser (Flutter Web or plain wasm-bindgen harness) with matching output; **explicitly a go/no-go spike** — if this fails or the toolchain proves too fragile, fall back to WebCodecs-via-interop as the *only* web backend (§2) rather than blocking on it | 1–2 |
| 4 | **"Grass-rabbit renders one frame"** (named milestone) | `avc/rendition-geometry.ts` (packing rects), new `FragmentProgram` shader (§3.2, unchanged from v1 given the CPU-side YUV conversion in Phase 3) | One static packed-alpha frame renders pixel-correct (unpack, premultiply, color) in a minimal Flutter app, comparable side-by-side to a browser screenshot at the same frame index | 2 |
| 5 | **Decode concurrency + frame-credit + streaming decode-ahead (Rust-hosted)** | `decoder-worker/{protocol.ts,frame-credit-ledger.ts,core.ts,client.ts,sample-sequence.ts}` ported into `aval_decode` (Rust) rather than a Dart isolate protocol (§4); `flutter_rust_bridge` async/stream bindings wired into `aval_player`'s `DecoderAdapter` | grass-rabbit's `idle-loop` unit (frames 30–100) seekless-loops continuously in Flutter at 24fps with decode-ahead; rational timestamps show zero drift after 10 minutes of looping vs. the TS `DecodeTimeline` formula; Rust-side `FrameCreditLedger` correctly backpressures submission | 3–4 |
| 6 | **Presentation ring + resident/streaming split + geometry** | `presentation-ring.ts`, `presentation-geometry.ts` | No visible stutter/frame-drop at 24fps on a representative low-end device; `contain/cover/fill` fit modes visually match web reference screenshots | 2 |
| 7 | **Graph integration: one-shot intro + motion policy** | `model.ts`, `motion-policy.ts`, `integrated-player.ts` facade (subset), `aval_graph`'s `MotionGraphEngine` | Cold start plays the `intro` one-shot unit exactly once, then joins `idle-loop`; presentation-kind sequence matches the TS reference trace | 2–3 |
| 8 | **Portal transitions + engagement bindings** | `submission-horizon.ts`'s portal logic (already ported in Phase 2, now wired live), `MouseRegion`/`Focus`/`GestureDetector` wiring (§5.4) | Hovering the widget triggers `idle→entering→hover` at exactly authored portal frame 69 (frame-accurate, verified via trace capture); hover-leave triggers `hover→exiting→idle` identically. This is the task's named "frame-accurate portal transitions" milestone | 3 |
| 9 | **Widget API + readiness/events/diagnostics parity** | `element/src/*` (public-types, element-public-state, diagnostics, error taxonomy, shadow-layers two-layer model) | A Flutter demo reproduces `examples/grass-rabbit/main.js` behavior (one-shot hint-icon dismissal, state-label badge via `visualstatechange`, readiness-gated first paint) with equivalent Dart code | 2 |
| 10 | **Remaining transition types + cross-platform hardening** | `cut-presentation-coordinator.ts`, `reversible-presentation.ts`, `page-resource-manager.ts`/`page-reclamation.ts`, `verified-blob-store.ts` (sha256/integrity), `browser-context-recovery.ts`'s terminal-loss policy | Cut and reversible transitions work on a synthetic test asset (grass-rabbit itself doesn't exercise them); certification-style test matrix passes on iOS/Android/macOS/Windows/Linux with no dropped frames at portal boundaries under simulated jitter | 4–6 |
| 11 | **Performance/parity certification** | n/a (validation phase) | Automated pixel-diff harness vs. browser reference frames across the full `motion.json`, passing the M6 alpha-quality gate (mean ≤2/255, p99 ≤8/255); memory/GPU budget audit; docs finalized | 2–3 |

**Total estimate: ~27–34 agent sessions** (v2 adds the ~1–2 session Phase
3b WASM spike vs. v1's estimate), excluding the parallel
`aval_graph`/`aval_format` porting effort (Phase 1 gates on that work).

---

## 8. Risk Register

| # | Risk | Mitigation |
|---|---|---|
| 1 | Decoder latency variance across platforms/hardware breaks frame-accurate portal/finish timing | Never gate transition commit on wall-clock decode latency — port `edge-lead.ts`'s `leadReady`/`planEdgeLead` exactly: transitions commit only once required lead frames are *already resident*, so latency variance affects buffering depth, never frame accuracy. Tune per-platform ring-capacity/decode-ahead defaults rather than reusing the web's fixed constants |
| 2 | *(v2, largely resolved)* v1's ffmpeg-licensing risk is avoided by choosing `openh264` (BSD-2-Clause) as the primary decoder — no GPL/LGPL build-config concerns. Residual nuance: Cisco's *prebuilt* binaries carry MPEG-LA patent-royalty coverage for redistribution that a from-source cross-compiled build (as this crate does) may not automatically carry | Confirm patent-licensing posture with counsel for a from-source `openh264` build specifically (not just copyright licensing, which is clean); if that posture is unacceptable, the demoted ffmpeg-FFI alternative (§2(b)) or the platform-channel backend (§2(c)) remain available behind the same `DecoderAdapter` interface |
| 3 | `FragmentProgram`/Impeller platform coverage gaps or SkSL-vs-GLSL semantic differences (precision, `FlutterFragCoord()` origin, texture wrap modes) cause pixel mismatches vs. the WebGL2 reference | Build an automated pixel-diff golden-frame harness (Phase 11) comparing Flutter-rendered frames against browser-captured reference frames per commit, mirroring `docs/certification/1.0.0`; treat any diff exceeding the M6 spec's alpha-quality gate as build-blocking |
| 4 | FRB/FFI call round-trip latency (or, in the plain-FFI alternative, isolate message-passing latency) exceeds the frame-credit ledger's assumed timing budgets, causing jitter the web version doesn't have | Benchmark FRB async-call round-trip latency early (Phase 3/5) before committing to ring-capacity constants; running the credit ledger *inside Rust* (§4) removes one cross-language hop per credit check versus a Dart-side ledger, but the Dart↔Rust call boundary itself still needs measuring, not assuming, parity with the web's `postMessage` |
| 5 | No existing Flutter plugin (`video_player`, `media_kit`) supports arbitrary-AU random-access decode from a custom container — this is being built from scratch, though the Rust `openh264` binding itself is a maintained, production-used crate (e.g. in WebRTC-adjacent Rust projects), reducing decoder-correctness risk relative to a from-scratch decoder | Treat Phase 3 (native decode spike) as the highest-priority, timeboxed validation before committing further engineering; `media_kit`'s FFI/packaging patterns remain a useful reference for cargokit-style build integration even though its player abstraction itself is rejected |
| 6 | Behavioral drift between the parallel-ported `aval_graph`/`aval_format` and what `aval_player` actually needs | Freeze the exact Dart interface contract (§6) before Phase 2 begins; validate against the TypeScript packages' own golden test fixtures translated 1:1, not reinvented |
| 7 | WebGL2 `sampler2DArray` has no Impeller equivalent, risking silent behavioral differences in resident/streaming frame selection | Explicit documented substitution (§3.2): separate bound `ui.Image` objects per logical layer instead of array-texture layers; validate via the same golden-frame harness used for risk #3 |
| 8 | Reduced-motion signal differs across platforms (web `prefers-reduced-motion` vs. Flutter's `MediaQuery.disableAnimations` vs. each OS's real accessibility API) | Enumerate each platform's true reduced-motion signal early (iOS "Reduce Motion", Android "Remove animations", not just Flutter's `MediaQuery` proxy which may not reflect the OS setting identically everywhere); design `AvalMotion.auto` against real per-platform queries |
| 9 | Ported byte-budget/resource accounting (M2 spec's ≤24/48/64 MiB caps) has no real GPU-memory-pressure signal wired in, risking OOM on mobile in ways the web version never needed to handle | Port the byte-budget math as-is but add platform memory-pressure hooks (iOS `didReceiveMemoryWarning`, Android `onTrimMemory`) into the ported `page-reclamation.ts` coordinator |
| 10 | *(v2, decided)* Flutter Web has two viable decode backends (WebCodecs-via-interop, WASM-compiled `aval_decode`) that could drift from each other if both are maintained long-term | Ship WebCodecs-via-`dart:js_interop` as the *only* default web backend (§2) — it is hardware-accelerated and is the literal reference implementation; keep the WASM Rust-core path as an explicitly optional, separately-gated build target (Phase 3b) for certification/offline/no-WebCodecs scenarios only, not a second backend maintained at parity by default |
| 11 | *(new, v2)* `openh264` is a **software** decoder with no hardware-acceleration path, costing more CPU/battery than a hardware decoder on mobile, especially across AVAL's long-running hover/idle loop content | Ship OpenH264 as the default for v1 parity (correctness first); treat the VideoToolbox/MediaCodec platform-channel backend (§2(c)) as a scheduled post-parity efficiency optimization behind the same `DecoderAdapter` interface, gated on measured battery/thermal impact rather than assumed |
| 12 | *(new, v2)* `openh264-sys2`'s `wasm32` C-toolchain build path is not battle-tested for this project; the Phase 3b spike could fail or prove fragile to maintain across Rust/Emscripten/`wasm-bindgen` toolchain upgrades | Timebox Phase 3b explicitly as a go/no-go spike (§7); if it fails, permanently drop the WASM-Rust web backend and rely solely on WebCodecs-via-interop for web (already the recommended default) — no architecture changes needed elsewhere if this path is abandoned |
| 13 | *(new, v2)* The I420→RGBA conversion step (§3.3), which has no analog in the original WebGL2 pipeline, could introduce color-space or chroma-upsampling errors (wrong BT.709 coefficients, incorrect chroma siting) invisible until compared against the browser reference | Validate the Rust-side I420→RGBA conversion against the same M6 alpha/color-quality gate (mean ≤2/255, p99 ≤8/255) using the Phase 4/11 pixel-diff harness before trusting it as "done"; treat this conversion as a first-class, independently-tested unit (input: a known I420 test pattern; expected: a known RGBA output), not an incidental detail of the decode step |

---

## Appendix: Key Type/File Citations

- `packages/player-web/src/decoder-worker/protocol.ts` — `DecoderWorkerCommand`/`DecoderWorkerEvent`, `DecoderWorkerSample`, `DECODER_WORKER_HARD_LIMITS`
- `packages/player-web/src/decoder-worker/frame-credit-ledger.ts` — `FrameCreditLedger`, `FrameLease`, `hasSubmissionCredit`
- `packages/player-web/src/runtime/path-scheduler.ts` (909 LOC) — `PathScheduler`, `#calculateRouteDecision`, `#beginReplacementGeneration`
- `packages/player-web/src/runtime/submission-horizon.ts` (599 LOC) — `planSubmissionHorizon`, `SubmissionHorizonDecision`
- `packages/player-web/src/runtime/decode-timeline.ts` — `DecodeTimeline`, `#nextOrdinal`, `activateNextGeneration`
- `packages/player-web/src/runtime/rational-time.ts` — `RationalFrameRate`, `timestampForFrame`, `divideRoundHalfUp`
- `packages/player-web/src/runtime/frame-renderer-browser.ts` (905 LOC) — `FRAME_FRAGMENT_SHADER_SOURCE`, `BrowserFrameBackend`
- `packages/player-web/src/runtime/cut-presentation-coordinator.ts` (946 LOC) — `CutPresentationCoordinator`, `#commitStagedActivation`
- `packages/player-web/src/runtime/reversible-presentation.ts` — `ReversiblePresentationCoordinator`
- `packages/player-web/src/runtime/integrated-player.ts` (1,029 LOC) — `IntegratedPlayer`
- `packages/graph/src/model.ts` / `engine.ts` — `MotionGraphEngine`, `GraphStartPolicy`, `GraphPresentation`
- `packages/format/src/avc/rendition-geometry.ts` — `deriveAvcRenditionGeometryFromVisibleAtPath`, `PACKED_ALPHA_GUTTER`
- `packages/element/src/public-types.ts` / `element-public-events.ts` — `AvalElementEventMap`, `AvalDiagnostics`
- `packages/element/src/automatic-inputs.ts` — `INPUT_EVENTS`, `isTouchPointer`
- `examples/grass-rabbit/motion.json` — reference state graph (5 units, 4 states, 5 edges)
- `flutter/packages/aval_graph`, `flutter/packages/aval_format` — existing scaffolds (pubspec + `errors.dart`/`limits.dart` only)

### External Rust/Flutter ecosystem references (v2)

- `openh264` / `openh264-sys2` (Rust bindings to Cisco's BSD-2-Clause
  OpenH264 codec) — primary decode engine, §2(a)
- `flutter_rust_bridge` — Rust↔Dart binding codegen with native FFI *and*
  web (`wasm-bindgen`) targets from one Rust source; recommended over
  plain `cbindgen`+`dart:ffi` for its built-in async/stream support and
  dual native/web codegen
- `cargokit` — per-platform Cargo build integration for Flutter plugins
  (iOS/Android/macOS/Windows/Linux native builds); used to compile
  `flutter/rust/aval_decode` into each platform's build system
- Dart `NativeFinalizer` / `Pointer<T>.asTypedList` — the zero-copy,
  GC-safe mechanism for exposing Rust-owned decoded-frame buffers to Dart
  as external typed data (§4)
