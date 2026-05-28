FROM postgres:18-bookworm

ARG WALG_VERSION=v3.0.3

RUN apt-get update && apt-get install -y --no-install-recommends \
        cron curl ca-certificates libsodium23 openssl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/wal-g/wal-g/releases/download/${WALG_VERSION}/wal-g-pg-ubuntu-20.04-amd64.tar.gz" \
        | tar -xzC /usr/local/bin \
    && mv /usr/local/bin/wal-g-pg-ubuntu-20.04-amd64 /usr/local/bin/wal-g \
    && chmod +x /usr/local/bin/wal-g

COPY docker/postgresql.conf     /etc/postgresql/postgresql.conf
COPY docker/pg_hba.conf         /etc/postgresql/pg_hba.conf
COPY docker/entrypoint.sh       /usr/local/bin/entrypoint.sh
COPY docker/wal-push-wrapper.sh /usr/local/bin/wal-push-wrapper.sh
COPY docker/restore.sh          /usr/local/bin/restore.sh
COPY docker/init.sh             /docker-entrypoint-initdb.d/init.sh
COPY docker/crontab             /etc/cron.d/postgres-backup

RUN chmod +x \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/wal-push-wrapper.sh \
        /usr/local/bin/restore.sh \
        /docker-entrypoint-initdb.d/init.sh \
    && chmod 0644 /etc/cron.d/postgres-backup \
    && touch /var/log/wal-g-backup.log /var/log/wal-g-archive.log \
    && chown postgres:postgres /var/log/wal-g-backup.log /var/log/wal-g-archive.log

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf", \
                 "-c", "hba_file=/etc/postgresql/pg_hba.conf"]
