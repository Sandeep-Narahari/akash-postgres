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

# Apply runtime tuning overrides
if [ -n "${PG_MAX_CONNECTIONS:-}" ]; then
    echo "max_connections = ${PG_MAX_CONNECTIONS}" >> /etc/postgresql/postgresql.conf
fi

# Auto-restore from R2 if PGDATA is empty and a backup exists
PGDATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
    if [ -n "${WALG_S3_PREFIX:-}" ]; then
        echo "[entrypoint] PGDATA empty — checking R2 for existing backup..."
        if PGHOST=/var/run/postgresql PGUSER="${POSTGRES_USER}" PGDATABASE="${POSTGRES_DB}" \
           wal-g backup-list 2>/dev/null | grep -q '^base_'; then
            echo "[entrypoint] Backup found — restoring LATEST from R2..."
            mkdir -p "$PGDATA"
            chown postgres:postgres "$PGDATA"
            chmod 700 "$PGDATA"
            su postgres -c "wal-g backup-fetch $PGDATA LATEST"
            su postgres -c "touch $PGDATA/recovery.signal"
            su postgres -c "cat >> $PGDATA/postgresql.auto.conf" <<EOF

# Recovery settings written by entrypoint auto-restore
restore_command = 'wal-g wal-fetch "%f" "%p"'
recovery_target_action = 'promote'
EOF
            echo "[entrypoint] Restore complete — postgres will replay WAL on start."
        else
            echo "[entrypoint] No backup found in R2 — fresh initialization."
        fi
    fi
fi

# Convert BACKUP_INTERVAL (e.g. 10min, 6hour, 1day) to cron expression
BACKUP_INTERVAL="${BACKUP_INTERVAL:-1day}"
case "$BACKUP_INTERVAL" in
    *min)  N="${BACKUP_INTERVAL%min}";  BACKUP_CRON="*/${N} * * * *" ;;
    *hour) N="${BACKUP_INTERVAL%hour}"; BACKUP_CRON="0 */${N} * * *" ;;
    *day)  N="${BACKUP_INTERVAL%day}";  BACKUP_CRON="0 2 */${N} * *" ;;
    *)     echo "[entrypoint] Unknown BACKUP_INTERVAL '${BACKUP_INTERVAL}', using 1day"; BACKUP_CRON="0 2 * * *" ;;
esac
echo "[entrypoint] Backup schedule: ${BACKUP_INTERVAL} → cron '${BACKUP_CRON}'"

# Dump all wal-g/storage env vars to file — cron doesn't inherit container environment
printenv | grep -E '^(AWS_|WALG_|POSTGRES_|PGDATA)' > /etc/wal-g-env
# wal-g uses PGUSER/PGDATABASE, not POSTGRES_USER/POSTGRES_DB
echo "PGUSER=${POSTGRES_USER}" >> /etc/wal-g-env
echo "PGDATABASE=${POSTGRES_DB}" >> /etc/wal-g-env
chmod 600 /etc/wal-g-env
chown postgres:postgres /etc/wal-g-env

# Generate crontab — sources /etc/wal-g-env for all storage + pg vars
cat > /etc/cron.d/postgres-backup <<CRONTAB
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${BACKUP_CRON} postgres set -a && . /etc/wal-g-env && set +a && PGHOST=/var/run/postgresql wal-g backup-push \$PGDATA >> /var/log/wal-g-backup.log 2>&1

0 3 * * 0 postgres set -a && . /etc/wal-g-env && set +a && PGHOST=/var/run/postgresql wal-g delete retain FULL 7 --confirm >> /var/log/wal-g-backup.log 2>&1
CRONTAB
chmod 0644 /etc/cron.d/postgres-backup

# Start cron daemon for scheduled full backups
cron

# Hand off to the official postgres entrypoint
exec docker-entrypoint.sh "$@"
