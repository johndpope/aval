# Compile a seamless partial loop

```sh
avl compile input.mov --loop 48:96 --codec av1 \
  --crf 20 --bit-depth 10 --cpu-used 0 --tiles 2x2 \
  --row-mt --threads 8 --out orbit
```

Frames are canonical. The optional intro is `[0,48)` and the repeating body is
`[48,96)`; no runtime seek is involved. The compiler validates the visual seam,
codec random-access/dependency timeline, alpha policy, dimensions, and resource
bounds before atomic bundle publication. Unused tail frames produce a warning.

Successful text and JSON output include frame rate, frame/time ranges, visible
and coded geometry, alpha choice, byte/resource estimates, continuity/alpha
summary, SHA-256 digest, and copyable element markup. Printed time is an
explanation of frame indices, not a new timestamp authority.
