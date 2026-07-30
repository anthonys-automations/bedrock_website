# Image validation

[`.github/workflows/validate-build.yml`](../.github/workflows/validate-build.yml)
is the runtime validation for `bedrock_website` images. It is a build-only,
never-publishing workflow intended to catch failures on Renovate branches
before they can be automerged. The Renovate workflow dispatches it explicitly:
pushes made by the built-in `GITHUB_TOKEN` do not start workflows.

The job runs on `ubuntu-latest`, the same amd64 architecture as the release
build. It loads the image into the runner's Docker daemon rather than pushing
it, then starts the services below on a private Docker network:

- A throwaway `mariadb:11` container, with a health check and per-run random
  credentials.
- The image under test, configured with the generated `DB_*` values and a
  `WP_HOME`/`WP_SITEURL` of `https://bedrock.validate.local`.

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
| `http://127.0.0.1:8081/server-status?auto` | `200` | The Prometheus exporter sidecar's loopback telemetry endpoint remains available. |

The two `403` checks are successful security assertions. They are not ignored
failures. In contrast, the front-door and loopback requests must be exactly
`200`; accepting any response merely because curl connected allows HTTP 500 to
pass unnoticed.

The front-page response is also checked for the installed site's `<title>`, so
a response that has status `200` but does not render the WordPress application
still fails validation.

## Process and logging contract

The job additionally verifies that:

- Apache with `mod_php` is the only web runtime. `nginx`, `php-fpm`, and
  `supervisord` must not be installed.
- The running Apache configuration sends the error log to container stderr,
  exposes the loopback telemetry vhost, and writes the access log through
  `rotatelogs` with its bounded `3 x 50M` configuration.
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