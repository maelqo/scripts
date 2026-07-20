# scripts

Public mirror of deployment tooling for maelqo products. Source of truth
for each product's scripts and compose files lives in that product's own
(private) repo; this repo exists only so clients can `curl` them without
authenticating against a private repo.

## aiflow

`scripts/aiflow/` holds the self-hosted deployment scripts for AiFlow
(`deploy-compose.sh`, `deploy-coolify.sh`, `deploy-caddy.sh`) and their
companion files under `scripts/aiflow/config/` (Docker Compose files,
`.env.example`, `Caddyfile.example`). See that product's own
`docs/DEPLOYMENTS.md` for what each script does and how to run them, this
repo intentionally carries no other documentation of its own to avoid
drifting out of sync with it.
