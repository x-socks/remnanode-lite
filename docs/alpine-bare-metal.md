# Alpine Bare-Metal Deployment

This layout targets Alpine LXC guests where Docker and local NestJS builds are too expensive.

Validated host state:

- Alpine `3.23.x`
- OpenRC
- Node.js `24.x`
- `supervisord`
- local Xray binary at `/usr/local/bin/xray`
- `/usr/local/bin/rw-core -> /usr/local/bin/xray`
- Remnanode runtime under `/opt/remnanode/releases/...`
- `/opt/remnanode/current` symlinked to the active release

## First Install

Run on the VPS:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh install
```

The installer will:

- install required Alpine packages
- install Xray if it is missing
- download the latest runtime bundle from GitHub Releases
- prompt for `NODE_PORT`
- prompt for `SECRET_KEY`
- write `/etc/remnanode/remnanode.env`
- write `/etc/supervisord.conf`
- write OpenRC service files
- start `remnanode`

Accepted `SECRET_KEY` input:

- raw secret value
- full `SECRET_KEY=...` line copied from the panel

## Later Update

Run on the VPS:

```sh
apk add --no-cache curl && \
curl -fsSL -o /root/one-click-panel.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-panel.sh && \
sh /root/one-click-panel.sh update
```

## Important Files

- `/etc/remnanode/remnanode.env`
- `/etc/remnanode/github-release.env`
- `/etc/supervisord.conf`
- `/etc/init.d/remnanode`
- `/etc/conf.d/remnanode`
- `/usr/local/bin/remnanode-start`
- `/opt/remnanode/current`

## Required Variables

Current runtime requires:

- `NODE_PORT`
- `SECRET_KEY`

Also used by the current host layout:

- `XTLS_API_PORT=61000`
- `XRAY_BIN=/usr/local/bin/xray`
- `XRAY_CONFIG=/etc/xray/config.json`
- `XRAY_ASSET_DIR=/usr/local/share/xray`

Low-memory defaults:

- `NODE_OPTIONS='--max-http-header-size=65536 --max-old-space-size=64 --max-semi-space-size=1'`
- `MALLOC_ARENA_MAX=2`
- `UV_THREADPOOL_SIZE=1`
- `REMNANODE_ULIMIT_NOFILE=65535`

## Logs

- `/var/log/remnanode/remnanode.log`
- `/var/log/remnanode/remnanode.err`
- `/var/log/supervisor/supervisord.log`
- `/var/log/supervisor/xray.out.log`
- `/var/log/supervisor/xray.err.log`

## Runtime Layout

Expected active tree:

```text
/opt/remnanode/current
├── dist/
├── node_modules/
├── package.json
└── ...
```

## Operational Notes

- Do not build NestJS on the VPS.
- Do not run Docker on the VPS.
- Let the VPS pull runtime bundles from GitHub Releases.
- Let GitHub Actions only publish releases.
- Keep file descriptor limits high.
- On 256 MB hosts, raising V8 heap limits usually makes OOM behavior worse.

## Common Failure Modes

`NODE_PORT must be numeric`

- The panel value was pasted incorrectly.
- Use the numeric Node Port from the Remnawave panel.

`SECRET_KEY is required`

- The panel secret was empty or truncated.
- Paste the full payload from the panel.

`Supervisord socket file not found`

- `supervisord` did not come up cleanly.
- Check `/var/log/supervisor/supervisord.log`.
- Check `/var/log/remnanode/remnanode.err`.

`connect ECONNREFUSED 127.0.0.1:61000`

- Xray did not fully start or its internal API is not ready.
- Check the supervisor logs and Xray logs first.

`Killed` or exit code `137`

- The container hit its memory limit.
- Do not increase heap size blindly on 256 MB hosts.
