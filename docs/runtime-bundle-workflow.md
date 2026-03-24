# Runtime Bundle Workflow

This workflow is for the real bottleneck in 256 MB Alpine guests: never build on the target host.

## 1. Export Runtime From the Official Image

Run this on a separate machine that already has the upstream image available locally:

```sh
./scripts/export-runtime-bundle.sh remnawave/node:latest
```

What the script does:

- creates a stopped container from the image
- detects a likely Node app root inside the container
- copies only runtime artifacts out of the image
- writes a compressed tarball under `./out/`

Default included paths:

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

The defaults are intentionally broader than the minimum so the extracted runtime is less likely to miss a required asset.

If the official image uses a non-standard app root, set it explicitly:

```sh
APP_ROOT=/usr/src/app ./scripts/export-runtime-bundle.sh remnawave/node:latest
```

If you need extra files:

```sh
INCLUDE_PATHS="dist node_modules package.json prisma templates" \
./scripts/export-runtime-bundle.sh remnawave/node:latest
```

## 2. Transfer the Bundle

Copy the generated tarball to the target host, for example:

```sh
scp out/remnanode-runtime-*.tar.gz root@your-host:/root/
```

If you also want a portable helper bundle for first-time bootstrap:

```sh
./scripts/package-host-tools.sh
```

That writes `out/remnanode-host-tools-*.tar.gz`.

If you publish GitHub releases from Actions, the host can also consume these stable asset names:

- `remnanode-runtime-latest.tar.gz`
- `remnanode-host-tools-latest.tar.gz`

## 3. Install or Update Runtime On the Target Host

On the Alpine host:

```sh
./scripts/install-runtime-bundle.sh /root/remnanode-runtime-<stamp>.tar.gz
```

For a first-time host bootstrap from an extracted helper bundle:

```sh
tar -xzf remnanode-host-tools-<stamp>.tar.gz
cd remnanode-host-tools
./scripts/bootstrap-host.sh /root/remnanode-runtime-<stamp>.tar.gz
```

For a first-time host bootstrap directly from the latest GitHub release:

```sh
curl -fsSL -o /tmp/bootstrap-from-github-release.sh \
  https://raw.githubusercontent.com/<owner>/<repo>/<branch>/scripts/bootstrap-from-github-release.sh
sh /tmp/bootstrap-from-github-release.sh <owner>/<repo>
```

This installs into a release directory and repoints:

```text
/opt/remnanode/current -> /opt/remnanode/releases/<release-id>
```

That makes updates reversible without rebuilding on the host.

Optional custom target:

```sh
./scripts/install-runtime-bundle.sh /root/remnanode-runtime-<stamp>.tar.gz /srv/remnanode
```

## 4. Restart the Service

After updating:

```sh
rc-service remnanode restart
```

If you want a sanity check before restart:

```sh
./scripts/check-remnanode-layout.sh /opt/remnanode/current
```

If the host has been configured for pull-based updates:

```sh
/usr/local/bin/remnanode-update-from-github
```

Updating the runtime bundle does not replace your application-specific env choices. Keep `/etc/remnanode/remnanode.env` aligned with the panel, especially:

- `APP_PORT`
- `SSL_CERT`

## 5. Roll Back

Because each deployment lands in its own release directory, rollbacks are symlink-only:

```sh
ln -sfn /opt/remnanode/releases/<previous-release-id> /opt/remnanode/current
rc-service remnanode restart
```

## 6. What Is Not Verified Here

This repository does not embed the official image and cannot prove the exact app root ahead of time.

The export script handles this by:

- trying common container paths
- allowing `APP_ROOT` override
- allowing `INCLUDE_PATHS` override

If the upstream image layout changes, the export command may need an explicit `APP_ROOT` or broader include list.
