# Alpine Bare-Metal Deployment

This layout is tuned for Alpine LXC guests where Docker, PM2, and local NestJS builds are too expensive.

## 1. Assumptions

- `node` is already available on the host, ideally Node.js 20 LTS.
- `xray` is already available on the host, ideally under `/usr/local/bin/xray`.
- Remnanode runtime files are extracted from the official image into `/opt/remnanode/current`.
- The extracted runtime contains at least:
  - `dist/`
  - `node_modules/`
  - `package.json`
- Remnanode is the primary service. It can call Xray directly if the binary path is exposed through env.

Expected runtime tree:

```text
/opt/remnanode/current
├── dist/
├── node_modules/
├── package.json
└── ...
```

## 2. Install This Layout

Run a lightweight host preflight first:

```sh
./scripts/preflight-alpine.sh
```

Create the dedicated service account on the Alpine host:

```sh
./scripts/create-service-user.sh
```

Copy the service assets into the host root:

```sh
./scripts/install-layout.sh
```

That installs:

- `/usr/local/bin/remnanode-start`
- `/usr/local/bin/xray-start`
- `/usr/local/bin/create-remnanode-user`
- `/usr/local/bin/install-remnanode-runtime`
- `/usr/local/bin/remnanode-preflight`
- `/usr/local/bin/check-remnanode-layout`
- `/usr/local/bin/remnanode-update-from-github`
- `/etc/init.d/remnanode`
- `/etc/init.d/xray`
- `/etc/conf.d/remnanode`
- `/etc/conf.d/xray`
- `/etc/remnanode/remnanode.env`
- `/etc/remnanode/xray.env`
- `/etc/remnanode/github-release.env`
- `/etc/xray/config.json.example`

If you want to stage into another root filesystem, use:

```sh
./scripts/install-layout.sh /my/chroot
```

## 3. Configure Remnanode

Edit `/etc/remnanode/remnanode.env`.

Important values:

- `REMNANODE_APP_DIR=/opt/remnanode/current`
- `REMNANODE_ENTRYPOINT=dist/src/main.js`
- `APP_PORT=<the same Node Port configured in the panel>`
- `SSL_CERT=...` copied as a full line from the panel
- `XRAY_BIN=/usr/local/bin/xray`

Low-memory defaults are already set conservatively:

- `NODE_OPTIONS=--max-old-space-size=64 --max-semi-space-size=1`
- `MALLOC_ARENA_MAX=2`
- `UV_THREADPOOL_SIZE=1`
- `REMNANODE_ULIMIT_NOFILE=65535`

Do not raise memory flags unless you have measured headroom. On a 256 MB host, bigger heaps usually make OOM kills more likely, not less.

`APP_PORT` is the key listener variable for the current `@remnawave/node` runtime. Set it to the same Node Port you configured in the Remnawave panel.

`SSL_CERT` must be copied from the panel as a full `SSL_CERT=...` line. Do not truncate it and do not paste only the value label.

## 3.1 Extract Runtime From the Official Image

Do this on a machine with enough memory, not on the 256 MB host.

The target host needs the runtime payload only:

- `dist/`
- `node_modules/`
- `package.json`
- any config files required by your Remnanode build

Once extracted, transfer it to:

```sh
/opt/remnanode/current
```

Avoid `npm install` and `npm run build` on the target box.

For a repeatable extraction and update workflow, see [docs/runtime-bundle-workflow.md](runtime-bundle-workflow.md).

## 4. Configure Xray

There are two supported patterns:

1. Recommended: let Remnanode spawn Xray itself.
2. Optional: run Xray as its own OpenRC service for debugging or a split-control setup.

For the default pattern, ensure only these are correct:

- `XRAY_BIN` in `/etc/remnanode/remnanode.env`
- Xray assets and config paths expected by your Remnanode build

If you intentionally run standalone Xray:

- copy `/etc/xray/config.json.example` to `/etc/xray/config.json`
- edit the ports so they stay inside your allowed public range
- enable the `xray` service only if Remnanode will not also start its own Xray child

Running both simultaneously against the same ports will fail.

## 5. OpenRC Usage

Enable and start Remnanode:

```sh
rc-update add remnanode default
rc-service remnanode start
```

Optional standalone Xray:

```sh
rc-update add xray default
rc-service xray start
```

Logs:

- `/var/log/remnanode/remnanode.log`
- `/var/log/remnanode/remnanode.err`
- `/var/log/xray/xray.log`
- `/var/log/xray/xray.err`

## 6. Verification

Basic layout check:

```sh
./scripts/check-remnanode-layout.sh /opt/remnanode/current
```

Manual service validation:

```sh
/usr/local/bin/remnanode-start
```

If Remnanode exits immediately, check:

- `APP_PORT` is set and matches the panel
- `SSL_CERT` exists as a full line copied from the panel
- the entrypoint path exists
- `node_modules` is present
- the env file values match the extracted runtime layout
- `xray` is executable by the service user

Host preflight can be rerun at any time:

```sh
./scripts/preflight-alpine.sh
```

## 7. Memory Discipline

Keep these habits:

- Avoid shell sessions and background tools you do not need.
- Do not build NestJS on the host.
- Prefer one service process tree, not multiple supervisors.
- Keep `GOMAXPROCS=1` for standalone Xray unless profiling proves otherwise.
- Keep file descriptor limits high to avoid fork and socket churn failures.

## 8. Common Failure Modes

`Killed` or exit code `137`

- The process exceeded the container memory limit.
- Lower traffic, lower concurrency, or trim enabled features before raising heap size.

`ECONNRESET` or HTTP 500 during Xray interaction

- Check `ulimit -n`.
- Confirm the service inherited `65535`.
- Confirm Xray is not being launched twice.

`not found` when launching Xray on Alpine

- Usually indicates glibc-linked binary issues on musl.
- Install and verify `gcompat`, or use a musl-compatible Xray build.

`Cannot find module`

- The extracted runtime is incomplete.
- Re-export the official image contents with `node_modules` included.
