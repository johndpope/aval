# Observed-display operator runbook

Begin only from a passed runtime report for the exact unchanged candidate and
profile. Use either a trace proven to identify actual refresh/scan-out for the
surface or synchronized external capture at four times measured refresh or
higher.

Record calibration, capture clock, shutter/exposure, focus, region, refresh,
capture rate, dropped-sample detection, tag-decoder version, and raw recording
digest. Import observations without editing them. Expected refresh repetition
for lower-rate authored content is normalized before duplicate grading.

The canonical metadata supplied to the importer must include
`captureProvenance`: the SHA-256 of the unmodified raw capture, the exact
extractor tool and version, the qualified operator role, and the complete
qualified reviewer-ID set from `config/release/release-policy.json`. The raw
capture is retained separately as `display-raw-capture`; final report-bundle
validation recomputes that attachment digest and requires it to equal the
provenance digest. A reviewer, operator, extractor, trace provider, or raw
capture cannot be substituted after the observation ledger is created.

Import a canonical CSV or JSON observation source with:

```text
node scripts/certification/import-display-observations.mjs samples.csv metadata.json observations.json
```

Inputs are stable no-follow reads and structured evidence is capped at 16 MiB,
the same in-memory limit enforced by report-bundle validation. The importer
accepts captured marker fields only; expected producer identities are derived
later from the exact candidate-owned pattern and runtime ledger.

Any ambiguous tag, dropped capture around a boundary, failed calibration, or
insufficient rate makes the result `inconclusive`. RAF, `performance.now()`,
`VideoFrame.timestamp`, GPU fences, canvas submission, screenshots, ordinary
screen recording, and readback are insufficient on their own.
