#!/usr/bin/env bash
#
# Out-of-band build of the bedrock_website image for linux/arm64.
#
# This is an escape hatch, not the normal path: .github/workflows/image_build.yml
# now builds both architectures natively and publishes them as one
# multi-architecture manifest under an unsuffixed tag. Use this script only when
# an arm64 image is needed without (or ahead of) a full release - a runner
# outage, or a local reproduction of a build failure.
#
# Tags published:
#   <YYYY>.<MM>.<DD>.<N>-arm64   immutable single-architecture build
#   latest-arm64                 moving alias, convenience only - never deploy it
#
# The `-arm64` suffix is load-bearing: this build covers one architecture only,
# so it allocates from its own version stream (scripts/next-version.sh with an
# arch argument) and must never advance the unsuffixed stream. Publishing a
# partial release there would offer a mixed-architecture cluster an image that
# only runs on some of its nodes - which is exactly what the multi-arch
# pipeline's publish gate exists to prevent (docs/image-versioning.md).
#
# Package inventory is not queried from an independently pulled base image
# before the build (that could drift from what actually gets installed, since
# both the Debian package index and Packagist are mutable). Instead the build
# enables a BuildKit SBOM attestation, which reflects the exact image that gets
# pushed; inspect it with:
#   docker buildx imagetools inspect --format '{{ json .SBOM }}' <repo>:<tag>
#
# Usage:
#   scripts/build-arm64.sh
#
# Environment:
#   DOCKERHUB_NAMESPACE   DockerHub namespace (default: anthonysautomations)
#   DOCKERHUB_IMAGE       image name (default: bedrock_website)
#   DOCKERHUB_USERNAME    optional; if set together with DOCKERHUB_TOKEN the
#                         script logs in, otherwise an existing `docker login`
#                         session is assumed
#   DOCKERHUB_TOKEN       optional access token, read from the environment and
#                         piped to `docker login` so it never appears in argv
#   ALLOW_DIRTY           set to 1 to publish despite uncommitted changes (the
#                         recorded revision will then not match what was
#                         actually built - avoid for real releases)
#
# Requires a buildx builder able to produce linux/arm64 (a native arm64 host, or
# qemu registered via `docker run --privileged --rm tonistiigi/binfmt --install arm64`).
#
# Run only one instance at a time. The version is checked to be unused when it
# is allocated, not when it is pushed, so two genuinely overlapping runs could
# still settle on the same version and have one overwrite the other. That is
# accepted here because these builds are manual and infrequent; it is not
# defended against.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)

if [[ $# -ne 0 ]]; then
    echo "usage: $(basename "$0")" >&2
    echo "       (no arguments; see the header of this script for environment variables)" >&2
    exit 2
fi

namespace=${DOCKERHUB_NAMESPACE:-anthonysautomations}
image=${DOCKERHUB_IMAGE:-bedrock_website}
repo="${namespace}/${image}"
arch=arm64
platform="linux/${arch}"

context_dir="${repo_root}"
dockerfile="${repo_root}/Dockerfile"

if [[ ! -f ${dockerfile} ]]; then
    echo "error: no Dockerfile found at ${dockerfile}" >&2
    exit 1
fi

for dep in docker curl jq git; do
    if ! command -v "${dep}" >/dev/null 2>&1; then
        echo "error: required dependency '${dep}' is not installed" >&2
        exit 1
    fi
done

if ! docker buildx version >/dev/null 2>&1; then
    echo "error: 'docker buildx' is not available; it is required for --platform builds" >&2
    exit 1
fi

if ! docker buildx inspect --bootstrap 2>/dev/null | grep -q "${platform}"; then
    echo "error: the active buildx builder cannot produce ${platform}" >&2
    echo "       register emulation with: docker run --privileged --rm tonistiigi/binfmt --install ${arch}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Source integrity
# ---------------------------------------------------------------------------
# The commit recorded in the image (GIT_COMMIT / image.revision) is only
# meaningful for audit if it actually matches what was built. The build context
# is the whole repository, so check tracked AND untracked changes anywhere in
# it - an untracked file would still be picked up by COPY.
dirty=$(git -C "${repo_root}" status --porcelain)
if [[ -n ${dirty} ]]; then
    if [[ ${ALLOW_DIRTY:-} == 1 ]]; then
        echo "warning: the working tree has uncommitted changes; ALLOW_DIRTY=1 set, proceeding anyway" >&2
        echo "${dirty}" >&2
    else
        echo "error: the working tree has uncommitted changes; refusing to publish an image whose" >&2
        echo "       recorded revision would not match its actual content:" >&2
        echo "${dirty}" >&2
        echo "       re-run with ALLOW_DIRTY=1 to override (not recommended for audited releases)" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------
if [[ -n ${DOCKERHUB_USERNAME:-} && -n ${DOCKERHUB_TOKEN:-} ]]; then
    echo "==> logging in to DockerHub as ${DOCKERHUB_USERNAME}"
    printf '%s' "${DOCKERHUB_TOKEN}" | docker login --username "${DOCKERHUB_USERNAME}" --password-stdin
else
    echo "==> DOCKERHUB_USERNAME/DOCKERHUB_TOKEN not set, assuming an existing docker login session"
fi

# ---------------------------------------------------------------------------
# Release identity
# ---------------------------------------------------------------------------
version=$("${script_dir}/next-version.sh" "${repo}" "${arch}")
tag="${version}-${arch}"

# ---------------------------------------------------------------------------
# Provenance metadata
# ---------------------------------------------------------------------------
# The PHP release is pinned in the Dockerfile, so read it from there rather than
# inspecting a separately pulled image.
php_version=$(sed -nE 's|^FROM php:([A-Za-z0-9._-]+).*|\1|p' "${dockerfile}")
php_version=${php_version%%$'\n'*}
if [[ -z ${php_version} ]]; then
    echo "error: could not determine the pinned PHP base image version from ${dockerfile}" >&2
    exit 1
fi

revision=$(git -C "${repo_root}" rev-parse HEAD)
created=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Derive the source URL from the checkout so the label stays correct if the
# repository is ever moved or forked.
source_url=$(git -C "${repo_root}" remote get-url origin 2>/dev/null || true)
source_url=${source_url%.git}
source_url=${source_url/git@github.com:/https://github.com/}

# ---------------------------------------------------------------------------
# Build and push
# ---------------------------------------------------------------------------
cat <<EOF
==> building ${repo}
    platform         ${platform}
    release tag      ${tag}
    moving alias     latest-${arch}
    php base image   ${php_version}
    revision         ${revision}
EOF

docker buildx build \
    --platform "${platform}" \
    --file "${dockerfile}" \
    --tag "${repo}:${tag}" \
    --tag "${repo}:latest-${arch}" \
    --build-arg "GIT_COMMIT=${revision}" \
    --label "org.opencontainers.image.title=${image}" \
    --label "org.opencontainers.image.version=${version}" \
    --label "org.opencontainers.image.revision=${revision}" \
    --label "org.opencontainers.image.source=${source_url}" \
    --label "org.opencontainers.image.created=${created}" \
    --label "io.anthonysautomations.php.version=${php_version}" \
    --sbom=true \
    --push \
    "${context_dir}"

echo "==> published ${repo}:${tag} and ${repo}:latest-${arch}"
# Same DockerHub link the CI build summary emits, so an out-of-band release is
# just as easy to open and verify.
echo "==> https://hub.docker.com/layers/${repo}/${tag}/"
