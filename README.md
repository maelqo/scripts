# scripts

Public mirror of deployment tooling for Maelqo products, one top-level
folder per product (e.g. `aiflow/`). Source of truth for each product's
scripts and compose files live in that product's own (private) repo;
This repo exists only so clients can `curl` them without authenticating
against a private repo.

## aiflow

`aiflow/` holds the self-hosted deployment scripts for AiFlow. 
Synced automatically from the private AiFlow repo's `scripts/` directory 
on every relevant push, don't edit these files here directly;
Changes will be overwritten on the next sync.
