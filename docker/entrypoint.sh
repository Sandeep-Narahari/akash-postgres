#!/bin/bash
set -e

SSL_DIR=/var/lib/postgresql/ssl

# Write TLS cert+key from env vars (base64-encoded, generated locally before deploy).
# This keeps the cert stable across redeployments.
if [ -z "${PG_TLS_CERT:-}" ] || [ -z "${PG_TLS_KEY:-}" ]; then
    echo "ERROR: PG_TLS_CERT and PG_TLS_KEY must be set."
    echo "Generate once: openssl req -new -x509 -days 3650 -nodes -subj '/CN=postgres' -keyout server.key -out server.crt"
    echo "Then: PG_TLS_CERT=\$(base64 -w0 server.crt)  PG_TLS_KEY=\$(base64 -w0 server.key)"
    exit 1
fi

mkdir -p "$SSL_DIR"
echo "$PG_TLS_CERT" | base64 -d > "${SSL_DIR}/server.crt"
echo "$PG_TLS_KEY"  | base64 -d > "${SSL_DIR}/server.key"
chmod 644 "${SSL_DIR}/server.crt"
chmod 600 "${SSL_DIR}/server.key"
chown postgres:postgres "${SSL_DIR}/server.crt" "${SSL_DIR}/server.key"

# Start cron daemon for scheduled full backups
cron

# Hand off to the official postgres entrypoint
exec docker-entrypoint.sh "$@"
