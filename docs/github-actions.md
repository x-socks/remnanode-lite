# GitHub Actions

This repository uses GitHub Actions only as a runtime export and release publisher.

It does not SSH into any VPS.
It does not copy files to any VPS.
It does not restart services on any VPS.

The split is:

1. GitHub runner pulls `remnawave/node:latest`.
2. GitHub runner exports the runtime bundle.
3. GitHub runner publishes `remnanode-runtime-latest.tar.gz` to GitHub Releases.
4. The Alpine VPS later pulls that release asset itself.

The workflow is [`.github/workflows/runtime-bundle.yml`](../.github/workflows/runtime-bundle.yml).

## Triggers

- Daily schedule:
  - checks the upstream image digest
  - publishes a new runtime release only when the upstream digest changed
- Manual `workflow_dispatch`:
  - lets you override `image_ref`
  - lets you override `app_root`
  - lets you override `include_paths`
  - can skip release publishing with `publish_release=false`

## Permissions

The workflow needs:

- `contents: write`

If release creation fails with `Resource not accessible by integration`, set:

- `Settings -> Actions -> General -> Workflow permissions`
- `Read and write permissions`

## Release Asset

Stable asset name:

- `remnanode-runtime-latest.tar.gz`

Each generated release note records:

- the upstream image reference
- `image_digest=sha256:...`

That digest is what the daily job uses to decide whether a new release is needed.

## First Install On The VPS

Run on the VPS:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh
```

The install path:

- installs the Alpine packages it needs on the VPS
- installs Xray locally on the VPS
- downloads the latest runtime bundle from GitHub Releases
- prompts for `NODE_PORT`
- prompts for `SECRET_KEY`
- writes OpenRC and supervisord config locally on the VPS
- starts `remnanode`

## Later Upgrades On The VPS

Run on the VPS:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh update
```

That update path:

- downloads the latest `remnanode-runtime-latest.tar.gz`
- installs it into a new release directory
- repoints `/opt/remnanode/current`
- restarts `remnanode`

## Terminology

- `runner`: the temporary GitHub Actions machine provided by GitHub
- `VPS`: your Alpine machine that actually runs Remnanode

In this project, the runner only publishes release assets. The VPS is the only side that pulls and installs them.
