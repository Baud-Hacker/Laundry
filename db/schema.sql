-- laundry SQLite schema.
--
-- Source of truth for credentials and routing. The OpenResty workers only ever
-- READ this (via a background timer into a shared-dict cache); all writes come
-- from the offline `laundry` CLI or from the batched write-flush timer.

PRAGMA journal_mode = WAL;   -- concurrent readers while the CLI writes
PRAGMA foreign_keys = ON;

-- Where a validated credential is sent.
--   kind = 'upstream' -> target is an upstream URL     (proxy_pass)
--   kind = 'internal' -> target is a named location    (ngx.exec "@hidden_<target>")
CREATE TABLE IF NOT EXISTS routes (
  id      INTEGER PRIMARY KEY,
  name    TEXT    NOT NULL UNIQUE,
  kind    TEXT    NOT NULL CHECK (kind IN ('upstream', 'internal')),
  target  TEXT    NOT NULL
);

-- One row per active pre-shared key.
--   psk_index  = keyed BLAKE2b(server_key, psk)  -- fast lookup key, hex
--   psk_verify = Argon2id(psk)                   -- memory-hard at-rest verifier
-- The raw PSK is never stored.
CREATE TABLE IF NOT EXISTS credentials (
  id           INTEGER PRIMARY KEY,
  psk_index    TEXT    NOT NULL UNIQUE,
  psk_verify   TEXT    NOT NULL,
  device_id    TEXT    NOT NULL,          -- arbitrary label, not authenticated
  label        TEXT,
  route_id     INTEGER REFERENCES routes(id) ON DELETE SET NULL,
  active       INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER,                   -- NULL = never expires
  last_used_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_credentials_index  ON credentials(psk_index);
CREATE INDEX IF NOT EXISTS idx_credentials_device ON credentials(device_id);

-- Private device-connection monitor log (successful auths only). Written async;
-- never affects a response. For the operator to watch who is connecting.
CREATE TABLE IF NOT EXISTS connections (
  id         INTEGER PRIMARY KEY,
  ts         INTEGER NOT NULL,
  device_id  TEXT    NOT NULL,
  src_ip     TEXT,
  route_name TEXT
);

-- Private abuse counter (invalid attempts). Feeds fail2ban; never affects a
-- response. Keyed by source so counts collapse rather than growing unbounded.
CREATE TABLE IF NOT EXISTS abuse (
  src_ip     TEXT PRIMARY KEY,
  attempts   INTEGER NOT NULL DEFAULT 0,
  first_ts   INTEGER NOT NULL,
  last_ts    INTEGER NOT NULL
);

-- Reserved for the future public-key / signature-proof auth mode.
CREATE TABLE IF NOT EXISTS authorized_keys (
  id         INTEGER PRIMARY KEY,
  device_id  TEXT NOT NULL,
  algo       TEXT NOT NULL,
  public_key TEXT NOT NULL UNIQUE,
  route_id   INTEGER REFERENCES routes(id) ON DELETE SET NULL,
  active     INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  expires_at INTEGER
);
