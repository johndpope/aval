# Author user-defined states

Run `rma init my-motion` for a deterministic CC0 idle/engaged project. Its
project JSON uses schema 0.2, two arbitrary states, a resident reversible
transition with endpoint runways, strict per-state posters, and
`engagement.on/off` bindings. Explanations remain in README so JSON stays valid.

Edit names freely within the identifier grammar. Define bodies and edges in the
project; do not add runtime state-specific JavaScript. Build with:

```sh
cd my-motion
rma compile motion.json --out starter.rma
rma validate starter.rma
```

The generated `provenance.json` records every source-frame and project digest
and the CC0-1.0 license.
