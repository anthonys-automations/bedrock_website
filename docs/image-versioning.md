# Container image versioning

How `anthonysautomations/bedrock_website` images are versioned, built and kept
up to date. The portable design rationale this implements is in
[workflow.example/image-versioning.md](../workflow.example/image-versioning.md);
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

The scheme that replaced it published one tag per architecture
(`...-amd64`, `...-arm64`) because CI built only amd64 and arm64 was produced by
hand. Both architectures are now built in the same run, on native runners, and
published as a single manifest: one tag serves every node, and a deployment no
longer has to know which architecture it lands on.

## Tag contract

```text
<YYYY>.<MM>.<DD>.<N>        e.g. 2026.07.30.1
```

| Field | Meaning |
| --- | --- |
| `YYYY.MM.DD` | UTC date of the build |
| `N` | 1-based sequence within that date and version stream |

| Tag | Mutability | Role |
| --- | --- | --- |
| `2026.07.30.1` | immutable | deployable multi-architecture release — pin this |
| `latest` | moving | human convenience only, never deploy |
| `2026.07.30.1-arm64` | immutable | out-of-band single-architecture build (escape hatch) |

Rules:

- Release tags are never overwritten; the allocator verifies the tag is unused
  and aborts otherwise.
- The unsuffixed tag is only ever created once **every** architecture has been
  built and pushed. This is the load-bearing rule — see below.
- An out-of-band single-architecture build publishes suffixed tags only, from a
  separately counted version stream. Advancing the unsuffixed stream with a
  partial release would hand a mixed-architecture cluster an image that only
  runs on some of its nodes.
- All timestamps are UTC.

## Publishing atomically across architectures

[.github/workflows/image_build.yml](../.github/workflows/image_build.yml) is a
fan-out/fan-in pipeline:

```text
prepare   allocate one version + one metadata set for the whole release
   |
   +-- build (amd64, ubuntu-latest)  ---+   pushed BY DIGEST, with no tag
   +-- build (arm64, ubuntu-24.04-arm) -+
                                         \
publish  depends on BOTH build jobs succeeding:
         assemble the digests into one manifest list,
         verify it covers both platforms, create the release tag, move `latest`
```

What makes it reliable:

- **Untagged pushes are inert.** A digest with no tag does not appear in tag
  listings and cannot be pulled by name, so a half-finished release leaves
  litter rather than a trap.
- **The dependency is the gate.** `publish` has no `if: always()`, so a failed,
  cancelled or never-scheduled architecture means no tag is created at all. The
  digest count is asserted explicitly as well.
- **The manifest is verified before `latest` moves.** The assembled index is
  built with `--dry-run` first and its platform set compared against
  `EXPECTED_PLATFORMS`; the alias is then created from that already-verified
  index. SBOM/provenance attestations appear as `unknown/unknown` entries and
  are filtered out of that comparison.
- **Metadata is allocated once**, in `prepare`, so both images carry identical
  labels and the manifest describes one release rather than two coincidental
  builds.

The cost is deliberate: when one architecture cannot build there is **no
release**, not even for the architecture that was fine. A missed weekly rebuild
is recoverable; a deployment that cannot be scheduled on half the cluster is
not. That also makes runner availability part of the release path, which is why
both architectures use GitHub-hosted runners.

## Out-of-band single-architecture builds

[scripts/build-arm64.sh](../scripts/build-arm64.sh) remains as an escape hatch
for when an arm64 image is needed without a full release. It allocates from the
`-arm64` version stream through the same
[scripts/next-version.sh](../scripts/next-version.sh), so it obeys the same
contract as CI while never advancing the multi-architecture stream. That shared
script — rather than inline workflow steps — is the reason the two cannot drift
apart.

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

Immediately before each build, `next-version.sh <repo> [arch]`:

1. Lists Docker Hub tags for the current UTC date using the server-side `name`
   prefix filter.
2. Takes the highest `N` already used for that date *in the matching stream*
   (unsuffixed when no `arch` is given, `-<arch>` otherwise), and returns `N+1`.
3. Verifies the resulting tag does not exist, and aborts if it does.

It is deliberately fail-closed: only a registry-confirmed HTTP 404 (repository
does not exist yet) counts as "no tags". A failed or malformed listing aborts,
because treating it as empty could allocate a version that sorts *older* than
one already published — which an updater would never offer as an update.

The pipeline sets a workflow-level `concurrency` group so two runs on the same
day cannot race for the same sequence number, nor interleave their tag pushes.
The out-of-band script does not serialise itself; run only one at a time.

## Provenance

The tag stays short; detail lives in metadata:

| Label | Value |
| --- | --- |
| `org.opencontainers.image.title` | `bedrock_website` |
| `org.opencontainers.image.version` | allocated version |
| `org.opencontainers.image.revision` | source commit SHA |
| `org.opencontainers.image.source` | repository URL |
| `org.opencontainers.image.created` | RFC 3339 UTC build time |
| `io.anthonysautomations.php.version` | pinned PHP base image version |

