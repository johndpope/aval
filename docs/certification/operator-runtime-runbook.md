# Runtime certification operator runbook

1. Obtain the immutable candidate bundle and independently verify its candidate
   manifest digest.
2. Create a bounded public-safe run config with exact product versions/builds,
   OS, hardware class, driver/Metal, display/refresh/scale, power/thermal state,
   background load, and candidate/fixture/harness digests. Never record serials,
   user names, signed URLs, or browser profile paths.
3. Start a fresh browser process/profile, headed and visible. Close devtools,
   screen capture, readback, and unrelated load.
4. Confirm the page is foreground, focused, source-matched, and exact capability
   probes are complete. Do not substitute another codec or browser.
5. Run all scenarios three times, each from a fresh process. Preserve failures,
   host interruptions, and partial attachments.
6. Run resource/lifecycle/fault profiles and the full 30-minute soak.
7. Hash raw ledgers first, then export and validate canonical report JSON.
8. A second reviewer verifies environment, digests, criteria, and status.

Playwright engines may exercise the page functionally but cannot fill branded
browser certification fields.
