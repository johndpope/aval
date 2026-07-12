# Compiler

The CLI supports `init`, `compile`, `dev`, `inspect`, `validate`, and `unpack`.
Project schema `0.2` produces wire format `0.1`; package version `1.0.0` does
not change either schema.

```sh
npx rma init my-motion
npx rma compile my-motion/motion.json --out my-motion.rma
npx rma inspect my-motion.rma
npx rma validate my-motion.rma
```

Inputs are strict JSON projects and bounded video or PNG sequences. The compiler
normalizes timing, creates independently decodable AVC units, validates exact
geometry and alpha policy, emits strict per-state PNGs, and writes atomically.
Build reports record the resolved FFmpeg/FFprobe fingerprints and quality
results. Temporary paths do not enter compiled bytes.

FFmpeg, FFprobe, libx264, and codec patent/licensing obligations are not bundled
or cleared by this project. Use a reviewed local toolchain and obtain legal
review for production distribution.
