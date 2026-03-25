# remnanode-lite

Bare-metal Remnanode deployment for extremely constrained Alpine LXC VPS hosts.

## Architecture

```mermaid
flowchart TB
    A["官方 remnawave/node 镜像"] --> B["GitHub Actions Runner"]
    B --> C["导出 runtime bundle"]
    C --> D["GitHub Release"]
    D --> E["remnanode-runtime-latest.tar.gz"]

    F["VPS: one-click-panel.sh"] --> G["install"]
    F --> H["update"]

    G --> I["从 GitHub Release 下载 runtime"]
    G --> J["写 OpenRC / supervisord.conf / env"]

    H --> I

    E --> I
    I --> K["/opt/remnanode/releases/..."]
    K --> L["/opt/remnanode/current"]
    L --> M["remnanode-start"]
    M --> N["Node.js 24 直接运行 Remnanode"]
    M --> O["supervisord"]
    O --> P["rw-core / xray"]
```

The current repository is designed to match the new architecture:

- GitHub Actions runs only on GitHub's runner
- the runner only exports and publishes the upstream Remnanode runtime bundle
- the runner does not SSH into the VPS
- the VPS pulls `remnanode-runtime-latest.tar.gz` from GitHub Releases by itself
- `install` writes host-local OpenRC, supervisord, and env files
- `update` only pulls a newer runtime, switches the active release, and restarts the service

## Quick Start

Interactive panel:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh
```

Direct install:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh install
```

Direct update:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh update
```

## Runtime Model

Validated target state:

- Alpine Linux `3.23.x` with OpenRC
- 256 MB RAM, no swap
- NAT networking with only a small high-port window available
- Node.js `24.x`
- `supervisord` present on the host
- Xray installed locally as `/usr/local/bin/xray` and `/usr/local/bin/rw-core`
- OpenRC `remnanode` service running as `root:root`

Current required runtime variables:

- `NODE_PORT`
- `SECRET_KEY`

## Current Entrypoints

Only these scripts are part of the current architecture:

- `scripts/export-runtime-bundle.sh`
- `scripts/one-click-panel.sh`
- `scripts/one-click-deploy.sh`
- `scripts/one-click-upgrade.sh`

## Conformance Check

Current practice matches the target architecture:

- [`.github/workflows/runtime-bundle.yml`](.github/workflows/runtime-bundle.yml) only exports and publishes release assets
- [`scripts/one-click-panel.sh`](scripts/one-click-panel.sh) only chooses `install` or `update` and downloads the matching host-side script
- [`scripts/one-click-deploy.sh`](scripts/one-click-deploy.sh) installs host dependencies, writes local config, downloads runtime from GitHub Releases, and starts the service
- [`scripts/one-click-upgrade.sh`](scripts/one-click-upgrade.sh) downloads the latest runtime from GitHub Releases, installs it into a new release directory, switches `current`, and restarts `remnanode`

One minor implementation detail:

- `one-click-panel.sh` still downloads `one-click-deploy.sh` or `one-click-upgrade.sh` from GitHub Raw before executing them on the VPS
- this still fits the new model, because the runner is not connecting to the VPS; the VPS is pulling what it needs itself

## Docs

- [docs/alpine-bare-metal.md](docs/alpine-bare-metal.md)
- [docs/runtime-bundle-workflow.md](docs/runtime-bundle-workflow.md)
- [docs/github-actions.md](docs/github-actions.md)
