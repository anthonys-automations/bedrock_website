#!/bin/bash
#
# Container entrypoint.
#
# Replaces the old nginx + PHP-FPM + supervisord startup: Apache (with mod_php)
# is now the single process and is exec'd as PID 1 so it receives signals and
# shuts down gracefully.
#
# Runs as www-data, not root (Dockerfile `USER`), so every step here has to work
# with nothing but ownership of the paths the image hands over. The one thing
# that cannot: /etc/hosts, which the container runtime owns - see below.
#
# The self-signed certificate is kept from the previous setup on purpose. The
# public front door (Cloudflare -> ingress) is not reachable from inside the
# container, so WordPress loopback/REST calls have to talk to the container
# itself - and because WP_HOME is an https URL those calls must succeed over
# TLS against a locally trusted certificate.

set -euo pipefail

# Used by build/apache/bedrock.conf (ServerName) and by the certificate below,
# so it must be exported and always have a value.
SITE_NAME="${SITE_NAME:-localhost}"
export SITE_NAME

# In-container access logging is opt-out: the ingress already produces the
# external access log, so a deployment that does not need the local copy can
# set ACCESS_LOG=off and avoid both the disk use and the rotatelogs child.
# Apache config cannot branch on an environment variable, so the value is
# turned into a define that <IfDefine ACCESS_LOG> in bedrock.conf keys on.
APACHE_ARGS=()
case "${ACCESS_LOG:-on}" in
  [Oo][Nn] | [Tt][Rr][Uu][Ee] | 1 | [Yy][Ee][Ss])
    APACHE_ARGS+=(-D ACCESS_LOG)
    ;;
  [Oo][Ff][Ff] | [Ff][Aa][Ll][Ss][Ee] | 0 | [Nn][Oo])
    ;;
  *)
    # Unrecognised values keep logging rather than silently dropping it.
    echo "run.sh: warning: unrecognised ACCESS_LOG='${ACCESS_LOG}', keeping access logging on"
    APACHE_ARGS+=(-D ACCESS_LOG)
    ;;
esac

CERT_DIR=/etc/ssl/bedrock
CA_CERT=/usr/local/share/ca-certificates/bedrock-loopback.crt

# Writable content directories. Tolerated as best effort: the uploads path is a
# mounted volume and a permission failure there should not stop the site from
# serving.
mkdir -p /srv/bedrock/web/app/uploads/ /srv/bedrock/web/app/plugins/independent-analytics/temp/ \
  || echo "run.sh: warning: could not create content directories, continuing"

# Ownership of a mounted volume is the platform's job now that this runs
# unprivileged (fsGroup in Kubernetes, a host-side chown to uid 33 for a bind
# mount). Attempted only when the image is started with an overridden root
# user, since a non-root chown of someone else's mount can only ever warn.
if [[ "$(id -u)" -eq 0 ]]; then
  chown www-data:www-data \
    /srv/bedrock/web/app/ \
    /srv/bedrock/web/app/uploads/ \
    /srv/bedrock/web/app/plugins/independent-analytics/temp/ \
    || echo "run.sh: warning: could not chown content directories, continuing"
fi

# Generated once per container rather than unconditionally: regenerating on
# every restart pointlessly invalidated the copy already in the CA store.
# SITE_NAME goes in a SAN because CN-only certificates are no longer accepted
# by modern OpenSSL/cURL verification.
if [[ ! -s "${CERT_DIR}/server.crt" || ! -s "${CERT_DIR}/server.key" ]]; then
  mkdir -p "${CERT_DIR}"
  openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
    -keyout "${CERT_DIR}/server.key" \
    -out "${CERT_DIR}/server.crt" \
    -subj "/CN=${SITE_NAME}" \
    -addext "subjectAltName=DNS:${SITE_NAME},DNS:localhost,IP:127.0.0.1"
  chmod 600 "${CERT_DIR}/server.key"
fi

# Trusted in-container so PHP/cURL loopback requests to https://${SITE_NAME}
# validate instead of having to disable verification.
if ! cmp -s "${CERT_DIR}/server.crt" "${CA_CERT}"; then
  cp "${CERT_DIR}/server.crt" "${CA_CERT}"
  update-ca-certificates
fi

# Resolve the public hostname back to this container. Appended only when absent
# so restarts do not keep growing /etc/hosts.
#
# /etc/hosts is mounted root-owned by the container runtime, so this only
# succeeds when the image is run as root. Unprivileged, the mapping has to come
# from outside: hostAliases in the pod spec, extra_hosts in compose, or
# --add-host for a bare `docker run`. Without it SITE_NAME resolves publicly and
# WordPress loopback calls leave the container (or fail).
if ! grep -qE "[[:space:]]${SITE_NAME}([[:space:]]|$)" /etc/hosts; then
  echo "127.0.0.1 ${SITE_NAME}" >> /etc/hosts \
    || echo "run.sh: warning: ${SITE_NAME} is not mapped to 127.0.0.1 and /etc/hosts is not writable; set hostAliases/extra_hosts/--add-host"
fi

# Fail fast on a broken vhost instead of crash-looping inside Apache. The same
# defines are passed here as to the server below, so the config is validated
# exactly as it will be loaded.
apache2ctl -t "${APACHE_ARGS[@]}"

# apache2-foreground forwards its arguments to apache2.
exec apache2-foreground "${APACHE_ARGS[@]}"
