# Laundry — Deployment & Configuration Guide

A silent HTTP Basic-auth gateway on OpenResty. The public sees an ordinary site (the
**decoy**); a client presenting a valid pre-shared key is silently routed to a **hidden**
service. Wrong or absent credentials get the decoy, byte-for-byte identical, with no hint
anything is gated.

> **Scope of use.** This is for hosting *you own or are authorized to operate* — discreet
> admin surfaces, deniable/private hosting. A real, believable decoy and a real TLS
> certificate are what make it work; both are covered below.

---

## 1. How the gate works

```
                    ┌──────────────────── OpenResty (Server: nginx) ───────────────────┐
   client ──TLS──▶  │  access phase: parse Authorization → keyed-BLAKE2b lookup         │
                    │                                                                   │
                    │   no / wrong / malformed creds ──▶ DECOY   (local dir or upstream)│
                    │   valid PSK ─────────────────────▶ HIDDEN  (local dir or upstream)│
                    └───────────────────────────────────────────────────────────────────┘
```

- **Silent**: never sends `WWW-Authenticate`/`401`. Browsers won't auto-send Basic auth
  without a challenge, so a legitimate client supplies it deliberately.
- **Fast path** touches only memory: base64 decode → keyed BLAKE2b → shared-dict lookup.
  SQLite is read by a background timer, never on the request path.
- **Timing-normalized**: every request is padded to `floor + jitter` ms so an authenticated
  lookup is indistinguishable from the decoy by latency.
- **Fail-safe**: any internal error routes to the decoy, never a `500`.
- **Uniform surface**: the `Server` header, error pages, and status codes are identical on
  the decoy and hidden paths (verified by the test suite for 403/404/418/500/502/503).

---

## 2. The four topologies

The decoy and the hidden service are each independently **local** (files on the box) or
**remote** (proxied to another server). All combinations are configuration only.

| # | Decoy | Hidden | Settings |
|---|-------|--------|----------|
| 1 | local | local | `LAUNDRY_DECOY_KIND=internal`; hidden route `kind=internal` |
| 2 | local | remote | `LAUNDRY_DECOY_KIND=internal`; hidden route `kind=upstream --target https://backend` |
| 3 | remote | local | `LAUNDRY_DECOY_KIND=upstream --decoy-target http://decoy-host`; hidden route `kind=internal` |
| 4 | remote | remote | decoy upstream **+** hidden upstream — the box is a pure stealth front door |

```
Topology 4 (pure front door):

  client ─TLS─▶ laundry ──▶ decoy server   (anonymous / wrong)
                     └─────────▶ hidden server  (valid PSK)
```

- **Decoy** target is set once (env): `LAUNDRY_DECOY_KIND` + `LAUNDRY_DECOY_TARGET`.
- **Hidden** targets are per-credential, stored in the DB via `laundry route`:
  - `kind=upstream --target <url>` → proxy to any URL (remote or local).
  - `kind=internal --target <name>` → serve local files; requires a matching
    `location /__laundry_<name>/` in `nginx/conf.d/site.conf` (the shipped default is
    `site` → `/var/www/hidden`).

---

## 3. Configuration reference

### Environment (`/etc/laundry/laundry.env`)
Loaded by systemd and inherited by nginx workers (declared with `env` in `nginx.conf`).

| Variable | Default | Meaning |
|----------|---------|---------|
| `LAUNDRY_DB` | `/etc/laundry/laundry.db` | SQLite path (source of truth) |
| `LAUNDRY_SERVER_KEY_FILE` | `/etc/laundry/server.key` | Keyed-hash pepper file (or `LAUNDRY_SERVER_KEY` inline) |
| `LAUNDRY_SERVER_HEADER` | `nginx` | Spoofed `Server` header on every response |
| `LAUNDRY_DECOY_KIND` | `internal` | `internal` (local `/var/www/decoy`) or `upstream` |
| `LAUNDRY_DECOY_TARGET` | — | Decoy URL when kind=upstream (e.g. `http://decoy-host:80`) |
| `LAUNDRY_TIMING_FLOOR_MS` | `40` | Minimum per-request time |
| `LAUNDRY_TIMING_JITTER_MS` | `15` | Added random jitter |
| `LAUNDRY_REFRESH_INTERVAL` | `5` | Seconds between credential-cache reloads |
| `LAUNDRY_FLUSH_INTERVAL` | `5` | Seconds between write-flushes (connection log / abuse) |

### nginx knobs (`nginx/conf.d/site.conf`, `nginx.conf`)
- TLS cert paths: `/etc/nginx/ssl/server.{crt,key}`.
- Internal hidden roots: add a `location /__laundry_<name>/ { internal; alias /path/; index index.html; }` per internal route.
- Resolver: `/etc/nginx/conf.d/00-resolver.conf` (written by the installer/entrypoint) — needed for remote (upstream) targets.
- Anti-cache for hidden responses: `nginx/conf.d/anticache.inc`.

### Credentials & routes (SQLite, via `laundry`)
- `routes`: name → (`upstream`|`internal`, target).
- `credentials`: many concurrent PSKs; username is an arbitrary device-ID label, the PSK is the secret (stored as a peppered BLAKE2b index + Argon2id verifier, never raw).

