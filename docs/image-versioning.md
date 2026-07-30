# Container image versioning

How `anthonysautomations/bedrock_website` images are versioned, built and kept
up to date. The portable design rationale this implements is in
[renovate.example/image-versioning.md](renovate.example/image-versioning.md);
this page records the choices made for *this* repository.

## Why it changed

The previous pipeline published `latest`, an ISO-timestamp tag and whatever
`IMAGE_TAG` the caller passed, and deployments used `latest`. That is mutable:
the running artefact changed underneath a pinned reference, there was no
rollback target, and an automated updater had nothing to raise a pull request
against. Almost every release of this image contains no source change at all —
what moves is the PHP base image, its Debian packages, and the plugin versions
that `composer update` resolves during the build — so a source-derived version
would not change either.

## Tag contract

```text
<YYYY>.<MM>.<DD>.<N>-<arch>        e.g. 2026.07.30.1-amd64
```

| Field | Meaning |
| --- | --- |
| `YYYY.MM.DD` | UTC date of the build |
| `N` | 1-based sequence within that date and architecture |
| `arch` | `amd64` or `arm64` |

| Tag | Mutability | Role |
| --- | --- | --- |
| `2026.07.30.1-amd64` | immutable | deployable release — pin this |
| `latest-amd64` / `latest-arm64` | moving | human convenience only, never deploy |
| `latest` / unsuffixed version | reserved | future promoted multi-architecture manifest |

Rules:

- Release tags are never overwritten; the allocator verifies the tag is unused
  and aborts otherwise.
- Each architecture allocates its versions independently. A manual arm64 build
  made weeks after an amd64 build resolves different packages, so giving it the
  amd64 version would assert an equivalence that does not exist.
- No single-architecture pipeline publishes an unsuffixed tag. Those are
  reserved for a manifest that genuinely contains every architecture.
- All timestamps are UTC.

## Multi-architecture split

| Architecture | Produced by | Cadence |
| --- | --- | --- |
| `amd64` | [.github/workflows/image_build.yml](../.github/workflows/image_build.yml) on `ubuntu-latest` | on push to `dev`/`main`, weekly cron, manual dispatch |
| `arm64` | [scripts/build-arm64.sh](../scripts/build-arm64.sh), run by hand | irregular |

Both allocate versions through the same
[scripts/next-version.sh](../scripts/next-version.sh), so the manual
architecture obeys exactly the same contract as CI. That shared script — rather
than inline workflow steps — is the reason the two cannot drift apart.

Building arm64 by hand:

```sh
export DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=...
./scripts/build-arm64.sh
```

It refuses to publish from a dirty working tree (override with `ALLOW_DIRTY=1`,
which makes the recorded commit a lie — avoid for real releases), and requires a
buildx builder that can produce `linux/arm64`:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

## Version allocation

Immediately before each build, `next-version.sh <repo> <arch>`:

1. Lists Docker Hub tags for the current UTC date using the server-side `name`
   prefix filter.
2. Takes the highest `N` already used for that date *and* architecture, and
   returns `N+1`.
3. Verifies the resulting tag does not exist, and aborts if it does.

It is deliberately fail-closed: only a registry-confirmed HTTP 404 (repository
does not exist yet) counts as "no tags". A failed or malformed listing aborts,
because treating it as empty could allocate a version that sorts *older* than
one already published — which an updater would never offer as an update.

The amd64 job sets a `concurrency` group so two runs on the same day cannot race
for the same sequence number. The manual script does not serialise itself; run
only one at a time.

## Provenance

The tag stays short; detail lives in metadata:

| Label | Value |
| --- | --- |
| `org.opencontainers.image.title` | `bedrock_website` |
| `org.opencontainers.image.version` | allocated version, no arch suffix |
| `org.opencontainers.image.revision` | source commit SHA |
| `org.opencontainers.image.source` | repository URL |
| `org.opencontainers.image.created` | RFC 3339 UTC build time |
| `io.anthonysautomations.php.version` | pinned PHP base image version |

The commit is also baked in as the `GIT_COMMIT` environment variable, declared
in the [Dockerfile](../Dockerfile) *after* the package and Composer layers so a
new commit does not invalidate them:

```sh
docker exec <container> printenv GIT_COMMIT
```

Treat both that variable and the `revision` label as best-effort — an
environment variable can be overridden by a container spec, and either is only
correct if the build came from a clean tree. The image digest is the
authoritative audit record.

Installed packages are not looked up from a separately pulled base image; that
query and the real build can resolve different package-index snapshots. Instead
both builds enable a BuildKit SBOM attestation generated from the image that is
actually pushed:

```sh
docker buildx imagetools inspect --format '{{ json .SBOM }}' \
  anthonysautomations/bedrock_website:2026.07.30.1-amd64
```

## Consuming the images

Deployments must pin an immutable release tag.
[release.yml](../.github/workflows/release.yml) only *publishes* an image on
push; it does not roll anything out. Deploying is a separate, deliberate step:
dispatch [container_deploy.yml](../.github/workflows/container_deploy.yml) with
the release tag, which feeds `IMAGE_TAG` in
[docker-compose.yml](../docker-compose.yml).

**Migration note:** the plain `latest` tag is no longer updated. Anything still
pulling `anthonysautomations/bedrock_website:latest` is now pinned to a stale
image and must be repointed to an immutable, architecture-scoped tag.

An external repository tracking these images with Renovate needs:

```yaml
# renovate: datasource=docker depName=anthonysautomations/bedrock_website versioning=regex:^(?<major>\d{4})\.(?<minor>\d{2})\.(?<patch>\d{2})\.(?<build>\d+)(?:-(?<compatibility>amd64|arm64))?$
image: anthonysautomations/bedrock_website:2026.07.30.1-arm64
```

The architecture suffix is captured as `compatibility`, which Renovate requires
to match between current and candidate versions, so an arm64 deployment is never
offered an amd64 image.

## Keeping the base image current

Pinning `php:8.2.32-apache` removes silent drift, so an updater has to replace it.
[.github/workflows/renovate.yml](../.github/workflows/renovate.yml) runs
self-hosted Renovate weekly (Friday 03:00 UTC) against this repository, with
policy in [renovate.json](../renovate.json).

Three things about that setup are easy to get wrong:

- **It uses the built-in `GITHUB_TOKEN`**, not a PAT. No secret to rotate, but
  its pushes start no workflow runs and it cannot write under
  `.github/workflows`. Actions version bumps are therefore routed to the
  dependency dashboard for manual application. It also cannot read Dependabot
  alerts — that is a GitHub App permission with no equivalent key in a
  workflow's `permissions:` block — so `vulnerabilityAlerts` is disabled in
  `renovate.json`; leaving it on only logged `Cannot access vulnerability
  alerts` on every run. Granting it would require a PAT with the
  `security_events` scope.
- **Automerge needs a check that actually runs.** Because bot pushes trigger
  nothing, the workflow explicitly dispatches
  [validate-build.yml](../.github/workflows/validate-build.yml) on each
  `renovate/*` branch. An API-triggered dispatch *is* allowed to run, so its
  check lands on the branch head and Renovate merges on a following run once it
  is green. See [testing.md](testing.md) for the validation contract.
- **Renovate exits 0 when it fails.** An invalid config key or an auth rejection
  produces a green job that did nothing. The workflow therefore runs
  `renovate-config-validator --strict` first, and afterwards asserts on the
  structured log that no error-level record was written and the repository
  result is `done`.

`bedrock/composer.json` is intentionally left unmanaged: its requirements are
open `>0` constraints with no committed lock file, so the weekly rebuild already
picks up new plugin releases and the calendar version makes that visible.
