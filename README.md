# container-registry.sh

**Pull and push container images from OCI/Docker registries without the Docker daemon.**

Pure shell (curl + jq). Domain: **container-registry.sh**

## Install

Same style as [acme.sh](https://github.com/acmesh-official/acme.sh):

```bash
curl https://get.container-registry.sh | sh -s
```

Or with wget:

```bash
wget -qO- https://get.container-registry.sh | sh -s
```

This installs `container-registry.sh` into `~/.local/bin`. Add to PATH if needed:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Override install directory:

```bash
INSTALL_DIR=/usr/local/bin curl https://get.container-registry.sh | sh -s
```

The installer **does not** install dependencies (curl, jq, tar, gzip). If any are missing it will exit with a message. To try automatic install of deps (apt/dnf/yum/apk/brew):

```bash
INSTALL_DEPS=1 curl https://get.container-registry.sh | sh -s
```

To install from a specific URL (e.g. GitHub raw):

```bash
SCRIPT_URL=https://raw.githubusercontent.com/OWNER/REPO/main/container-registry.sh curl https://get.container-registry.sh | sh -s
```

## Requirements

- **curl** – HTTP
- **jq** – JSON
- **tar** – archives
- **gzip** – optional (for `.tar.gz` on pull)

## Commands

### pull

Download an image from a registry into a Docker-format tar (or `.tar.gz`).

```bash
container-registry.sh pull [OPTIONS] IMAGE [OUTPUT]

# Examples
container-registry.sh pull alpine:3.19
container-registry.sh pull alpine:3.19 -o alpine.tar.gz
container-registry.sh pull -o img.tar --no-gzip docker.io/library/nginx:alpine
container-registry.sh pull -u user:token ghcr.io/myorg/private:v1
```

| Option       | Description |
|-------------|-------------|
| `-o FILE`   | Output path (default: `<repo>_<tag>.tar` or `.tar.gz`) |
| `--no-gzip` | Write uncompressed `.tar` |
| `-u USER[:PASSWORD]` | Registry credentials |
| `-q`        | Quiet |

### push

Upload a Docker-format tar (from `pull` or `docker save`) to a registry.

```bash
container-registry.sh push [OPTIONS] IMAGE FILE.tar[.gz]

# Examples
container-registry.sh push -u user:token ghcr.io/myorg/img:v1 image.tar.gz
container-registry.sh push localhost:5000/myimg:tag myimg.tar
```

Push requires authentication (`-u`). The archive must be in Docker save format (e.g. from `container-registry.sh pull` or `docker save`).

| Option | Description |
|--------|-------------|
| `-u USER[:PASSWORD]` | Registry credentials (required for push) |
| `-q`   | Quiet |

## Image reference

- `[REGISTRY/]REPOSITORY[:TAG|@sha256:DIGEST]`
- Default registry: Docker Hub (`registry-1.docker.io`)
- Default tag: `latest`
- Short names (e.g. `alpine`) → `library/alpine` on Docker Hub

## Output format (pull)

Same layout as `docker save`:

- `manifest.json` – config and layer list
- `<config_sha>.json` – image config
- `<layer_sha>/layer.tar` – layer blobs

Load with Docker: `docker load -i output.tar.gz`

## How it works

- **pull**: GET manifest (handles multi-arch), GET config and layer blobs, write Docker-format tar.
- **push**: Extract tar, GET token with push scope, HEAD blobs (skip if exist), POST blob upload, PUT blob with digest, PUT manifest.
- **Auth**: On 401, parse `WWW-Authenticate`, request Bearer token, retry. Credentials via `-u` for private/push.

No Docker binary or daemon is used.
