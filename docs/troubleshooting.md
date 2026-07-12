# Troubleshooting

- `static` mode can be a successful usable result. Check `staticReason` and the
  `fallback` event before treating it as a fatal error.
- `unsupported` means an exact WebCodecs/WebGL/codec probe failed. The strict
  static path must still work.
- Range errors usually indicate transformed encoding, missing/malformed
  `Content-Range`, or a changing/missing strong ETag.
- External integrity mismatch means the complete fetched bytes are not the
  declared asset. Do not retry from a different range cache silently.
- `AbortError` commonly means a newer state/source superseded an operation.
- A request can wait for a decoder under page pressure. It must settle or abort;
  queues are bounded and FIFO.
- After a real disconnect, reconnect starts a fresh source generation. A final
  `dispose()` makes that element instance inert.
- If `getDiagnostics().cleanup.completed` is false, inspect its participant
  ownership and `failureCount`. Do not treat page totals as a leak while peer
  elements are active. A failed receipt blocks replacement/final disposal
  until a later lifecycle operation observes a completed receipt.

Capture the bounded diagnostics snapshot and public event order. Do not include
signed URLs, cookies, response bodies, local paths, or device serial numbers in
a support report.
