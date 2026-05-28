include config.env
export

.DEFAULT_GOAL := help

.PHONY: help certs keygen derive-keys setup build push deploy backup-list

help:
	@echo "  derive-keys  derive WAL-G key from passphrase+email (recoverable)"
	@echo "  certs        generate TLS cert+key (run once)"
	@echo "  keygen       print random WAL-G key (alternative to derive-keys)"
	@echo "  setup        derive-keys + certs, then show next steps"
	@echo "  build        docker build"
	@echo "  push         docker push"
	@echo "  deploy       render deploy.yaml → paste into console.akash.network"
	@echo "  backup-list  list backups in R2"

certs:
	@openssl req -new -x509 -days 3650 -nodes -subj "/CN=postgres" \
	    -keyout server.key -out server.crt 2>/dev/null
	@sed -i "s|^PG_TLS_CERT=.*|PG_TLS_CERT=$$(base64 -w0 server.crt)|" config.env
	@sed -i "s|^PG_TLS_KEY=.*|PG_TLS_KEY=$$(base64 -w0 server.key)|"  config.env
	@echo "server.crt → give to your backend  (sslmode=verify-ca&sslrootcert=server.crt)"
	@echo "server.key → save in password manager, never share"
	@echo "config.env → PG_TLS_CERT and PG_TLS_KEY updated"

keygen:
	@echo "WALG_LIBSODIUM_KEY=$$(openssl rand -base64 32)"

derive-keys:
	@./derive-keys.sh

setup: derive-keys certs
	@echo ""
	@echo "Next: fill config.env (POSTGRES_PASSWORD, R2_*)"
	@echo "Then: make build && make push && make deploy"

build:
	docker build -t $(REGISTRY_IMAGE) .

push:
	docker push $(REGISTRY_IMAGE)

deploy:
	@envsubst < deploy.yaml.template > deploy.yaml
	@echo "deploy.yaml ready — paste into console.akash.network > New Deployment > Custom SDL"

backup-list:
	docker run --env-file config.env --rm $(REGISTRY_IMAGE) wal-g backup-list --detail
