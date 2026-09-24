#!/usr/bin/env bash
# laundry installer for Debian/Ubuntu + systemd.
#
# Installs OpenResty (official repo) + runtime libs, lays out the app under
# /opt/laundry and /etc/laundry, provisions a cert (self-signed by
# default, Let's Encrypt with --letsencrypt), and starts a systemd service.
#
# Usage:
#   sudo ./deploy/install.sh [options]
# Options:
#   --domain <fqdn>          Server name / cert domain (required for --letsencrypt)
#   --email <addr>           Registration email for Let's Encrypt
#   --letsencrypt            Obtain a real cert via acme.sh (needs :80 reachable)
#   --decoy-kind <k>         internal (default) | upstream
#   --decoy-target <url>     Decoy URL when --decoy-kind=upstream
#   --server-header <s>      Spoofed Server header (default: nginx)
set -euo pipefail

DOMAIN="" EMAIL="" LETSENCRYPT=0
DECOY_KIND="internal" DECOY_TARGET="" SERVER_HEADER="nginx"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)        DOMAIN="$2"; shift 2;;
    --email)         EMAIL="$2"; shift 2;;
    --letsencrypt)   LETSENCRYPT=1; shift;;
    --decoy-kind)    DECOY_KIND="$2"; shift 2;;
    --decoy-target)  DECOY_TARGET="$2"; shift 2;;
    --server-header) SERVER_HEADER="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# --- OS detection -----------------------------------------------------------
. /etc/os-release
CODENAME="${VERSION_CODENAME:-$(lsb_release -sc 2>/dev/null || true)}"
case "$ID" in
  ubuntu) OR_URL="http://openresty.org/package/ubuntu";  OR_COMP="main";;
  debian) OR_URL="http://openresty.org/package/debian";  OR_COMP="openresty";;
  *) case "${ID_LIKE:-}" in
       *ubuntu*) OR_URL="http://openresty.org/package/ubuntu"; OR_COMP="main";;
       *debian*) OR_URL="http://openresty.org/package/debian"; OR_COMP="openresty";;
       *) echo "unsupported distro: $ID (need Debian/Ubuntu)" >&2; exit 1;;
     esac;;
esac

echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  wget curl gnupg ca-certificates lsb-release openssl socat cron perl \
  libsodium23 libsqlite3-0
if ! command -v openresty >/dev/null 2>&1; then
  wget -qO - https://openresty.org/package/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
  echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] $OR_URL $CODENAME $OR_COMP" \
    > /etc/apt/sources.list.d/openresty.list
  apt-get update -qq
  apt-get install -y -qq openresty
fi

# --- Layout -----------------------------------------------------------------
echo "==> Laying out files"
install -d /opt/laundry/{lua,db,bin} /etc/laundry/ssl \
           /etc/nginx/conf.d /var/www/decoy /var/www/hidden /var/www/acme \
           /var/log/nginx
