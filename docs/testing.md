# Image validation

[`.github/workflows/validate-build.yml`](../.github/workflows/validate-build.yml)
is the runtime validation for `bedrock_website` images. It is a build-only,
never-publishing workflow intended to catch failures on Renovate branches
before they can be automerged. The Renovate workflow dispatches it explicitly:
pushes made by the built-in `GITHUB_TOKEN` do not start workflows.

The job runs once per published architecture, on `ubuntu-latest` (amd64) and
`ubuntu-24.04-arm` (arm64) — the same native runners the release build uses. The
release fails closed when either architecture cannot build, so a base image bump
that only breaks one of them has to be caught here rather than turning into a
silently missing release. Each job loads the image into its runner's Docker
daemon rather than pushing it, then starts the services below on a private
Docker network:

- A throwaway `mariadb:11` container, with a health check and per-run random
  credentials.
- The image under test, configured with the generated `DB_*` values and a
  `WP_HOME`/`WP_SITEURL` of `https://bedrock.validate.local`, started with
  `--add-host bedrock.validate.local:127.0.0.1`. The unprivileged container
  cannot write its own `/etc/hosts`, so this stands in for the chart's
  `hostAliases` and makes the loopback assertion below meaningful.

WordPress is installed through its `install.php?step=2` endpoint. This is
intentional: without a database the front page returns HTTP 500, which only
tests that Apache can expose WordPress's error page. A valid test must exercise
a rendered WordPress page.

## Runtime contract

The workflow requires these exact HTTP results:

| Request | Expected result | Reason |
| --- | --- | --- |
| Port 80, with `Host: bedrock.validate.local` and `X-Forwarded-Proto: https` | `200` | Models Cloudflare/ingress TLS termination and verifies the public front door renders WordPress. |
| `https://bedrock.validate.local/` inside the container | `200` | Confirms the generated loopback certificate is trusted and the hostname resolves to Apache. |
| `/app/uploads/probe.php` | `403` | PHP must never execute from the uploads volume. |
| `/server-status` on the public vhost | `403` | `mod_status` must not be exposed through ingress. |
| `/wp-json/prompress/v1/metrics` and `/wp-json/prompress/v1/storage/wipe` on the public vhost | `403` | PromPress serves its metrics unauthenticated unless a token is configured, and registers `storage/wipe` with no permission callback at all, so neither route may reach ingress. |
| `http://127.0.0.1:9118/` | `403` | The dedicated PromPress metrics listener denies everything but the one route it exists for. |
| `http://127.0.0.1:9118/wp-json/prompress/v1/metrics` | `404` | Anything other than `403` proves the request survived both authorization passes: the scrape itself, and the internal redirect to `/index.php` that the front controller rewrite triggers. It is `404` rather than `200` because the plugin ships in the image but a fresh install leaves it deactivated, so WordPress has no such route. |
| `http://127.0.0.1:8081/server-status?auto` | `200` | The Prometheus exporter sidecar's loopback telemetry endpoint remains available. |

The `403` checks are successful security assertions. They are not ignored
failures. In contrast, the front-door and loopback requests must be exactly
`200`; accepting any response merely because curl connected allows HTTP 500 to
pass unnoticed.

The front-page response is also checked for the installed site's `<title>`, so
a response that has status `200` but does not render the WordPress application
still fails validation.

## Process and logging contract

The job additionally verifies that:

- No process in the container runs as uid 0, and PID 1 holds an empty
  capability set. The container under test is started with `--cap-drop ALL`,
  `--security-opt no-new-privileges=true`,
  `--sysctl net.ipv4.ip_unprivileged_port_start=0`, `--read-only` and the same
  writable-path mounts the chart declares (the `HARDENING` variable in the
  workflow env), which is the chart's security context expressed in Docker: the
  front-door and loopback checks then prove that an unprivileged Apache really
  can bind :80 and :443 under exactly the privileges the cluster grants, rather
  than under the daemon's defaults.
- The root filesystem rejects a write, outbound HTTPS still verifies against
  the immutable system trust store, and a `wp_remote_get()` with certificate
  verification enabled succeeds over the generated loopback certificate.
- Apache with `mod_php` is the only web runtime. `nginx`, `php-fpm`, and
  `supervisord` must not be installed.
- The `redis` PHP extension is loaded. PromPress keeps its Prometheus counters
  in Redis and disables itself with nothing but an admin notice when the
  extension is missing, so dropping it from the Dockerfile would otherwise
  surface only as silently absent metrics.
- The running Apache configuration sends the error log to container stderr,
  exposes the loopback telemetry vhost and the PromPress metrics listener on
  port 9118, and writes the access log through `rotatelogs` with its bounded
  `3 x 50M` configuration.
- PHP fatal errors, parse errors, and warnings in container stderr fail the
  workflow, even if the HTTP checks returned `200`. PHP deprecations and
  notices are printed as GitHub warnings so a dependency bump can be reviewed
  without treating a non-fatal compatibility notice as an outage.
- Access logs are a non-empty regular file at
  `/var/log/apache2/access.log`, rather than the base image's `/dev/stdout`
  symlink, and access lines do not appear in container stdout.
- PID 1 handles `SIGTERM` and exits with code `0`.
- With `ACCESS_LOG=off`, the site still serves `200`, no access-log file is
  created, and no `rotatelogs` child is running.

On failure, the workflow retains enough state to diagnose the run before
cleanup: database logs, application logs, process lists, Apache log-directory
contents, vhost configuration, and a verbose front-door request are printed.

## Running locally

The CI workflow uses GitHub Actions environment files and generated credentials,
so the most faithful local check is to dispatch it from GitHub. For a direct
Docker smoke test, build the same image first:

```sh
docker build -t bedrock_website:validate \
  --build-arg GIT_COMMIT="$(git rev-parse HEAD)" .
```

Then start a MariaDB container and the image on an isolated Docker network,
using the values and request assertions from
[`validate-build.yml`](../.github/workflows/validate-build.yml). Do not use a
database-free `curl /` check as a substitute: it deliberately reproduces the
old false-green condition where WordPress returned `500` but the validation job
passed.