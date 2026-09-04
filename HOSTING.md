# Hosting and migration notes

AZHDAR used to be served from a File Browser instance at `dl.digitsell.shop`
(share `gZ1XGygF` for releases, share `Wf-XKNL9` for the Mimic `.deb` mirror).
That host is no longer required: everything now lives in this repository.

## What moved here

| Old location | New location |
| --- | --- |
| `dl.digitsell.shop/api/public/dl/gZ1XGygF/install` | `install` (repository root) |
| `dl.digitsell.shop/.../gZ1XGygF/azhdar-X.Y.Z.zip` | `dist/azhdar-X.Y.Z.zip` (every release, 3.1.15 – 3.2.30) |
| `dl.digitsell.shop/.../Wf-XKNL9/*.deb` | `assets/*.deb` |

Each release is also a commit tagged `vX.Y.Z`, so `git show v3.2.14` gives the
exact source of that build.

## Installing

The repository is public, so the installer needs no credentials:

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/m0000hamad/AZHDAR/contents/install" | sudo bash
```

The installer resolves the newest `dist/azhdar-X.Y.Z.zip` through the GitHub
contents API and runs `scripts/install.sh` from it.

`AZHDAR_GH_TOKEN` is still honoured and is only useful for raising the GitHub
API rate limit, or if you run this from a private fork. When set, the installer
saves it to `/etc/azhdar/gh.token` (mode 600) so the updater reuses it; delete
that file to stop using it.

Being publicly readable is not permission to redistribute. See LICENSE.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `AZHDAR_GH_TOKEN` | – | Read-only token; falls back to `/etc/azhdar/gh.token` |
| `AZHDAR_GH_TOKEN_FILE` | `/etc/azhdar/gh.token` | Alternate token path |
| `UPDATE_BASE_URL` | `https://github.com/m0000hamad/AZHDAR` | Self-update source; also accepts an `api.github.com/.../contents/<dir>` URL or any plain directory listing that serves `azhdar-X.Y.Z.zip` |
| `ASSET_MIRROR_BASE` | `https://api.github.com/repos/m0000hamad/AZHDAR/contents/assets` | Mimic `.deb` mirror |
| `AZHDAR_DIST_MIRROR` | – | Installer-only fallback: a plain directory URL serving the release zips |

Existing installs that still carry a `dl.digitsell.shop` value in
`/etc/azhdar/global.env` are reset to the GitHub defaults automatically on the
next run.

## If GitHub is filtered on the servers

`api.github.com` is the only GitHub host the code talks to. When it is
unreachable, point the two variables above at any reachable proxy or mirror —
they accept plain directory URLs, so a simple static file server holding
`dist/` and `assets/` is enough:

```bash
export AZHDAR_DIST_MIRROR="https://mirror.example.com/azhdar/dist"
export UPDATE_BASE_URL="https://mirror.example.com/azhdar/dist"
export ASSET_MIRROR_BASE="https://mirror.example.com/azhdar/assets"
```

Those can also be written into `/etc/azhdar/global.env` so they survive updates.
