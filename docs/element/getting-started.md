# Rendered Motion element: getting started

> `@rendered-motion/element`, `<rendered-motion>`, and `.rma` are prototype
> names. Pin an exact version once packages are published.

Install and explicitly register the SSR-safe package root:

```sh
npm install @rendered-motion/element
```

```js
import { defineRenderedMotionElement } from "@rendered-motion/element";
defineRenderedMotionElement();
```

```html
<rendered-motion src="/assets/orbit.rma" width="96" height="96">
  <img slot="fallback" src="/assets/orbit.png" alt="" width="96" height="96">
</rendered-motion>
```

Connection automatically prepares metadata and the current strict static.
When animation is supported and visible, a direct one-state compile plays its
authored intro and body loop without application code. Unsupported animation
remains a successful static result. Network, parser, integrity, or strict
static failure leaves the author-owned fallback visible.

For a browser-only pinned CDN import, use the explicit side-effect entry:

```js
import "https://your-pinned-cdn.example/@rendered-motion/element@VERSION/auto";
```

Do not use an unpinned URL in production. Call `dispose()` when an element
instance is permanently retired; it settles only after the terminal cleanup
receipt. Ordinary disconnection already retires the source. A same-root
same-task DOM move preserves it, while a later true reconnect or cross-realm
adoption starts a receipt-gated source generation.