cp -f "$REPO"/lua/*.lua        /opt/laundry/lua/
cp -f "$REPO"/db/schema.sql    /opt/laundry/db/
cp -f "$REPO"/bin/laundry  /usr/local/bin/laundry
chmod +x /usr/local/bin/laundry
cp -f "$REPO"/nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
cp -f "$REPO"/nginx/conf.d/site.conf      /etc/nginx/conf.d/site.conf
cp -f "$REPO"/nginx/conf.d/anticache.inc  /etc/nginx/conf.d/anticache.inc
rm -f /etc/nginx/conf.d/default.conf
# Seed a default decoy page if the operator hasn't placed one yet.
[[ -f /var/www/decoy/index.html ]] || cp -f "$REPO"/decoy/index.html /var/www/decoy/ 2>/dev/null || true

# --- DNS resolver (for variable proxy_pass to remote upstreams) -------------
RESOLVER="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
[[ -n "$RESOLVER" ]] || RESOLVER="1.1.1.1"
echo "resolver $RESOLVER ipv6=off valid=30s;" > /etc/nginx/conf.d/00-resolver.conf

# --- Secrets + config -------------------------------------------------------
echo "==> Generating server key and config"
if [[ ! -s /etc/laundry/server.key ]]; then
  laundry gen-key > /etc/laundry/server.key 2>/dev/null
fi
chmod 600 /etc/laundry/server.key

ENV_FILE=/etc/laundry/laundry.env
if [[ ! -f "$ENV_FILE" ]]; then
  sed -e "s|^LAUNDRY_SERVER_HEADER=.*|LAUNDRY_SERVER_HEADER=$SERVER_HEADER|" \
      -e "s|^LAUNDRY_DECOY_KIND=.*|LAUNDRY_DECOY_KIND=$DECOY_KIND|" \
      -e "s|^LAUNDRY_DECOY_TARGET=.*|LAUNDRY_DECOY_TARGET=$DECOY_TARGET|" \
      "$REPO/deploy/laundry.env.example" > "$ENV_FILE"
fi

# --- Database ---------------------------------------------------------------
echo "==> Initializing database"
export LAUNDRY_DB=/etc/laundry/laundry.db
[[ -f "$LAUNDRY_DB" ]] || {
  laundry init-db
  # A ready-to-use internal route (matches location /__laundry_site/ in site.conf).
  laundry route add --name site --kind internal --target site
}

# --- Permissions (workers run as 'nobody'; WAL needs a writable DB dir) ------
chown -R nobody:nogroup /etc/laundry /var/log/nginx

# --- TLS certificate --------------------------------------------------------
if [[ ! -f /etc/nginx/ssl/server.crt ]]; then
  install -d /etc/nginx/ssl
  echo "==> Generating bootstrap self-signed certificate"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/nginx/ssl/server.key -out /etc/nginx/ssl/server.crt \
    -days 365 -subj "/CN=${DOMAIN:-localhost}" >/dev/null 2>&1
fi

# --- systemd service --------------------------------------------------------
echo "==> Installing systemd service"
cp -f "$REPO/deploy/laundry.service" /etc/systemd/system/laundry.service
systemctl daemon-reload
systemctl enable --now laundry

# --- Let's Encrypt (optional) ----------------------------------------------
if [[ "$LETSENCRYPT" -eq 1 ]]; then
  [[ -n "$DOMAIN" && -n "$EMAIL" ]] || { echo "--letsencrypt needs --domain and --email" >&2; exit 1; }
  echo "==> Obtaining Let's Encrypt certificate for $DOMAIN"
  if [[ ! -d "$HOME/.acme.sh" ]]; then
    curl -s https://get.acme.sh | sh -s email="$EMAIL"
  fi
  ACME="$HOME/.acme.sh/acme.sh"
  "$ACME" --issue -d "$DOMAIN" -w /var/www/acme --server letsencrypt
  "$ACME" --install-cert -d "$DOMAIN" \
    --key-file       /etc/nginx/ssl/server.key \
    --fullchain-file /etc/nginx/ssl/server.crt \
    --reloadcmd      "systemctl reload laundry"
  systemctl reload laundry
else
  echo "!! Using a SELF-SIGNED certificate — a stealth giveaway. Re-run with"
  echo "!! --letsencrypt --domain <fqdn> --email <you> once DNS points here."
fi

cat <<EOF

==> Done. laundry is running.

Next steps:
  1. Put your decoy content in    /var/www/decoy   (or set upstream decoy in $ENV_FILE)
  2. Put hidden content in        /var/www/hidden  (internal route 'site'),
     and/or add an upstream route: laundry route add --name app --kind upstream --target https://backend
  3. Mint a credential:           laundry add --device laptop-01 --route site
     (the PSK prints once — deliver it to the client out of band)
  4. Client access:               curl -u 'laptop-01:<psk>' https://$DOMAIN/

Manage: systemctl status|reload laundry   Config: $ENV_FILE
EOF
