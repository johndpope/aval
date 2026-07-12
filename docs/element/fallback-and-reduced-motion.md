# Fallback and reduced motion

The visual ladder is the author-owned light-DOM fallback, a verified
current-state asset static, then animation after its first prepared draw. A
layer never hides the last usable layer before its own pixels are ready. There
is no independent image request that can bypass asset integrity.

`motion="auto"` follows live `prefers-reduced-motion`; `reduce` forces strict
per-state statics and `full` ignores that preference while still respecting
visibility, pause intent, and resource limits. Reduced mode never advances an
infinite loop. Returning to full begins the current state's body at frame zero,
without replaying its initial intro.

Offscreen, document-hidden, page-hidden, and zero-size hosts suspend through
the same player visibility path. Logical time freezes. Re-entry rebuilds behind
the current static without elapsed-time catch-up. `pause()` is independent of
visibility; `resume()` records intent even while hidden.
