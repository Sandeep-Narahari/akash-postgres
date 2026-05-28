#!/bin/bash
# Runs once after initdb. Auto-tunes memory and pushes initial WAL-G backup.
set -e

PGDATA="${PGDATA:-/var/lib/postgresql/data}"

# ── Memory auto-tune ──────────────────────────────────────────────────────────
TOTAL_RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
{
    echo "# Auto-tuned ($(( TOTAL_RAM_KB / 1024 ))MB RAM)"
    echo "shared_buffers = '$(( TOTAL_RAM_KB / 4 ))kB'"
    echo "effective_cache_size = '$(( TOTAL_RAM_KB * 3 / 4 ))kB'"
    echo "work_mem = '$(( TOTAL_RAM_KB / 50 ))kB'"
} >> "$PGDATA/postgresql.auto.conf"
echo "[init] shared_buffers=$(( TOTAL_RAM_KB / 4 / 1024 ))MB work_mem=$(( TOTAL_RAM_KB / 50 / 1024 ))MB"

# ── Initial WAL-G full backup ─────────────────────────────────────────────────
SENTINEL="${PGDATA}/.wal_g_initialized"
if [ ! -f "$SENTINEL" ]; then
    echo "[init] Pushing initial full backup to R2..."
    /usr/local/bin/wal-g backup-push "$PGDATA"
    touch "$SENTINEL"
    echo "[init] Initial backup complete."
fi
