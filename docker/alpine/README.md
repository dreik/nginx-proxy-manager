# Alpine + OpenResty image

Optional production image for nginx-proxy-manager. Builds OpenResty from source on Alpine Linux and replaces s6-overlay with shell entrypoint scripts (`tini` + `su-exec`).

The official published image (`docker/Dockerfile`, Debian + `nginx-full` + s6) is unchanged. This path is additive.

## Versions

Pin OpenResty, Alpine, and geoip2 in [`versions.env`](versions.env), or override at build time:

```bash
OPENRESTY_VERSION=1.27.1.2 ./scripts/buildx-alpine-openresty --load -t local/nginx-proxy-manager:alpine-openresty
```

| Variable | Default | Notes |
|----------|---------|-------|
| `OPENRESTY_VERSION` | `1.29.2.5` | GitHub tag on openresty/openresty |
| `ALPINE_VERSION` | `3.24` | Base image |
| `GEOIP2_REF` | commit SHA | Pinned ngx_http_geoip2_module |
| `CERTBOT_VERSION` | _(unset)_ | Optional build-arg to pin certbot |
| `USE_LTO` | `0` | Enable LTO in OpenResty build |
| `JOBS` | `2` | Parallel make jobs for OpenResty |

## Build

Single platform (load into local Docker):

```bash
PLATFORMS=linux/amd64 ./scripts/buildx-alpine-openresty --load -t local/nginx-proxy-manager:alpine-openresty
```

Multi-arch manifest (push to a registry):

```bash
PLATFORMS=linux/amd64,linux/arm64 ./scripts/buildx-alpine-openresty --push -t your/repo/nginx-proxy-manager:alpine-openresty
```

Direct `docker build` also works:

```bash
docker build -f docker/Dockerfile.alpine-openresty -t local/nginx-proxy-manager:alpine-openresty .
```

## Run

Same ports and volumes as the official image:

```bash
docker run -d --name npm-alpine \
  -p 80:80 -p 81:81 -p 443:443 \
  -v ./data:/data \
  -v ./letsencrypt:/etc/letsencrypt \
  local/nginx-proxy-manager:alpine-openresty
```

Supported env vars match the s6 image: `PUID`, `PGID`, `NPM_ADMIN_PORT`, `DISABLE_IPV6`, `DISABLE_RESOLVER`, `INITIAL_ADMIN_*`, `VAR__FILE` secrets, and others handled in `prepare.sh`.

## Test

Manual integration tests (not wired into CI):

```bash
# Start a test container with published ports for external checks
docker run -d --name npm-alpine-test \
  -p 8181:81 -p 8080:80 -p 8443:443 \
  -v ./data:/data -v ./letsencrypt:/etc/letsencrypt \
  local/nginx-proxy-manager:alpine-openresty

./docker/alpine/fulltest.sh
```

Skip auxiliary container tests:

```bash
SKIP_ISOLATED=1 ./docker/alpine/fulltest.sh
```

## Design notes

- **OpenResty source build** — GitHub tag + `mirror-tarballs`. The nginx tarball URL is rewritten to `nginx.org` because `openresty.org/download` often stalls.
- **GeoIP2 module** — Built as a dynamic module; `00-geoip2.conf` is generated so `include /etc/nginx/modules/*.conf` works.
- **Certbot DNS plugins** — `/opt/certbot` venv keeps `pip`. Runtime image includes `build-base` and Python dev headers so the `npm` user can `pip install` plugins without root `apk`. This adds image size but matches upstream behavior for on-demand plugin installs on musl.
- **Init** — `entrypoint.sh` runs `prepare.sh` (user/group, paths, admin port, resolvers, secrets, ownership) then `start.sh` (nginx + Node under `su-exec`).
- **Log rotation** — Same as official: backend timer calls `logrotate` every two days.
