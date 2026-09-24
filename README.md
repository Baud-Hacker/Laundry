# Laundry

A **silent HTTP Basic-auth gateway** built on OpenResty (nginx + LuaJIT). To the
outside world the host looks exactly like an ordinary nginx site (a WordPress-style
blog, the "decoy"). Clients that present a **valid pre-shared key** in the
`Authorization` header are silently routed to a hidden service; everyone else — no
credentials, wrong credentials, malformed input — gets the decoy, **byte-for-byte
identical**, with no hint that anything is gated.

> Intended for hosting you own/control (discreet admin surfaces, deniable/private
> hosting). Not a tool for evading controls on systems you don't own.

**Deploying for real?** See **[GUIDE.md](GUIDE.md)** — bare-metal installer, the four
local/remote topologies, full config reference, TLS, credential ops, and hardening.

## Demo

![Laundry in action — the same URL shows a decoy to everyone, and the hidden service only to a client with a valid pre-shared key](docs/laundry-demo.gif)

Same address throughout: an anonymous visitor sees the decoy; supplying a valid
pre-shared key silently reveals the hidden service — no login prompt, ever.
[Higher-quality video (webm)](docs/laundry-demo.webm).

## How it works

```
client ──TLS──> OpenResty  (Server: nginx/…, identical fingerprint)
                  │  access_by_lua → parse Authorization → keyed-BLAKE2b lookup
                  ├─ no/invalid creds ─────────────────> decoy site   (identical 200)
                  └─ valid PSK ──> per-credential route:
                                     ├─ upstream  → proxy to a hidden backend
                                     └─ internal  → serve local hidden content
```

- **Silent.** No `WWW-Authenticate`, no `401`, ever. Browsers won't auto-send Basic
  auth without a challenge, so a legitimate client supplies it deliberately:
  `curl -u 'device:psk' https://host/` or `https://device:psk@host/`.
- **Fast path never touches disk.** SQLite is the source of truth; a background timer
  loads credentials into shared memory. Each request only does a base64 decode, a
  keyed BLAKE2b, and a shared-dict lookup.
- **Timing-normalized.** Every request is padded to `floor + jitter` ms so a valid
  lookup can't be distinguished from the decoy path by latency.
- **Strong anti-cache** on hidden responses; validators (`ETag`/`Last-Modified`)
  stripped so no intermediary can cache or revalidate hidden content.

## Layout

| Path | Purpose |
|------|---------|
| `lua/crypto.lua`  | libsodium via FFI — keyed BLAKE2b, Argon2id, constant-time compare |
| `lua/sqlite.lua`  | minimal libsqlite3 FFI binding (no external Lua deps) |
| `lua/config.lua`  | env-driven settings (db path, pepper, timing) |
| `lua/store.lua`   | SQLite → shared-dict cache, refresh + write-flush timers |
| `lua/routing.lua` | credential → internal redirect target |
| `lua/auth.lua`    | the silent access-phase gate |
| `bin/laundry` | offline credential/route management CLI |
| `db/schema.sql`   | SQLite schema |
| `nginx/`          | `nginx.conf` (stealth hardening) + `conf.d/site.conf` |
| `docker/`         | build + a full test rig (gateway, decoy, hidden backend) |
| `test/`           | `unit/` (resty) and `integration/` (curl black-box) |

## Configuration (environment)

| Var | Default | Meaning |
|-----|---------|---------|
| `LAUNDRY_DB` | `/etc/laundry/laundry.db` | SQLite path |
| `LAUNDRY_SERVER_KEY` / `LAUNDRY_SERVER_KEY_FILE` | — | **required** keyed-hash pepper (kept out of the DB) |
| `LAUNDRY_SERVER_HEADER` | `nginx` | spoofed `Server` header on every response |
| `LAUNDRY_DECOY_KIND` | `internal` | `internal` (local `/var/www/decoy`) or `upstream` |
| `LAUNDRY_DECOY_TARGET` | — | decoy URL when kind=upstream |
| `LAUNDRY_STRIP_AUTH_DECOY` | `true` | strip `Authorization` before proxying to the decoy |
| `LAUNDRY_STRIP_AUTH_HIDDEN` | `true` | strip `Authorization` before proxying to the hidden backend |
| `LAUNDRY_REFRESH_INTERVAL` | `5` | seconds between cache reloads |
| `LAUNDRY_FLUSH_INTERVAL` | `5` | seconds between write-flushes |
| `LAUNDRY_TIMING_FLOOR_MS` | `40` | minimum per-request time |
| `LAUNDRY_TIMING_JITTER_MS` | `15` | added random jitter |

Env vars must also be declared with `env` in `nginx.conf` (already done). The decoy and
hidden service can each be local or remote — see **[GUIDE.md](GUIDE.md)** for the four
topologies.

## Quick start (Docker)

```bash
cd docker
docker compose up --build -d
# anonymous → the decoy blog
curl -sk https://localhost:8443/ | grep -o 'The Daily Loaf'
# grab the seeded test PSKs
docker compose exec gateway cat /shared/creds.env
# authenticate → hidden content
curl -sk -u 'dev-internal:<psk>' https://localhost:8443/ | grep -o 'HIDDEN-SERVICE-OK'
```

## Managing credentials

```bash
# inside the gateway container (LAUNDRY_DB / server key already in its env)
laundry gen-key                                   # mint a pepper (server_key)
laundry init-db
laundry route add --name hidden_app --kind upstream --target http://hidden:80
laundry route add --name site       --kind internal --target site
#   ^ an internal route with --target NAME requires a matching, more-specific
#     prefix location in site.conf:
#         location /__laundry_NAME/ { internal; alias /path/to/content/; index index.html; }
#     (out-ranking `location /` so its index/try_files redirect never re-enters
#      the gate). The `upstream` kind needs no extra config.
laundry add --device laptop-01 --route site        # prints the PSK ONCE
laundry list
laundry revoke --device laptop-01
laundry connections --limit 20                     # private monitor log
```

Changes take effect on the next cache refresh (≤ `LAUNDRY_REFRESH_INTERVAL`).

## Testing

```bash
# unit (crypto / sqlite / routing)
docker compose run --rm gateway resty /opt/laundry/test/unit/run.lua
# integration (black-box, needs the stack up)
docker compose --profile test up --build --abort-on-container-exit tests
```

## Security notes & residual risks

- **TLS is mandatory.** Basic auth is base64, not encryption. Port 80 only redirects.
- **Use high-entropy PSKs.** `laundry add` mints 256-bit keys. The fast path
  authenticates by keyed-BLAKE2b index (peppered, ~5µs); Argon2id (interactive params,
  ~60ms) is a memory-hard at-rest verifier checked **once per key per hour** (cached in
  shared memory) that protects against a full DB+pepper compromise. Only the first
  authenticated request per key pays it; steady-state authenticated requests match the
  decoy path's timing. That first-hit cost cannot be triggered by an attacker (they'd
  need pepper+PSK to reach it), so it is not a DoS vector.
- **Traffic analysis.** Hidden responses differ in size/shape from the decoy; a
  determined on-path observer may still infer a hidden service exists. Response
  padding/shaping is future work.
- **Replay.** A static PSK is replayable if TLS is broken/MITM'd. The schema reserves
  `authorized_keys` for a future public-key + timestamp signature mode that removes this.
- **Differential headers.** Aggressive anti-cache is applied only to hidden responses;
  if your decoy sets very different cache headers this is a faint tell. Consider a
  consistent site-wide cache policy for maximum uniformity.
- **Brute force / abuse** is recorded to a private counter (for fail2ban) without ever
  changing the response.
