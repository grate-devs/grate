# Docker publication configuration

These are desired setup templates, not snapshots of live settings. Verify the
actual configuration when changing or diagnosing publication.

| File | Purpose |
| --- | --- |
| `github-environment.json` | Settings for the `docker-hub` GitHub environment |
| `github-environment-policies.json` | Allowed branch/tag deployment rules |
| `oidc-connection-request.json` | Docker organization OIDC subject and repository-scoped push grant |

See [publication configuration](../RELEASE.md#publication-configuration) for the
identity boundaries, required variables and setup references. Keep credentials
and observed API responses out of these files.
