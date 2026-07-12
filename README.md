# Rendered Motion

Rendered Motion is a web-only format and runtime for short pre-rendered motion
with continuous partial loops, user-defined states, authored triggers, bounded
transitions, packed transparency, and strict static fallback.

The central idea is simple: encode independently decodable motion units and a
small deterministic state graph in one `.rma` asset. The browser keeps a
decoder timeline moving forward across a loop instead of seeking a video file
at every seam. Hover, focus, application state, reversals, portals, finite
bodies, and held states are graph routes rather than hand-timed media seeks.

## Five-minute start

```sh
npm install @rendered-motion/element@1.0.0
npm install --save-dev @rendered-motion/compiler@1.0.0
npx rma init my-motion
cd my-motion
npm install
npm run dev
```

Open the printed loopback URL. That generated starter includes its frames,
project, fallback markup, exact package dependencies, and watch workflow. The
following is illustrative integration markup for a package-aware web build
after you publish or copy a compiled asset into your application:

```html
<script type="module" src="/motion.js"></script>

<rendered-motion src="/my-motion.rma" width="320" height="320">
  <img slot="fallback" src="/my-motion.png" alt="">
</rendered-motion>
```

```js
// motion.js, resolved by your package-aware web build
import { defineRenderedMotionElement } from "@rendered-motion/element";
defineRenderedMotionElement();
```

A one-state asset loops with no seeking code. Multi-state assets keep their
own names and triggers; applications can set any authored state:

```ts
const motion = document.querySelector("rendered-motion");
await motion?.setState("success");
```

The element package is SSR-safe. Its root exports an explicit definition
helper; the opt-in `@rendered-motion/element/auto` entry is the only automatic
registration side effect.

## What is included

- `@rendered-motion/graph`: deterministic latest-wins state and route engine;
- `@rendered-motion/format`: strict wire `0.1` parser, validator, and writer;
- `@rendered-motion/compiler`: project `0.2` authoring and CLI;
- `@rendered-motion/player-web`: bounded web loader, decoder scheduler,
  renderer, static fallback, and page resource manager; and
- `@rendered-motion/element`: markup-first public browser component.

The compiler uses caller-installed FFmpeg/FFprobe and libx264; it never bundles
or downloads native codec tools. Codec, patent, source-media, and distribution
obligations remain the publisher's responsibility.

## Develop and verify

Node.js 22.12.0 or newer is required.

```sh
npm ci --ignore-scripts
npm run typecheck
npm run test:unit
npm run build
npm run test:browser:reference
```

Browser animation is capability-probed. Unsupported WebCodecs/WebGL/AVC
configurations must still pass the strict per-state static path.

## Documentation

- [Quick start](docs/quick-start.md)
- [States and triggers](docs/states-and-triggers.md)
- [Element API](docs/element-api.md)
- [Compiler](docs/compiler.md)
- [Network and integrity](docs/network-and-integrity.md)
- [Accessibility and reduced motion](docs/accessibility-and-motion.md)
- [Performance and budgets](docs/performance-and-budgets.md)
- [Browser support](docs/browser-support.md)
- [Versioning](docs/versioning.md)
- [Certification method](docs/certification/method.md)
- [Security policy](SECURITY.md)

Functional Playwright evidence is not a branded-browser or physical-display
certificate. Runtime scheduling certification applies only to exact published
named profiles. Physical display continuity requires a separate qualifying
observed-display report; browser callback, decoder, GPU-fence, screenshot, and
canvas-readback timestamps are insufficient by themselves.
