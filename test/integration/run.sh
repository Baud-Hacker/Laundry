#!/usr/bin/env bash
# Black-box integration tests against the running gateway (compose service).
# Verifies the core stealth guarantees end-to-end.
set -uo pipefail

BASE="https://gateway"
CURL="curl -sk"           # -k: self-signed cert in the test rig
CREDS="/shared/creds.env"

pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "waiting for gateway + seeded creds..."
for _ in $(seq 1 30); do
  [[ -f "$CREDS" ]] && $CURL -o /dev/null "$BASE/" && break
  sleep 1
done
[[ -f "$CREDS" ]] || { echo "creds.env never appeared"; exit 1; }
# shellcheck disable=SC1090
source "$CREDS"

DECOY_MARK="The Daily Loaf"
HIDDEN_MARK="HIDDEN-SERVICE-OK"

echo "== 1. anonymous request sees the decoy =="
body=$($CURL "$BASE/")
hdrs=$($CURL -D - -o /dev/null "$BASE/")
grep -q "$DECOY_MARK" <<<"$body" && ok "decoy body served" || bad "decoy body missing"
grep -qiE '^Server: nginx\r?$' <<<"$hdrs" && ok "Server header spoofed to bare nginx" || bad "Server header wrong: $(grep -i '^Server:' <<<"$hdrs")"
grep -qi 'WWW-Authenticate' <<<"$hdrs" && bad "leaked WWW-Authenticate!" || ok "no WWW-Authenticate challenge"
grep -q '200' <<<"$(head -1 <<<"$hdrs")" && ok "200 OK" || bad "not 200: $(head -1 <<<"$hdrs")"

echo "== 2. wrong credentials are indistinguishable from anonymous =="
$CURL "$BASE/" > /tmp/anon.body
$CURL -u "nobody:wrongwrongwrong" "$BASE/" > /tmp/wrong.body
if diff -q /tmp/anon.body /tmp/wrong.body >/dev/null; then
  ok "wrong-cred body byte-identical to anonymous"
else
  bad "wrong-cred body differs from anonymous"
fi
grep -q "$HIDDEN_MARK" /tmp/wrong.body && bad "hidden content leaked to wrong creds!" || ok "no hidden content on wrong creds"

echo "== 3. valid PSK (upstream route) reaches the hidden backend =="
body=$($CURL -u "$UPSTREAM_DEVICE:$UPSTREAM_PSK" "$BASE/")
grep -q "$HIDDEN_MARK" <<<"$body" && ok "upstream route served hidden content" || bad "upstream route did not reach hidden backend"

echo "== 4. valid PSK (internal route) reaches local hidden content =="
body=$($CURL -u "$INTERNAL_DEVICE:$INTERNAL_PSK" "$BASE/")
grep -q "$HIDDEN_MARK" <<<"$body" && ok "internal route served hidden content" || bad "internal route did not serve local hidden content"

echo "== 5. hidden responses carry strong anti-cache headers =="
hh=$($CURL -D - -o /dev/null -u "$INTERNAL_DEVICE:$INTERNAL_PSK" "$BASE/")
grep -qi 'Cache-Control:.*no-store' <<<"$hh" && ok "Cache-Control no-store present" || bad "no-store missing"
grep -qi '^ETag:' <<<"$hh" && bad "ETag not stripped" || ok "ETag stripped"
grep -qi '^Last-Modified:' <<<"$hh" && bad "Last-Modified not stripped" || ok "Last-Modified stripped"

echo "== 6. timing: valid vs wrong vs anon overlap (informational) =="
measure() { # $1 curl-args...  -> mean ms over 10 reqs
  local total=0 t
  for _ in $(seq 1 10); do
    t=$($CURL -o /dev/null -w '%{time_total}' "$@" "$BASE/")
    total=$(awk -v a="$total" -v b="$t" 'BEGIN{print a+b*1000}')
  done
  awk -v s="$total" 'BEGIN{printf "%.0f", s/10}'
}
m_anon=$(measure)
m_wrong=$(measure -u "x:y")
m_valid=$(measure -u "$INTERNAL_DEVICE:$INTERNAL_PSK")
echo "  mean ms  anon=$m_anon  wrong=$m_wrong  valid=$m_valid  (floor=40, jitter=15)"
[[ "$m_anon" -ge 30 && "$m_wrong" -ge 30 ]] && ok "timing floor applied to decoy paths" || bad "timing floor not applied"

echo "== 7. status-code propagation & parity (decoy vs hidden) =="
for c in 403 404 418 500 502 503; do
  a=$($CURL -o /dev/null -w '%{http_code}' "$BASE/status/$c")                              # anon -> decoy
  w=$($CURL -o /dev/null -w '%{http_code}' -u "nobody:wrong" "$BASE/status/$c")            # wrong -> decoy
  u=$($CURL -o /dev/null -w '%{http_code}' -u "$UPSTREAM_DEVICE:$UPSTREAM_PSK" "$BASE/status/$c") # valid -> hidden
  [[ "$a" == "$c" ]] && ok "decoy propagates $c" || bad "decoy $c returned $a"
  [[ "$w" == "$a" ]] && ok "wrong-cred matches decoy on $c" || bad "wrong-cred $c returned $w (decoy=$a)"
  [[ "$u" == "$c" ]] && ok "hidden propagates $c" || bad "hidden $c returned $u"
done
# The internal (local) hidden route returns a real 404 for a missing file.
i404=$($CURL -o /dev/null -w '%{http_code}' -u "$INTERNAL_DEVICE:$INTERNAL_PSK" "$BASE/no-such-file-xyz")
[[ "$i404" == "404" ]] && ok "internal hidden 404 on missing file" || bad "internal missing file returned $i404"
# Error responses must keep the stealth properties.
eh=$($CURL -D - -o /dev/null "$BASE/status/500")
grep -qiE '^Server: nginx\r?$' <<<"$eh" && ok "decoy error carries bare nginx Server" || bad "decoy error Server header wrong"
he=$($CURL -D - -o /dev/null -u "$UPSTREAM_DEVICE:$UPSTREAM_PSK" "$BASE/status/500")
grep -qi 'Cache-Control:.*no-store' <<<"$he" && ok "hidden error stays anti-cached" || bad "hidden error missing no-store"
grep -qiE '^Server: nginx\r?$' <<<"$he" && ok "hidden error carries bare nginx Server" || bad "hidden error Server header wrong"
# The 444 safety net must never fire on a normal request.
[[ "$($CURL -o /dev/null -w '%{http_code}' "$BASE/")" != "000" ]] && ok "gate never drops to 444 on decoy" || bad "gate returned 444"

echo
echo "==== $pass passed, $fail failed ===="
[[ "$fail" -eq 0 ]]
