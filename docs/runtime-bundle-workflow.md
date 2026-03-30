# Runtime Bundle Workflow

The target VPS should never build Remnanode locally.

This repository uses two paths:

1. Export and publish runtime bundles on a separate machine or in GitHub Actions.
2. Pull and install those bundles from the Alpine VPS.

## Manual Export

Run on a machine with Docker:

```sh
./scripts/export-runtime-bundle.sh remnawave/node:latest
```

Default output:

- `./out/remnanode-runtime-<upstream-version>.tar.gz`
- falls back to `./out/remnanode-runtime-<stamp>.tar.gz` only when the upstream package version cannot be detected

Default exported paths:

- `dist`
- `node_modules`
- `package.json`
- `package-lock.json`
- `pnpm-lock.yaml`
- `npm-shrinkwrap.json`
- `prisma`
- `apps`
- `libs`
- `ecosystem.config.js`
- `.env.example`

Optional overrides:

```sh
APP_ROOT=/usr/src/app ./scripts/export-runtime-bundle.sh remnawave/node:latest
```

```sh
INCLUDE_PATHS="dist node_modules package.json prisma templates" \
./scripts/export-runtime-bundle.sh remnawave/node:latest
```

## GitHub Actions Export

The workflow [`.github/workflows/runtime-bundle.yml`](../.github/workflows/runtime-bundle.yml):

- checks `remnawave/node:latest` once per day
- compares the upstream image digest with the latest published release
- publishes a new release only when the digest changed

Published release assets:

- `remnanode-runtime-<upstream-version>.tar.gz`
- `remnanode-runtime-latest.tar.gz`

## VPS Install

Run on the VPS:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh install
```

Pin a specific upstream runtime version:

```sh
RUNTIME_VERSION=2.6.1 sh /root/one-click-panel.sh install
```

That install path pulls the selected runtime bundle from GitHub Releases and writes:

```text
/opt/remnanode/current -> /opt/remnanode/releases/<release-id>
```

## VPS Upgrade

Run on the VPS:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh update
```

That update path:

- downloads the selected release asset
- installs it into a new release directory
- repoints `/opt/remnanode/current`
- restarts `remnanode`

## Rollback

Because each runtime lands in its own release directory, rollback is just:

```sh
ln -sfn /opt/remnanode/releases/<previous-release-id> /opt/remnanode/current && \
rc-service remnanode restart
```

## Important Boundary

GitHub Actions publishes runtime bundles.

The VPS pulls runtime bundles.

There is no runner-to-VPS SSH step in the current design.