The same set is repeated as `index:` annotations on the published manifest, so
the release is described at the level a consumer actually pins.

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
  anthonysautomations/bedrock_website:2026.07.30.1
```

## Consuming the images

Deployments must pin an immutable release tag.
[release.yml](../.github/workflows/release.yml) only *publishes* an image on
push; it does not roll anything out. Deploying is a separate, deliberate step:
dispatch [container_deploy.yml](../.github/workflows/container_deploy.yml) with
the release tag, which feeds `IMAGE_TAG` in
[docker-compose.yml](../docker-compose.yml).

**Migration note:** the architecture-suffixed release tags (`...-amd64`,
`...-arm64`) are no longer produced by CI and stop being updated. Anything still
pinned to one — including the chart's `appVersion` — must be repointed to an
unsuffixed release tag at the next rollout. The plain `latest` tag is published
again, but as a moving alias that must not be deployed.

An external repository tracking these images with Renovate needs:

```yaml
# renovate: datasource=docker depName=anthonysautomations/bedrock_website versioning=regex:^(?<major>\d{4})\.(?<minor>\d{2})\.(?<patch>\d{2})\.(?<build>\d+)$
image: anthonysautomations/bedrock_website:2026.07.30.1
```

One tag serves every architecture, so consumers need no architecture-specific
configuration. The regex deliberately does **not** match an `-<arch>` suffix, so
an out-of-band single-architecture build is never offered as an update.

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
  `renovate/*` branch, which builds and smoke tests on both architectures. An
  API-triggered dispatch *is* allowed to run, so its check lands on the branch
  head and Renovate merges on a following run once it is green. See
  [testing.md](testing.md) for the validation contract.
- **Renovate exits 0 when it fails.** An invalid config key or an auth rejection
  produces a green job that did nothing. The workflow therefore runs
  `renovate-config-validator --strict` first, and afterwards asserts on the
  structured log that no error-level record was written and the repository
  result is `done`.

Everything Renovate may actually branch — the Dockerfile base image and the
chart's sidecar images — is grouped into a single `renovate/all-dependencies`
branch and pull request, so a run costs one validation build and one merge
instead of one per dependency. `separateMajorMinor: false` keeps major updates
in that same branch rather than splitting them off into their own. The group
names its managers explicitly instead of matching everything: `github-actions`
has to stay outside it, because `GITHUB_TOKEN` cannot push under
`.github/workflows` and one such change in a shared branch would block every
other update travelling with it.

`prHourlyLimit` is set to `0` (off) rather than left at its default of `2`.
That default counts every PR opened in the current clock hour — including ones
already closed, such as the per-dependency PRs that were pruned when this
config moved to a single group. Once the limit is reached Renovate still
creates the branch but silently skips the PR, and because that is a
`debug`-level event an `info`-level run shows only `Branch created` and the
workflow's log assertions still pass. If a branch ever exists without a PR
again, check the Dependency Dashboard: rate-limited updates are listed there
with a checkbox that forces creation.

`bedrock/composer.json` is intentionally left unmanaged: its requirements are
open `>0` constraints with no committed lock file, so the weekly rebuild already
picks up new plugin releases and the calendar version makes that visible.

## Keeping the chart's sidecar images current

The Helm chart pins its telemetry sidecars (`bitnami/apache-exporter`,
`busybox`, `ghcr.io/google/mtail`, `redis`) inline in
[charts/bedrock-website/templates/deployment.yaml](../charts/bedrock-website/templates/deployment.yaml),
not in `values.yaml`. Renovate's `kubernetes` manager ships with no default file
pattern, so `renovate.json` names those template files explicitly; without that
entry no chart image is actionable for Renovate.

Two consequences follow:

- **The main image has to be excluded by name.** Its tag is a Helm expression
  (`{{ .Chart.AppVersion }}`), it is calendar-versioned rather than semver, and
  its rollout is the deliberate `appVersion` edit described above. A packageRule
  in `renovate.json` disables it. An inline `# renovate:ignore` comment would
  not do the job — the `kubernetes` manager does not honour that convention, and
  would read the templated tag as no tag at all.
- **A sidecar bump is a chart change, so the chart version moves with it.** The
  overlays inflate the chart straight from this repository, so nothing else
  would signal that the rendered manifests changed. Renovate's `bumpVersions`
  feature rewrites `version:` in
  [charts/bedrock-website/Chart.yaml](../charts/bedrock-website/Chart.yaml)
  inside the same commit. Its `matchString` starts at a newline rather than
  `^`, because Renovate compiles it without the multiline flag and `version:`
  is not at the beginning of `Chart.yaml`.
