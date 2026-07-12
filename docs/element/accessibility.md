# Accessibility

`<rendered-motion>` is a visual primitive. It does not add a role, name,
`tabindex`, keyboard handler, live region, pressed state, navigation, or
business action.

```html
<button id="favorite" type="button" aria-pressed="false">
  <rendered-motion
    src="favorite.rma"
    interaction-for="favorite"
    aria-hidden="true"
  >
    <img slot="fallback" src="favorite.png" alt="">
  </rendered-motion>
  <span>Favorite</span>
</button>
```

Keep meaning in text/ARIA owned by the page. Use an independent live region for
loading or errors. Static reduced-motion states must communicate the same
meaning as animated states. Supply a separate pause control when nonessential
motion continues beyond five seconds. Avoid rapid flashes, excessive parallax,
and high-frequency infinite motion even when full motion is requested.
