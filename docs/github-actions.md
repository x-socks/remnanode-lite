# GitHub Actions Deployment

Yes, GitHub Actions is a reasonable control plane for this project.

The intended split is:

1. GitHub Actions exports the runtime bundle from the upstream Docker image.
2. Actions stores the bundle as a workflow artifact, and optionally as a GitHub release asset.
3. Actions can optionally SSH into the Alpine host, install host helpers, install the runtime bundle, and restart the service.

The workflow is in [.github/workflows/runtime-bundle.yml](../.github/workflows/runtime-bundle.yml).

If you want the workflow to create GitHub releases, the workflow token must have release write access. This repository workflow requests:

- `contents: write`

If release creation still fails with `Resource not accessible by integration`, check the repository setting:

- `Settings` -> `Actions` -> `General` -> `Workflow permissions`
- choose `Read and write permissions`

When `publish_release=true`, each release contains both stamped assets and stable alias assets:

- `remnanode-runtime-latest.tar.gz`
- `remnanode-host-tools-latest.tar.gz`

The stable names are intended for pull-based updates on the Alpine host.

The current pull-based scripts assume the repository release assets are publicly downloadable.

## Required Repository Secrets For Remote Deploy

- `DEPLOY_HOST`
- `DEPLOY_PORT`
- `DEPLOY_USER`
- `DEPLOY_SSH_KEY`

Optional:

- `DEPLOY_KNOWN_HOSTS`

If `DEPLOY_KNOWN_HOSTS` is not set, the workflow falls back to `ssh-keyscan`.

`DEPLOY_USER` should normally be `root`. If it is not, that user needs write access to `/etc`, `/usr/local/bin`, `/opt/remnanode`, `/var/log`, and permission to restart OpenRC services.

## Manual Run Inputs

- `image_ref`: upstream image to export
- `app_root`: optional override if the container app root is not auto-detected
- `include_paths`: optional override for copied runtime paths
- `publish_release`: publish runtime and host-tools bundles as release assets
- `deploy_host`: push the bundles to the Alpine host and run bootstrap/update
- `base_dir`: install target, default `/opt/remnanode`
- `restart_service`: restart `remnanode` after remote install

## Practical Deployment Modes

Artifact only:

- export the runtime bundle
- store it in the workflow run
- download and install manually later

Release asset:

- export both bundles
- publish them as a GitHub release
- useful if you want the host or an external script to fetch a known asset later

Direct remote deploy:

- export both bundles
- copy them to the Alpine host over SSH
- run `bootstrap-host.sh` remotely
- optionally restart `remnanode`

Pull-based host updates:

- publish the stable release assets from GitHub Actions
- let the Alpine host download `releases/latest/download/...`
- install the runtime locally without any CI-to-host SSH session

## Recommended First Rollout

For the first host bring-up:

- run the workflow with `deploy_host=true` and `restart_service=false`
- inspect `/etc/remnanode/remnanode.env`
- copy the panel-provided `SSL_CERT=...` line into `/etc/remnanode/remnanode.env`
- set `APP_PORT` to the same Node Port configured in the panel
- verify Xray paths and any remaining app-specific variables
- start the service manually once the env is correct

After the first successful deployment, later updates can use `restart_service=true`.

## No-Extra-Host Model

If you do not want GitHub Actions to SSH into the VPS:

1. Run the workflow with `publish_release=true`.
2. On the Alpine host, bootstrap once from the latest release assets.
3. For later upgrades, run `/usr/local/bin/remnanode-update-from-github`.

This keeps GitHub Actions as the build and release plane only, while the VPS pulls updates itself.

For the first rollout in this model:

- run the workflow with `publish_release=true`
- on the Alpine host run the bootstrap script against your GitHub repo
- verify `/etc/remnanode/remnanode.env`
- add the panel-provided `SSL_CERT=...` line
- set `APP_PORT` to the panel Node Port
- start `remnanode` manually

If you prefer an interactive host-side installer, use:

```sh
curl -fsSL -o /tmp/one-click-deploy.sh \
  https://raw.githubusercontent.com/x-socks/remnanode-lite/main/scripts/one-click-deploy.sh
sh /tmp/one-click-deploy.sh
```

That script:

- installs `nodejs`, `gcompat`, and `unzip` on Alpine
- installs the latest Xray release for the current CPU architecture
- downloads the latest host-tools and runtime bundles from GitHub Releases
- prompts for `APP_PORT` and `SSL_CERT`
- writes `/etc/remnanode/remnanode.env`
- installs and starts the `remnanode` OpenRC service

## Limitation

The workflow can automate runtime delivery and host bootstrap, but it cannot guess missing Remnanode application env values.

You still need to define the app-specific values in:

- `/etc/remnanode/remnanode.env`

For the current `@remnawave/node` runtime, that explicitly includes:

- `APP_PORT`
- `SSL_CERT`

That is why the first rollout should usually avoid auto-restart until the env file is confirmed.

For private repositories, the pull-based host scripts would need authenticated GitHub API downloads instead of anonymous `latest/download/...` URLs.
