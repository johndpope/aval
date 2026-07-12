# @rendered-motion/element

Progressive, web-only `<rendered-motion>` custom element for interactive
rendered motion assets. It lazy-loads the decoder/runtime only after a source
is assigned, preserves author-owned fallback content, supports arbitrary
authored states and events, and uses strict static fallback when animation is
unavailable or reduced motion is requested.

```js
import "@rendered-motion/element/auto";
```

```html
<button id="favorite" type="button">
  <rendered-motion
    src="/favorite.rma"
    interaction-for="favorite"
    aria-hidden="true"
  >
    <img slot="fallback" src="/favorite.png" alt="">
  </rendered-motion>
  <span>Favorite</span>
</button>
```

Use `setState(name)` for application state, `send(event)` for authored graph
events, and the reflected `state`, `motion`, `autoplay`, `fit`, and
`bindings` properties for framework integration. The package creates no
seeking `<video>`; playback is frame-scheduled through the Rendered Motion
web runtime.

See the repository element API, accessibility, network/integrity, and browser
support guides for the complete contract.
