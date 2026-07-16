# App Boundary And Packaging Contract

Date: 2026-06-24

This script keeps its own runtime output under `scripts/node/.runtime`. Future macOS app packaging must use `scripts/node/app-bundle-manifest.txt` as a whitelist source and must not copy the whole `scripts/node` directory blindly.

## Bundle Rules

- Include only files listed in `app-bundle-manifest.txt`.
- Exclude `.runtime`, `.DS_Store`, downloaded tools, logs, temporary files, and local shell output.
- Treat tests and docs as optional app resources; production app bundles can omit them if the packager has a smaller production whitelist.

## Project `.nvmrc`

Project `.nvmrc` writes are outside the script runtime boundary by design. The terminal flow stays disabled unless the user explicitly sets `NODE_MANAGER_ALLOW_PROJECT_WRITE=1`.

The JSON contract exposes this as `plan project-nvmrc <project-path> <version>` with `externalWrite:true`. The version must be a concrete Node version such as `20.11.1` or `v20.11.1`; moving aliases such as `lts` are rejected for reproducibility. `execute project-nvmrc` requires both `NODE_MANAGER_ALLOW_JSON_EXECUTE=1` and `NODE_MANAGER_ALLOW_PROJECT_WRITE=1`, so app callers must show a separate path confirmation and permission prompt before writing outside `scripts/node`.

## JSON Execute Gate

Most `--json execute` commands require `NODE_MANAGER_ALLOW_JSON_EXECUTE=1` after app-side confirmation. The compatibility command `execute cleanup logs` is the only exception: it proxies to `logs-cleanup`, touches only `scripts/node/.runtime/logs`, and does not require `NODE_MANAGER_ALLOW_JSON_EXECUTE`.
