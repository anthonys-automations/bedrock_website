#!/bin/bash
#
# Container entrypoint.
#
# Replaces the old nginx + PHP-FPM + supervisord startup: Apache (with mod_php)
# is now the single process and is exec'd as PID 1 so it receives signals and
# shuts down gracefully.
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

CERT_DIR=/etc/ssl/bedrock
CA_CERT=/usr/local/share/ca-certificates/bedrock-loopback.crt

# Writable content directories. Tolerated as best effort: the uploads path is a
# mounted volume and a permission failure there should not stop the site from
# serving.
mkdir -p /srv/bedrock/web/app/uploads/ /srv/bedrock/web/app/plugins/independent-analytics/temp/
chown www-data:www-data \
  /srv/bedrock/web/app/ \
  /srv/bedrock/web/app/uploads/ \
  /srv/bedrock/web/app/plugins/independent-analytics/temp/ \
  || echo "run.sh: warning: could not chown content directories, continuing"

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
if ! grep -qE "[[:space:]]${SITE_NAME}([[:space:]]|$)" /etc/hosts; then
  echo "127.0.0.1 ${SITE_NAME}" >> /etc/hosts \
    || echo "run.sh: warning: could not add ${SITE_NAME} to /etc/hosts"
fi

# Fail fast on a broken vhost instead of crash-looping inside Apache.
apache2ctl -t

exec apache2-foreground
