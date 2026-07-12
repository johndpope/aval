# Security and privacy

Use immutable content-hashed assets, HTTPS, exact CORS/range responses, strong
ETags, CSP, and external integrity when the distribution channel is not already
authenticated. Avoid credentialed cross-origin loading unless required.

The format contains media and declarative graph data only. It cannot execute
JavaScript, selectors, HTML, CSS, or network requests. Public diagnostics and
events are bounded and secret-free. Release reports forbid personal paths,
query-bearing URLs, serial-number fields, unsafe integers, non-finite values,
unbounded attachments, and digest mismatches.

See the repository [security policy](../SECURITY.md) and [threat model](../THREAT-MODEL.md).