---

## 4. Deploying on a VPS (Debian/Ubuntu + systemd)

```bash
sudo ./deploy/install.sh \
  --domain hidden.example.com --email you@example.com --letsencrypt \
  --decoy-kind internal --server-header nginx
```

The installer: adds the official OpenResty APT repo and installs it + `libsodium`/`libsqlite3`;
lays out `/opt/laundry` and `/etc/laundry`; mints the pepper; writes the env file;
initializes the DB with a ready `site` internal route; sets DB-dir permissions (workers run
as `nobody`, WAL needs a writable dir); installs and starts the `laundry` systemd
service; and (with `--letsencrypt`) obtains a real cert via acme.sh using the
`/.well-known/acme-challenge` webroot, with auto-renew + reload.

Without `--letsencrypt` it bootstraps a self-signed cert and warns you — **replace it before
going live**; a self-signed cert is the single biggest giveaway.

Then:
```bash
# put decoy content
sudo cp -r my-blog/*  /var/www/decoy/
# hidden content (internal route 'site') and/or a remote route
sudo cp -r secret-app/* /var/www/hidden/
sudo laundry route add --name app --kind upstream --target https://10.0.0.9
# mint credentials (PSK prints ONCE)
sudo laundry add --device laptop-01 --route site
sudo laundry add --device phone-02  --route app
```

Manage: `systemctl status|reload laundry`. Remove: `sudo ./deploy/uninstall.sh [--purge]`.

## 4b. Deploying with Docker

```bash
cd docker && docker compose up --build -d
docker compose exec gateway cat /shared/creds.env   # seeded test PSKs
```
Production: set `LAUNDRY_SERVER_KEY_FILE` to a real secret, disable `LAUNDRY_SEED_TEST_CREDS`,
mount real cert files over `/etc/nginx/ssl`, and set `LAUNDRY_DECOY_*` for your topology.

---

## 5. Credential operations

```bash
laundry add --device <id> [--route <name>] [--label <l>] [--expires <secs>]  # mint, prints PSK once
laundry list                    # all credentials
laundry revoke --device <id>    # or --id <n>; effective within LAUNDRY_REFRESH_INTERVAL
laundry connections --limit 50  # private monitor log of successful connections
laundry route add|list
laundry gen-key                 # new pepper (rotating it invalidates all PSKs)
```
- **Delivery**: give `device_id` + PSK to the client **out of band** (not over the gated site).
- **Client**: `curl -u 'device:psk' https://host/`, or `https://device:psk@host/`, or a
  browser extension that injects the `Authorization` header. No login box will ever appear.
- **Rotation**: revoke + re-mint per device; rotate the pepper to invalidate everything at once.

---

## 6. Hardening checklist

- [ ] **Real TLS cert** on a real domain (`--letsencrypt`). No self-signed in production.
- [ ] **Believable decoy** with real content/history — a bare page fools no one.
- [ ] **High-entropy PSKs** (the CLI mints 256-bit) delivered out of band.
- [ ] **Fingerprint parity**: confirm `Server` and error pages match a stock nginx of the
      same version you advertise; check TLS with `sslyze`/JA3/JA4 if your threat model warrants.
- [ ] **fail2ban** on the private `abuse` table / log to throttle guessing (response stays the decoy).
- [ ] **Firewall**: only 80/443 exposed; hidden backend reachable only from the gateway.
- [ ] **Log hygiene**: the `Authorization` header is never logged; keep it that way if you customize `log_format`.
- [ ] **Consistent cache headers** if your decoy sets unusual ones (the hidden path forces `no-store`).

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Empty/`000` responses | `location /` safety net (`444`) firing — check `error.log`; usually the gate errored before `ngx.exec`. |
| `attempt to write a readonly database` | DB dir not writable by the worker user; `chown -R nobody:nogroup /etc/laundry` (WAL needs it). |
| Valid PSK still gets decoy | Cache not refreshed yet (wait `LAUNDRY_REFRESH_INTERVAL`); wrong pepper (`LAUNDRY_SERVER_KEY(_FILE)` must match what minted the PSK); route unset on the credential. |
| Remote upstream fails (`502`) | Missing/incorrect resolver in `/etc/nginx/conf.d/00-resolver.conf`, or backend unreachable. |
| `Server: openresty` leaking | `LAUNDRY_SERVER_HEADER` not applied — confirm the `header_filter_by_lua` block and that config loaded. |
| Browser shows a login box | Something is sending `WWW-Authenticate` (a misconfigured backend). The gate never does. |

Logs: `/var/log/nginx/error.log`, `journalctl -u laundry`.

---

## 8. Residual risks

- **Traffic analysis**: hidden responses differ in size/shape from the decoy; a determined
  on-path observer may infer a hidden service exists even over TLS. Response padding/shaping
  is future work.
- **Replay**: a static PSK is replayable if TLS is broken/MITM'd. The schema reserves
  `authorized_keys` for a future public-key + timestamp signature mode that removes this.
- **First-request cost**: the first authenticated request per key per hour runs one Argon2id
  verify (~60ms, cached after); not attacker-triggerable.
- **Decoy realism & fingerprinting** are ultimately operational, not code, concerns — see the
  hardening checklist.
