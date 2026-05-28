#!/bin/bash
# Derive WAL-G encryption key deterministically from passphrase + email.
#
# Same passphrase + same email = same key, every time.
# Run this whenever you need to recover or regenerate the key.
#
# Algorithm: scrypt(passphrase, salt="EMAIL:akash-postgres:walg", N=2^18, r=8, p=1, len=32)
# Requires: python3 (stdlib only, no pip installs)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"

# ── Read email ────────────────────────────────────────────────────────────────
EMAIL=$(grep '^OWNER_EMAIL=' "$CONFIG_ENV" | cut -d= -f2)
if [ -z "$EMAIL" ]; then
    read -rp "Email address: " EMAIL
    if [ -z "$EMAIL" ]; then
        echo "ERROR: email required"
        exit 1
    fi
fi
echo "Email : ${EMAIL}"

# ── Read passphrase (hidden) ──────────────────────────────────────────────────
read -rsp "Passphrase: " PASSPHRASE
echo
read -rsp "Confirm   : " PASSPHRASE2
echo

if [ "$PASSPHRASE" != "$PASSPHRASE2" ]; then
    echo "ERROR: passphrases do not match"
    exit 1
fi
if [ "${#PASSPHRASE}" -lt 16 ]; then
    echo "ERROR: passphrase must be at least 16 characters"
    exit 1
fi

# ── Derive WAL-G key via scrypt ───────────────────────────────────────────────
echo "Deriving key (takes a few seconds)..."

WALG_KEY=$(DERIVE_PASSPHRASE="$PASSPHRASE" DERIVE_EMAIL="$EMAIL" python3 - <<'PYEOF'
import hashlib, base64, os

passphrase = os.environ['DERIVE_PASSPHRASE'].encode()
salt       = (os.environ['DERIVE_EMAIL'] + ':akash-postgres:walg').encode()

key = hashlib.scrypt(passphrase, salt=salt, n=2**18, r=8, p=1, dklen=32, maxmem=300*1024*1024)
print(base64.b64encode(key).decode())
PYEOF
)

# ── Update config.env ─────────────────────────────────────────────────────────
sed -i "s|^WALG_LIBSODIUM_KEY=.*|WALG_LIBSODIUM_KEY=${WALG_KEY}|" "$CONFIG_ENV"

echo ""
echo "WALG_LIBSODIUM_KEY set in config.env"
echo ""
echo "To recover this key in future:"
echo "  ./derive-keys.sh"
echo "  → type same passphrase + email → same key"
echo ""
echo "WARNING: changing passphrase or email produces a DIFFERENT key."
echo "All existing R2 backups become unreadable. Only change if starting fresh."
