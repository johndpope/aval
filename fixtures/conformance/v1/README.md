# AVAL 1.0 four-codec bundle

This directory is a real compiler-produced AVAL 1.0 bundle for browser and
playground verification. The four assets contain the same transparent
idle/engaged animation and differ only in their video codec:

1. `av1.avl` — AV1, 10-bit
2. `vp9.avl` — VP9
3. `h265.avl` — H.265/HEVC
4. `h264.avl` — H.264/AVC

`build.json` is the canonical compiler report. Its `assets` array and
`sourceMarkup` preserve that order and contain the exact MIME codec string,
SHA-256 digest, and SRI value for every file. A browser should try the literal
direct-child `<source>` elements in this order and retain the first supported
configuration.

Rebuild from the canonical project with the local FFmpeg toolchain:

```sh
npm run build -w @pixel-point/aval-compiler
node packages/compiler/dist/cli.js compile \
  fixtures/compiler/v1/source/motion.json \
  --out fixtures/conformance/v1 --force
node fixtures/conformance/v1/update-provenance.mjs
npm run fixtures:verify
```

The exact source bytes and generated outputs are pinned in `provenance.json`.
The source frames are CC0-1.0.
