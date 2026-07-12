# Performance and budgets

The default page policy bounds decoders and tracked bytes across players. A
player reserves before allocation, publishes exact category ownership, and can
fall back to a strict static under pressure. Hidden or reduced-motion players
release optional animation resources first; required statics remain protected.

Use short independently decodable units, authored restart runways, reasonable
canvas dimensions, and a compact per-state static set. `getDiagnostics()` is
bounded and suitable for support logs, but verbose tracing, screenshots,
synchronous readback, and devtools perturb timing benchmarks.

CI performance comparisons are advisory. A named scheduling certificate
requires at least 300 post-warm-up outputs at 1.5× authored real time plus exact
deadline and boundary rules. Heap, RSS, GPU-process memory, and energy are
observational; explicit ownership counters are the leak gate.

## JavaScript delivery gates

The original design target put the complete element, player, and worker below
75 KiB gzip. The implementation did not meet that monolithic target, so it is
recorded as a miss and is not presented as a release pass. The accepted gates
measure the costs users actually encounter at distinct loading boundaries:

- the source-free element bootstrap's complete static import closure is
  strictly below 75 KiB gzip;
- the complete loaded element/player graph, including bootstrap and its one
  lazy runtime closure, is at most 250 KiB gzip; and
- the self-contained packaged decoder worker is at most 20 KiB gzip.

`scripts/performance/measure-m8-bundles.mjs` builds production ESM with pinned
Vite 8.1.4/Oxc and gzip level 9, verifies one lazy runtime boundary and no
duplicated module ownership, then enforces all three limits. A preliminary
source-tree run on 2026-07-12 measured 17,708 bootstrap bytes, 226,721 loaded
graph bytes, and 15,829 worker bytes. The former combined interpretation would
be 242,550 bytes and therefore misses 75 KiB. These numbers are not frozen
package evidence; the exact candidate must be measured again and recorded
before a release claim.
