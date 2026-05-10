# Shell Script Conventions

## Structure

- All scripts start with `set -euo pipefail`
- Helper functions defined before use
- `update_key_value_file` used for env file writes — never `echo >>` directly

## Variable Defaults

Top-of-file pattern:
```bash
VAR="${VAR:-default}"
```

Hardcoded in env template block (heredoc) AND as top-level default — both must match.

## Alpine vs Debian Parity

Deploy/upgrade logic is duplicated across `-alpine` and `-debian` variants. Any change to defaults or env vars must be applied to all 4 files:
- `one-click-deploy-alpine.sh`
- `one-click-deploy-debian.sh`
- `one-click-upgrade-alpine.sh`
- `one-click-upgrade-debian.sh`

## Naming

- UPPER_SNAKE for env vars
- `lower_snake` for local shell vars and functions
