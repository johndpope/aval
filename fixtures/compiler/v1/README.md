# AVAL 1.0 compiler fixture

This is the canonical source project for the checked AVAL 1.0 multi-codec
bundle. It contains a small transparent idle/engaged animation, authored as a
PNG sequence, and requests ordered AV1, VP9, H.265, and H.264 encodings.

The compression settings intentionally keep this fixture quick to rebuild. A
production project can select slower presets, `deadline: "best"`, lower
`cpuUsed`, more AV1 tiles and threads, and codec-specific CRF values.

Rebuild the source provenance after an intentional source edit with:

```sh
node fixtures/compiler/v1/update-provenance.mjs
```

The generated frames are CC0-1.0. See `source/ASSET-LICENSE.md`.
