<p align="center">
  <a href="https://roots.io/">
    <img alt="Roots" src="https://cdn.roots.io/app/uploads/logo-roots.svg" height="55">
  </a>
</p>
<h1 align="center"><strong>bedrock-docker</strong></h1>

bedrock-docker is a quick way create a [Bedrock](https://github.com/roots/bedrock/) WordPress install meant for testing and continous integration. It is not a full replacement for development environments like [Trellis](https://github.com/roots/trellis).

bedrock-docker was developed for integration tests in [Bud](https://github.com/roots/bud) and Bedrock itself.

## Quickstart

Run `./dev.sh` to clone `bedrock` and `sage` into `./bedrock`:

```sh
./dev.sh
```

Configure the `WP_HOME` and `WP_SITEURL` variables as needed in `.env`.

Build and run the container in the background:

```sh
docker compose up --build -d
```

Get a bash session going:

```sh
docker compose run bedrock bash
```

This bash session has access to `composer`, `node` and the wordpress cli.

Setup dev environment as needed:

```sh
cd web/app/themes/sage
composer install
yarn install
yarn build
wp theme activate sage
```

## Existing installs

1. Copy `build` and `docker-compose.yml` into the root of an existing bedrock install.
2. Edit `services.bedrock.volumes` in `docker-compose.yml` to reference the correct path. `./bedrock:/srv/bedrock` becomes `./:/srv/bedrock`.

## Container images

The container runs a single process: Apache with `mod_php`, started as PID 1 by
`build/bin/run.sh`. There is no nginx, no PHP-FPM and no supervisord, and no
MPM/worker tuning is carried in this repo - the upstream `php:<version>-apache`
defaults are used on purpose.

Ports:

- **80** - the front door. Public TLS is terminated upstream (Cloudflare, then
  the k8s ingress controller or a host reverse proxy), which forwards plain
  HTTP to the container.
- **443** - internal only. `run.sh` generates a self-signed certificate for
  `SITE_NAME`, installs it into the container's CA store and points `SITE_NAME`
  at `127.0.0.1`, so WordPress loopback/REST calls against the `https://` value
  of `WP_HOME` succeed without leaving the container. Nothing outside the
  container is expected to trust that certificate, and this port should not be
  published.

Apache configuration lives in [build/apache/bedrock.conf](build/apache/bedrock.conf).

### Logs

- **Errors** (Apache *and* PHP) go to the container's stderr, so `kubectl logs`
  or `docker logs` shows both in one stream. PHP's `error_log` is intentionally
  unset in [build/php/php.ini](build/php/php.ini) and `WP_DEBUG_LOG` is `false`
  in the environment configs; pointing either at a file hides application
  errors from the container log.
- **Access logs** are written inside the container to
  `/var/log/apache2/access.log` in `combined` format, rotated by `rotatelogs`
  at 50M with 3 files kept, since the container has no log rotation of its own.
  The k8s ingress remains the source of external access logs, so this file is
  for in-container inspection (`docker exec <container> tail -f
  /var/log/apache2/access.log`) and is lost when the container is replaced.
  Mount `/var/log/apache2` if it needs to outlive the container. The
  `php:<version>-apache` base image symlinks that path to `/dev/stdout`; the
  [Dockerfile](Dockerfile) deletes the symlink so it is a real, rotated file and
  access lines stay out of the error stream.
  Set the `ACCESS_LOG` container variable to `off` (also accepted: `false`,
  `0`, `no`) to disable this local copy entirely - no file is written and no
  `rotatelogs` child is started. It defaults to `on`, and an unrecognised value
  logs a warning and keeps logging on. Error logging is not affected.

### Telemetry

Apache exposes `mod_status` at `http://127.0.0.1:8081/server-status?auto`
(`ExtendedStatus` on). The port is loopback-only and carries nothing else, so it
is unreachable through the ingress and cannot collide with the WordPress
rewrite; `/server-status` is explicitly denied on the public vhosts.

Apache has no native Prometheus format, so scraping needs an exporter. Run it as
a sidecar rather than adding a second process to this image:

```yaml
- name: apache-exporter
  image: bitnami/apache-exporter:1.0.10
  args:
    - --scrape_uri=http://127.0.0.1:8081/server-status?auto
  ports:
    - name: metrics
      containerPort: 9117
```

Containers in a pod share the network namespace, so the sidecar reaches the
loopback port and Prometheus scrapes the sidecar's `:9117/metrics`. This yields
worker/scoreboard state, request and byte counters, and uptime - enough to see
saturation of the prefork pool. Per-request latency and status codes still come
from the ingress metrics.

Published images use an immutable, architecture-scoped calendar version:

```text
anthonysautomations/bedrock_website:<YYYY>.<MM>.<DD>.<N>-<arch>
```

- `amd64` is built by CI (`.github/workflows/image_build.yml`) on push to `dev`/`main` and weekly.
- `arm64` is built by hand with `./scripts/build-arm64.sh`.
- `latest-<arch>` is a convenience alias only. **Never deploy it**, and note that the plain `latest` tag is no longer updated.
- The pinned PHP base image is bumped automatically by Renovate (`.github/workflows/renovate.yml`, policy in `renovate.json`).

See [docs/image-versioning.md](docs/image-versioning.md) for the full tag contract, provenance metadata and updater setup.

## Community

Keep track of development and community news.

- Join us on Roots Slack by becoming a [GitHub
  sponsor](https://github.com/sponsors/roots)
- Participate on the [Roots Discourse](https://discourse.roots.io/)
- Follow [@rootswp on Twitter](https://twitter.com/rootswp)
- Read and subscribe to the [Roots Blog](https://roots.io/blog/)
- Subscribe to the [Roots Newsletter](https://roots.io/subscribe/)
