#!/usr/bin/env bash
# Remove laundry. Keeps /etc/laundry (DB, keys, config) unless --purge.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

systemctl disable --now laundry 2>/dev/null || true
rm -f /etc/systemd/system/laundry.service
systemctl daemon-reload

rm -rf /opt/laundry
rm -f /usr/local/bin/laundry
rm -f /etc/nginx/conf.d/site.conf /etc/nginx/conf.d/anticache.inc \
      /etc/nginx/conf.d/00-resolver.conf

if [[ "$PURGE" -eq 1 ]]; then
  echo "!! purging credentials, keys and config"
  rm -rf /etc/laundry /var/www/decoy /var/www/hidden /var/www/acme
else
  echo "kept /etc/laundry (DB/keys/config) and web roots. Use --purge to remove."
fi
echo "OpenResty package left installed (remove with: apt-get remove openresty)."
