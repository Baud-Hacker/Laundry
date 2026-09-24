#!/bin/bash
# Gateway entrypoint: prepare TLS, the credential DB, routes and (for testing)
# a couple of credentials, then start OpenResty. Idempotent.
set -euo pipefail

: "${LAUNDRY_DB:=/etc/laundry/laundry.db}"
export LAUNDRY_DB

SSL_DIR=/etc/nginx/ssl
SHARED=/shared           # volume the integration tests read PSKs from

# 0. DNS resolver for variable proxy_pass. In Docker this is the embedded DNS.
echo 'resolver 127.0.0.11 ipv6=off valid=30s;' > /etc/nginx/conf.d/00-resolver.conf

# 1. Self-signed cert (looks like any default TLS host).
if [[ ! -f "$SSL_DIR/server.crt" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$SSL_DIR/server.key" -out "$SSL_DIR/server.crt" \
    -days 365 -subj "/CN=example.com" >/dev/null 2>&1
fi

# 2. Server key (pepper). In production set LAUNDRY_SERVER_KEY_FILE to a real secret;
#    here we accept LAUNDRY_SERVER_KEY from compose, or mint one and persist it.
if [[ -z "${LAUNDRY_SERVER_KEY:-}" && -z "${LAUNDRY_SERVER_KEY_FILE:-}" ]]; then
  KEYFILE=/etc/laundry/server.key
  [[ -f "$KEYFILE" ]] || laundry gen-key > "$KEYFILE" 2>/dev/null
  export LAUNDRY_SERVER_KEY_FILE="$KEYFILE"
fi

# 3. DB + routes + (optional) test creds. Seeding is coupled to DB creation so the
#    PSKs in creds.env always match the DB — they can never drift if the DB is
#    recreated while an old creds.env lingers on the shared volume.
if [[ ! -f "$LAUNDRY_DB" ]]; then
  laundry init-db
  laundry route add --name hidden_app  --kind upstream --target "http://hidden:80"
  laundry route add --name site        --kind internal --target "site"

  if [[ -n "${LAUNDRY_SEED_TEST_CREDS:-}" ]]; then
    mkdir -p "$SHARED"
    UP=$(laundry add --device dev-upstream --route hidden_app 2>/dev/null | awk '/^psk:/{print $2}')
    IN=$(laundry add --device dev-internal --route site       2>/dev/null | awk '/^psk:/{print $2}')
    {
      echo "UPSTREAM_DEVICE=dev-upstream"
      echo "UPSTREAM_PSK=$UP"
      echo "INTERNAL_DEVICE=dev-internal"
      echo "INTERNAL_PSK=$IN"
    } > "$SHARED/creds.env"
    echo "seeded test creds -> $SHARED/creds.env"
  fi
fi

# Workers run as 'nobody'; WAL-mode SQLite needs write access to the DB dir (for
# -wal/-shm) even on reads, and workers write the access log.
chown -R nobody:nobody /etc/laundry /var/log/nginx 2>/dev/null || true

exec /usr/local/openresty/bin/openresty -g "daemon off;"
