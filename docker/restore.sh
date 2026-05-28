#!/bin/bash
# Restore PostgreSQL from WAL-G backup stored in Cloudflare R2.
# Run this on a FRESH container with PGDATA empty BEFORE starting postgres.
#
# Usage:
#   ./restore.sh              -- restore LATEST full backup
#   ./restore.sh BACKUP_NAME  -- restore specific backup (list with: wal-g backup-list)
#   ./restore.sh PITR 2024-01-15T14:30:00Z  -- restore to point in time
set -e

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
BACKUP_NAME="${1:-LATEST}"
PITR_TARGET="${2:-}"

if [ -n "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
    echo "ERROR: PGDATA ${PGDATA} is not empty. Aborting to prevent data loss."
    exit 1
fi

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Fetching backup: ${BACKUP_NAME}"
wal-g backup-fetch "$PGDATA" "$BACKUP_NAME"

# Signal postgres to enter recovery mode
touch "$PGDATA/recovery.signal"

# Write restore_command so postgres fetches WAL segments from R2
cat >> "$PGDATA/postgresql.auto.conf" <<EOF

# Recovery settings written by restore.sh
restore_command = 'wal-g wal-fetch "%f" "%p"'
EOF

if [ -n "$PITR_TARGET" ]; then
    cat >> "$PGDATA/postgresql.auto.conf" <<EOF
recovery_target_time = '${PITR_TARGET}'
recovery_target_action = 'promote'
EOF
    echo "PITR target set: ${PITR_TARGET}"
fi

chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

echo ""
echo "Restore complete. Start postgres normally — it will replay WAL and promote."
echo "To verify: SELECT pg_is_in_recovery();"
