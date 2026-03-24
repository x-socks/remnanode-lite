# remnanode-lite

Bare-metal deployment scaffold for running Remnanode on extremely constrained Alpine LXC VPS instances.

GitHub Releases publish only the upstream Remnanode runtime bundle. Host bootstrap files are written directly by the installer script on the target machine.
The GitHub Actions workflow now checks upstream `remnawave/node:latest` once per day and only publishes a new runtime release when the upstream image digest changes.

Quick install:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-deploy.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-deploy.sh && \
sh /root/one-click-deploy.sh
```

Validated target state:

- Alpine Linux `3.23.x` with OpenRC
- 256 MB RAM, no swap
- NAT networking with only a small high-port window available
- Remnanode is started directly from prebuilt artifacts extracted from the official `remnawave/node` image
- Node.js matches the upstream runtime, currently `24.x`
- `supervisord` is present and Xray is launched through the same process tree
- Xray is installed locally and available as both `/usr/local/bin/xray` and `/usr/local/bin/rw-core`
- The OpenRC `remnanode` service runs as `root:root`

Runtime config note:

- The current runtime actually consumes `NODE_PORT` and `SECRET_KEY`

Start with [docs/alpine-bare-metal.md](docs/alpine-bare-metal.md).

For image extraction and host updates, also see [docs/runtime-bundle-workflow.md](docs/runtime-bundle-workflow.md).

For CI-driven export and remote deployment, see [docs/github-actions.md](docs/github-actions.md).

For first-time interactive host setup, you can also use [scripts/one-click-deploy.sh](scripts/one-click-deploy.sh).
