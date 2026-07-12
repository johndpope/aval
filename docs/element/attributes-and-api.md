# Attributes and API

The reflected attributes are exactly `src`, `integrity`, `crossorigin`,
`motion`, `autoplay`, `fit`, `bindings`, `state`, `interaction-for`, `width`,
and `height`.

| Attribute | Values | Default |
|---|---|---|
| `crossorigin` | `anonymous`, `use-credentials` | `anonymous` |
| `motion` | `auto`, `reduce`, `full` | `auto` |
| `autoplay` | `visible`, `manual` | `visible` |
| `fit` | `contain`, `cover`, `fill`, `none` | asset fit |
| `bindings` | `auto`, `none` | `auto` |

`src`, `integrity`, and `crossorigin` form one retrieval identity. Same-task
changes coalesce. A new identity first completely disposes the old generation;
only the newest pending identity may start. Policy, fit, input, state, and size
changes do not replace the asset.

Properties validate synchronously and never mutate on invalid input. Invalid
HTML attribute text falls back to the documented default and emits a nonfatal,
normalized `error` event. Source strings are capped at 4,096 UTF-16 code
units, interaction IDs at 256, state names use the format identifier grammar,
and size hints are integers from 1 through 16,384. The element has no external
image URL API: initial and per-state pixels come from verified asset statics,
with the author-owned fallback slot below them.

Core methods are `prepare`, `setState`, `send`, `readyFor`, `pause`, `resume`,
`getDiagnostics`, and `dispose`. Caller abort signals and `timeoutMs` bound only
that caller's `prepare()` wait; they do not cancel connected shared preparation.
`setState()` returns the graph-authored settlement promise. `send()` is
synchronous. `state` remains declarative intent and is not rewritten by
imperative requests.

Read-only staged properties include readiness, mode, fallback reason,
requested/visual state, transition state, pause intent, effective visibility,
and immutable discovered state/event/binding lists.

Same-root moves completed within the disconnect grace microtask preserve the
active generation. A real disconnect retires it. Reconnection in another
document or root clears an object-assigned `interactionTarget`, unpublishes the
old event bridge, rebinds styles and observers to the new realm, and starts a
successor only after the retired generation publishes a completed cleanup
receipt. Incomplete cleanup blocks that successor; a later completed receipt
can recover on a subsequent serialized lifecycle operation.
