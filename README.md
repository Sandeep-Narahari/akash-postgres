# akash-postgres

Production PostgreSQL 18 on Akash Network with continuous real-time backup to Cloudflare R2.

---

## What this does

Runs a single PostgreSQL container on any Akash provider. Every change to the database
is streamed to Cloudflare R2 (S3-compatible object storage) in near real-time using
[WAL-G](https://github.com/wal-g/wal-g). All data leaving the container is compressed
and encrypted before upload.

| Property | Value |
|----------|-------|
| Database | PostgreSQL 18 |
| Backup tool | WAL-G v3.0.3 |
| Backup destination | Cloudflare R2 |
| RPO (max data loss) | ≤ 60 seconds |
| RTO (recovery time) | Minutes — full backup fetch + WAL replay |
| Compression | Brotli (~70% size reduction on WAL) |
| Encryption | libsodium secretbox (AES-256-equivalent) |
| TLS in transit | Yes — enforced, plaintext connections rejected |

---

## How it works

### Startup sequence

```
container starts
  │
  ├─ entrypoint.sh
  │    ├── decode TLS cert+key from env vars → write to /var/lib/postgresql/ssl/
  │    ├── start cron daemon (background)
  │    └── exec docker-entrypoint.sh (official postgres entrypoint)
  │
  ├─ docker-entrypoint.sh
  │    ├── if PGDATA empty: run initdb (first start only)
  │    │     └── run init.sh (first start only)
  │    │           ├── auto-tune shared_buffers / work_mem from actual RAM
  │    │           └── push initial full backup to R2
  │    └── start postgres
```

### Continuous WAL archiving (real-time backup)

Every time PostgreSQL fills a WAL segment (16 MB) or 60 seconds pass — whichever
comes first — it calls `archive_command`:

```
postgres fills WAL segment  OR  60 seconds pass
  └─ wal-push-wrapper.sh /pg/wal/00000001...
       └─ wal-g wal-push
            ├── compress with brotli  (16 MB → ~3-6 MB)
            ├── encrypt with libsodium
            └── upload to R2: s3://bucket/postgres/wal_005/00000001...
```

If the upload fails, postgres retries automatically — WAL is never dropped.

### Scheduled full backups (cron)

```
every day  02:00 UTC  →  wal-g backup-push  (full base backup to R2)
every Sun  03:00 UTC  →  wal-g delete retain FULL 7  (keep last 7 full backups)
```

Schedule configurable via `BACKUP_INTERVAL` env var. Supported values: `10min`, `30min`, `1hour`, `6hour`, `1day` (default), `2day`.

Full backups are needed as a recovery base — WAL alone is not enough to restore.
The initial full backup is pushed automatically on first start.

### What lives in R2

```
s3://your-bucket/postgres/
├── basebackups_005/          ← full backups
│   └── base_00000001.../
└── wal_005/                  ← WAL segments (compressed + encrypted)
    ├── 000000010000000000000001.br
    ├── 000000010000000000000002.br
    └── ...
```

---

## File structure

```
akash-postgres/
├── config.env              ← YOU FILL THIS (secrets, resources)
├── Makefile                ← all commands live here
├── Dockerfile              ← builds the image
├── deploy.yaml.template    ← Akash SDL template (make deploy renders it)
├── deploy.yaml             ← rendered SDL — paste into console.akash.network
├── server.crt              ← TLS cert — give to your backend (safe to share)
├── server.key              ← TLS private key — keep secret, never share
├── README.md
└── docker/                 ← internal — you don't need to edit these
    ├── entrypoint.sh       ← container startup: writes TLS cert, starts cron
    ├── init.sh             ← first-start: auto-tune memory, push initial backup
    ├── wal-push-wrapper.sh ← called by postgres archive_command for each WAL segment
    ├── restore.sh          ← recovery script (run manually when restoring)
    ├── postgresql.conf     ← postgres configuration
    ├── pg_hba.conf         ← postgres auth rules (forces TLS for external connections)
    └── crontab             ← full backup + retention schedule
```

---

## Prerequisites

- **Docker** — to build and push the image
- **make** — to run commands
- **openssl** — for TLS cert generation (already installed on most systems)
- **envsubst** — for SDL rendering (`apt install gettext-base` on Ubuntu)
- **Cloudflare account** — with R2 enabled
- **Public container registry** — Docker Hub or GitHub Container Registry (GHCR)

---

## Setup (first time)

### Step 1 — Create Cloudflare R2 bucket and credentials

1. Go to [Cloudflare dashboard](https://dash.cloudflare.com) → R2 → Create bucket
2. Note your **Account ID** (visible in the URL: `dash.cloudflare.com/<ACCOUNT_ID>/`)
3. R2 → Manage R2 API Tokens → Create API Token
   - Permissions: **Object Read & Write**
   - Scope: **Specific bucket** — your bucket only
4. Save: `Access Key ID` and `Secret Access Key`

> Create a second **read-only** token for restore use. Keep it off Akash (not in deploy.yaml).

---

### Step 2 — Generate TLS certificate

Run once. Never run again unless you update every backend that uses this cert.

```bash
make certs
```

This creates `server.crt` and `server.key` locally and auto-updates `config.env`.

- `server.crt` — give to your backend service (it is public, safe to commit with the backend)
- `server.key` — store in a password manager, never share

---
agents:akash:917
### Step 3 — Generate WAL-G encryption key

**Option A — Derived from passphrase (recommended):**

```bash
make derive-keys
```

Prompts for your email (set `OWNER_EMAIL` in `config.env` first) and a passphrase you choose.
Derives the key using scrypt and writes it to `config.env` automatically.

The same passphrase + same email always produces the same key.
**If you lose everything, run `make derive-keys` again with the same passphrase → key is back.**

Rules:
- Passphrase must be ≥ 16 characters — treat it like a master password
- Never change passphrase or email unless you are starting fresh (old backups become unreadable)
- You do not need to store the key anywhere — your memory is the backup

**Option B — Random key:**

```bash
make keygen
```

Paste the output into `config.env`. Store in a password manager.
If lost, backups are unrecoverable. Use only if you have a reliable secrets manager.

---

### Step 4 — Fill in config.env

Open `config.env` and fill in every blank field:

```
REGISTRY_IMAGE=ghcr.io/yourorg/akash-postgres:latest   ← your registry + image name
POSTGRES_DB=mydb                                        ← database name
POSTGRES_USER=postgres                                  ← database user
POSTGRES_PASSWORD=                                      ← strong password (required)
R2_ACCOUNT_ID=                                          ← from Cloudflare dashboard URL
R2_BUCKET=                                              ← bucket name you created
AWS_ACCESS_KEY_ID=                                      ← R2 token access key
AWS_SECRET_ACCESS_KEY=                                  ← R2 token secret key
WALG_LIBSODIUM_KEY=                                     ← from: make keygen
CPU_UNITS=2.0                                           ← Akash CPU (min 1.0)
MEMORY_SIZE=4Gi                                         ← Akash RAM (min 512Mi)
STORAGE_SIZE=100Gi                                      ← persistent disk size
```

`PG_TLS_CERT` and `PG_TLS_KEY` are already filled by `make certs` — do not edit them.

**Resource guidance:**

| Workload | CPU | RAM | Disk |
|----------|-----|-----|------|
| Dev / small | 1.0 | 512Mi | 20Gi |
| Production (small) | 1.0 | 1Gi | 50Gi |
| Production (medium) | 2.0 | 4Gi | 100Gi |
| Production (large) | 4.0 | 8Gi | 500Gi |

Memory settings (`shared_buffers`, `work_mem`) auto-tune to the actual container RAM
on first start — you do not need to set them manually.

---

### Step 5 — Build and push the Docker image

```bash
make build
make push
```

The image must be in a **public** registry. Akash providers pull images without credentials.

**GitHub Container Registry (GHCR):**
```bash
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
# set REGISTRY_IMAGE=ghcr.io/yourorg/akash-postgres:latest in config.env
# make the package public in GitHub → Packages → akash-postgres → Package settings
```

**Docker Hub:**
```bash
docker login
# set REGISTRY_IMAGE=yourusername/akash-postgres:latest in config.env
```

---

### Step 6 — Deploy to Akash

```bash
make deploy
```

This renders `deploy.yaml` with your values from `config.env`.

Then:
1. Open [console.akash.network](https://console.akash.network)
2. Connect your wallet
3. New Deployment → Custom SDL
4. Paste the contents of `deploy.yaml`
5. Choose a provider from the bids
6. Deploy

> If no bids appear with `class: beta3` storage, edit `deploy.yaml` and remove the
> `class: beta3` line to accept any storage type.

---

## Connecting your backend

Your backend runs on a different Akash provider. After deployment, the console shows
the provider's hostname and port (e.g. `provider.example.com:32145`).

Connection string:
```
postgresql://USER:PASSWORD@HOST:PORT/DB?sslmode=verify-ca&sslrootcert=/path/to/server.crt
```

- `sslmode=verify-ca` — verifies the server is using your specific cert (prevents MITM)
- `sslrootcert` — path to the `server.crt` file generated in Step 2
- Do **not** use `sslmode=require` alone — it encrypts but does not verify server identity

**Environment variable for most frameworks:**
```bash
DATABASE_URL=postgresql://postgres:PASSWORD@HOST:PORT/mydb?sslmode=verify-ca&sslrootcert=/app/server.crt
```

---

## Security model

| Threat | Protection |
|--------|-----------|
| Eavesdropping on wire | TLS 1.2+ enforced, plaintext connections rejected (`hostssl` in pg_hba.conf) |
| MITM attack | Backend pins `server.crt` via `sslmode=verify-ca` |
| Backup data leak | All WAL and base backups encrypted with libsodium before leaving container |
| Credential exposure | R2 token scoped to single bucket; credentials visible to Akash provider (on-chain SDL) |
| Unauthorized DB access | scram-sha-256 password auth on all connections |

**Known limitation:** Akash SDL environment variables are stored on-chain and visible to
the provider running your workload. Use a bucket-scoped R2 token and a strong
`POSTGRES_PASSWORD`. Do not put account-level credentials here.

---

## Verify backups are working

Shell into the container via console.akash.network (Deployment → Shell):

```bash
# list full backups in R2
wal-g backup-list --detail

# check archive log for WAL push activity
tail -50 /var/log/wal-g-archive.log

# check full backup log
tail -50 /var/log/wal-g-backup.log

# verify R2 roundtrip: fetch a WAL segment
wal-g wal-fetch 000000010000000000000001 /tmp/test-wal && echo "R2 OK"
```

---

## I lost everything — how to recover

### Scenario: lost config.env, server.key, server.crt — R2 data intact

```bash
# 1. Set OWNER_EMAIL in config.env
# 2. Rederive WAL-G key (same passphrase = same key)
make derive-keys

# 3. Regenerate TLS cert (new cert — update backends after)
make certs

# 4. Rebuild and redeploy
make build && make push && make deploy
```

Data in R2 is intact and decryptable. Update backends with the new `server.crt`.

### What you must never forget

| Thing | If lost | Recoverable? |
|-------|---------|-------------|
| Passphrase (for `derive-keys`) | Can't decrypt R2 backups | **No — memorize it** |
| `OWNER_EMAIL` | Can't rederive key | Yes — it's your email |
| R2 credentials | Can't access backups | Yes — recreate in Cloudflare |
| `server.crt` / `server.key` | Must update all backends | Yes — `make certs` |
| R2 bucket data | Total loss | No — this IS the backup |

---

## Restore

Run these commands inside a **fresh container** with empty `PGDATA` **before** postgres starts.

### Restore latest backup

```bash
/usr/local/bin/restore.sh
```

### Restore a specific backup

```bash
# list available backups
wal-g backup-list --detail

# restore by name
/usr/local/bin/restore.sh base_000000010000000000000003
```

### Point-in-time recovery (PITR)

Restore to any moment within your retention window (up to 7 days back):

```bash
/usr/local/bin/restore.sh LATEST "2024-06-15 14:30:00"
```

After any restore, start postgres normally. It replays WAL segments from R2 and
promotes to primary automatically.

Verify:
```sql
SELECT pg_is_in_recovery();
-- returns false = promotion complete, database is live
```

---

## Tuning PostgreSQL

Defaults are auto-calculated from container RAM on first start. To override
without rebuilding the image:

```sql
-- connect to postgres
ALTER SYSTEM SET shared_buffers = '2GB';
ALTER SYSTEM SET work_mem = '64MB';
SELECT pg_reload_conf();
-- some settings require restart (shared_buffers)
```

For hardware-specific values: [https://pgtune.leopard.in.ua](https://pgtune.leopard.in.ua)

---

## Make command reference

```bash
make setup        # generate TLS cert (run once before first deploy)
make keygen       # print new WAL-G encryption key
make build        # docker build -t IMAGE .
make push         # docker push IMAGE
make deploy       # render deploy.yaml from template
make backup-list  # list backups in R2
```

---

## Retention

By default, 7 full backups are kept (approximately 7 days). WAL segments older than
the oldest retained full backup are also deleted automatically every Sunday at 03:00 UTC.

To change retention, edit `docker/crontab`:
```
wal-g delete retain FULL 14 --confirm   # keep 14 full backups
```

Then rebuild and push the image.

---

> Not validated against a live Akash deployment. Test in staging before production use.
