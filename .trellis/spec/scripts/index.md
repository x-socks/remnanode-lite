# Scripts Layer — Spec Index

Deployment and management scripts for remnanode-lite (LXC-optimized).

## Pre-Development Checklist

- [ ] Does a similar helper function already exist in the script?
- [ ] Will this change affect both Alpine and Debian variants?
- [ ] Does this touch env file generation? Check all 4 scripts (deploy + upgrade × 2).
- [ ] Does this touch `XRAY_START_TIMEOUT` or other tuning defaults? Update all occurrences.

## Quality Check

- [ ] Tested on Alpine LXC (primary target)
- [ ] Tested on Debian (secondary target)
- [ ] No hardcoded values that also exist in env templates
- [ ] New env vars documented in `deploy/env/remnanode.env.example`

## Guidelines

| File | Purpose |
|------|---------|
| [conventions.md](./conventions.md) | Shell style, variable naming, function patterns |
| [env-management.md](./env-management.md) | Rules for env file generation and defaults |
