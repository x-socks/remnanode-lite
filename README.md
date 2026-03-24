# remnanode-lite

Bare-metal deployment scaffold for running Remnanode on extremely constrained Alpine LXC VPS instances.

This repository assumes:

- Alpine Linux with OpenRC
- 256 MB RAM, no swap
- NAT networking with only a small high-port window available
- Remnanode is started directly from prebuilt artifacts extracted from the official image
- Xray binary is installed locally, and by default Remnanode is allowed to spawn/manage it

Start with [docs/alpine-bare-metal.md](docs/alpine-bare-metal.md).

For image extraction and host updates, also see [docs/runtime-bundle-workflow.md](docs/runtime-bundle-workflow.md).

For CI-driven export and remote deployment, see [docs/github-actions.md](docs/github-actions.md).
