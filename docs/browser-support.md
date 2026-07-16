# Browser support

Functional CI uses pinned Playwright Chromium, Firefox, and WebKit engines. It
proves browser-path correctness and fallback-state behavior; it is not a
branded Chrome, Edge, Firefox, or Safari certificate.

The player evaluates direct-child sources in author order. It validates each
required codec hint and probes every otherwise-eligible authored rendition
with `VideoDecoder.isConfigSupported()` inside the same module-worker
environment used for decoding. It does not sniff the user agent or call media
element `canPlayType()`.

A deterministically unsupported codec/configuration advances to the next
source. Network, CORS/CSP, integrity, malformed-asset, WebGL/resource, and
general decoder failures are terminal for that generation and keep the host's
external fallback visible. Within a file, renditions remain in authored
quality order. The runtime never silently changes canvas size, frame rate, or
active codec.

<!-- BEGIN GENERATED SUPPORT -->
| Profile | Host fallback | Runtime scheduling | Observed display |
| --- | --- | --- | --- |
| No named profiles | not run | not run | not measured |
<!-- END GENERATED SUPPORT -->

This table remains conservative until validated, digest-linked named reports
are committed. Runtime scheduling describes the browser-side content/deadline
ledger. Observed display requires a separate qualified scan-out trace or
calibrated external capture; RAF, decoder callbacks, GPU fences, canvas
submission, screenshots, and readback do not prove physical display continuity.
