# Accessibility and motion

The custom element supplies motion, not business semantics. Put button, link,
pressed, selected, status, progress, and keyboard behavior on ordinary host DOM
where users and assistive technology expect it. Use `interaction-for` or the
`interactionTarget` property to associate that semantic control with motion.

`motion="auto"` follows live `prefers-reduced-motion`; `reduce` forces strict
per-state statics; `full` requests animation when exact capabilities and
resources permit it. Reduced motion still processes authored state changes and
bindings, but an infinite body does not advance. Static states must convey the
same product meaning as animated states.

Light-DOM fallback remains usable without JavaScript. Supply meaningful
alternative text when motion carries information, and empty alternative text
when it is decorative. The element does not capture keyboard events, suppress
clicks, or invent roles.
