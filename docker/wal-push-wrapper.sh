#!/bin/bash
# Wrapper for archive_command so failures are logged but don't silently drop WALs.
# PostgreSQL retries archive_command until it exits 0, so returning non-zero is safe.
set -e

WAL_FILE="$1"
LOG=/var/log/wal-g-archive.log

/usr/local/bin/wal-g wal-push "$WAL_FILE" >> "$LOG" 2>&1
RC=$?

if [ $RC -ne 0 ]; then
    logger -t wal-push "FAILED to archive ${WAL_FILE} (exit ${RC}) — postgres will retry"
fi

exit $RC
