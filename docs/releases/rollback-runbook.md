# Rollback runbook

Read the publication ledger and registry state first. In reverse dependency
order, restore `latest` to the recorded previous known-good exact versions.
Deprecate affected immutable versions with a link to mitigation instructions;
do not unpublish them.

Mark public result summaries withdrawn while retaining original raw reports and
attachments. Publish a replacement only after a new immutable candidate passes
the complete gate. Runtime remote kill switches are outside the architecture.
