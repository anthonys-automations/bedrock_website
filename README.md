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

`mod_status` says nothing about individual requests, though, and the in-container
access log (see above) is otherwise only reachable with `docker exec`/`kubectl
exec`. Two more sidecars, sharing an `emptyDir` mounted at `/var/log/apache2`
with the main container, cover that:

- an **access-log-tail** sidecar that just `tail -F`s `access.log` to its own
  stdout, so the access log is visible via `kubectl logs -c access-log-tail`
  (or any node-level log collector watching container stdout) without mixing
  into the main container's error stream.
- an **access-log-exporter** sidecar running
  [mtail](https://github.com/google/mtail) against the same file, turning each
  `combined`-format line into Prometheus counters (requests/bytes by method,
  HTTP version and status) independently of what `mod_status` can report.

Neither of those knows anything about WordPress itself. That layer is covered by
the [PromPress](https://wordpress.org/plugins/prompress/) plugin
(`wpackagist-plugin/prompress`), which instruments WordPress from the inside and
exposes request counts and durations, peak memory, query counts and durations,
outbound request timings, emails sent, error counts, and post/user/option totals
— things no external exporter can see.

It needs two pieces of infrastructure, both already wired up:

- The **`redis` PHP extension** (added in the [Dockerfile](Dockerfile)). This is
  not optional: the plugin checks for it and, if it is missing, disables itself
  with nothing but an admin notice. The build validation workflow asserts the
  extension is present so it cannot be dropped silently.
- A **Redis instance** to accumulate metrics across PHP requests. The plugin
  talks to Redis directly rather than through WordPress' object cache, and
  falls back to `127.0.0.1:6379` when `WP_REDIS_HOST`/`WP_REDIS_PORT` are
  undefined — so a Redis sidecar bound to loopback needs no configuration at
  all. Bound to loopback it is also unreachable from the cluster network, which
  is why it needs no password and therefore no Secret. Persistence is off:
  counter resets on pod restart are normal and handled by `rate()`.

The plugin's REST routes are **not** served on the public vhosts.
`/wp-json/prompress/v1/metrics` is unauthenticated unless a token is set in
wp-admin, and `/wp-json/prompress/v1/storage/wipe` is registered with *no
permission callback at all*, so anything that can reach it can reset the site's
counters. [build/apache/bedrock.conf](build/apache/bedrock.conf) therefore denies
the whole `/wp-json/prompress` prefix at server scope — `:80` and `:443` return
403 — and re-allows only the read-only metrics route on a dedicated listener,
port **9118**, the same belt-and-braces shape used for `mod_status`. That
re-allow matches on the original request line rather than the current URI,
because the front controller rewrite makes Apache authorize the scrape twice:
once as `/wp-json/...` and again as `/index.php`.

Unlike the `mod_status` listener, 9118 is bound to all interfaces, because
Prometheus scrapes it from outside the pod. It exposes that one route and
nothing else; restrict who may connect to it with a NetworkPolicy.

Two costs to weigh, since this is in-process instrumentation rather than an
external poller: every page load now does Redis writes, and every scrape is a
full WordPress bootstrap — so keep that scrape interval modest. Note also that
the plugin has not been tested against the last few WordPress releases; since
this project pins nothing (`>0` constraints, no committed lockfile), verify it
after WordPress major upgrades.

The Helm chart below contains the complete deployment, including the mtail
program, Redis sidecar, and probes for the main container.

Published images use an immutable, architecture-scoped calendar version:

```text
anthonysautomations/bedrock_website:<YYYY>.<MM>.<DD>.<N>-<arch>
```

- `amd64` is built by CI (`.github/workflows/image_build.yml`) on push to `dev`/`main` and weekly.
- `arm64` is built by hand with `./scripts/build-arm64.sh`.
- `latest-<arch>` is a convenience alias only. **Never deploy it**, and note that the plain `latest` tag is no longer updated.
- The pinned PHP base image is bumped automatically by Renovate (`.github/workflows/renovate.yml`, policy in `renovate.json`). Renovate also tracks the telemetry sidecar images pinned in the chart's templates, and bumps the chart `version` in the same commit; the main image is excluded there, since its rollout is the deliberate `appVersion` bump below.

See [docs/image-versioning.md](docs/image-versioning.md) for the full tag contract, provenance metadata and updater setup.

## Deploying

[charts/bedrock-website](charts/bedrock-website) is the Helm chart the live
sites are deployed from. It renders the manifest shape documented above -
Deployment (main container plus the four telemetry sidecars), Service,
HTTPRoute and the mtail ConfigMap - and is deliberately narrow: everything the
sites share is fixed in the templates, the image tag is the chart's
`appVersion`, and per-site values configure the public hostname, the existing
database-password Secret, and container resource sizing.

The included Kustomize example inflates the chart with `valuesInline` rather
than a Helm values file:

- [charts/bedrock-website/examples/anthonysautomations-prod](charts/bedrock-website/examples/anthonysautomations-prod)

The chart also creates a `grafana_dashboard: "1"` ConfigMap named
`<release>-grafana-dashboard`. Configure Grafana's dashboard sidecar to watch
that label in the release namespace; it provisions **Bedrock Website
Telemetry**, covering Apache exporter, mtail access-log, and PromPress metrics.
The dashboard has separate target selectors for each exporter and a Prometheus
datasource selector. This prevents cross-site aggregation when one Grafana
instance serves multiple releases.

Prometheus annotation-based discovery is enabled through three dedicated
Services: `<release>-metrics-apache`, `<release>-metrics-log`, and
`<release>-metrics-wp`. Each carries the standard `prometheus.io/scrape`,
`prometheus.io/path`, and `prometheus.io/port` annotations for its one metric
endpoint. The PromPress Service also requests a 60-second interval because a
scrape performs a full WordPress bootstrap. The Prometheus Kubernetes service
discovery configuration must honor these annotations.

The `resources` value has a block for `bedrock`, `apacheExporter`,
`accessLogTail`, `accessLogExporter`, and `redis`. Its defaults match the
previous fixed resource requests and limits; override only the needed block in
a site overlay to tune it for that cluster.

The HTTPRoute is rendered by default; set `httpRoute: false` where routing is
owned elsewhere or the Gateway API CRDs are absent.

```sh
kubectl kustomize --enable-helm --load-restrictor LoadRestrictionsNone \
  charts/bedrock-website/examples/anthonysautomations-prod | kubectl apply -f -
```

`--enable-helm` is what runs `helm template`; `--load-restrictor
LoadRestrictionsNone` is needed because the chart sits outside the example
directory (`helmGlobals.chartHome: ../../..`), which Kustomize refuses
by default.

Resource names are named after `releaseName`, which must therefore stay the name
the site is already deployed under: the `envFrom` Secret, the uploads `subPath`
on the shared `wordpress-data` claim and the Deployment's (immutable) label
selector all derive from it.

Rolling out a new image is an `appVersion` bump in
[charts/bedrock-website/Chart.yaml](charts/bedrock-website/Chart.yaml), pinned
to an immutable tag - never `latest`. The `version` field next to it is the
chart's own version and moves whenever the templates or values change; Renovate
bumps its patch level itself when it updates a sidecar image. Add another
directory under `charts/bedrock-website/examples` for a site that only needs
different values; a site that needs anything else to differ does not belong in
this chart as it stands.

This path never creates a Helm release - Kustomize only templates the chart and
`kubectl apply` owns the result. If you instead install the chart with Helm
directly over resources that are already deployed, the first run has to adopt
them, which Helm refuses without:

```sh
helm upgrade --install --take-ownership anthonysautomations-prod \
  charts/bedrock-website \
  --set hostname=www.anthonysautomations.com \
  --set dbPasswordSecret=anthonysautomations-dbpassword
```


## Community

Keep track of development and community news.

- Join us on Roots Slack by becoming a [GitHub
  sponsor](https://github.com/sponsors/roots)
- Participate on the [Roots Discourse](https://discourse.roots.io/)
- Follow [@rootswp on Twitter](https://twitter.com/rootswp)
- Read and subscribe to the [Roots Blog](https://roots.io/blog/)
- Subscribe to the [Roots Newsletter](https://roots.io/subscribe/)
