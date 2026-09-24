-- store.lua — SQLite -> shared-memory cache, plus async write-flush.
--
-- The request path NEVER opens SQLite. A background timer (worker 0 only) loads
-- credentials + their route into the `creds` shared dict; a second timer flushes
-- queued connection logs and abuse counters back to SQLite in batches.

local cjson  = require "cjson.safe"
local sqlite = require "sqlite"

local _M = {}

local cfg
local D_CREDS -- ngx.shared.laundry_creds    : psk_index -> json(cred)
local D_CONN  -- ngx.shared.laundry_conn     : list queue of json(connection)
local D_ABUSE -- ngx.shared.laundry_abuse    : src_ip -> attempt count
local D_VERIF -- ngx.shared.laundry_verified : psk_index -> 1 (Argon2id verified)

local VERIFY_TTL = 3600 -- re-run the memory-hard verify at most hourly per key

function _M.init(config)
  cfg = config
  D_CREDS = ngx.shared.laundry_creds
  D_CONN  = ngx.shared.laundry_conn
  D_ABUSE = ngx.shared.laundry_abuse
  D_VERIF = ngx.shared.laundry_verified
  if not (D_CREDS and D_CONN and D_ABUSE and D_VERIF) then
    return nil, "missing lua_shared_dict (laundry_creds/laundry_conn/laundry_abuse/laundry_verified)"
  end
  return true
end

-- One-time Argon2id verification cache (keyed by psk_index).
function _M.is_verified(idx)
  return D_VERIF:get(idx) == 1
end

function _M.mark_verified(idx)
  D_VERIF:set(idx, 1, VERIFY_TTL)
end

-- Load all active credentials (joined with their route) into the creds dict.
-- Deletions are handled with a generation stamp: entries not seen this pass are
-- dropped afterwards.
function _M.refresh()
  local conn, err = sqlite.open(cfg.db_path)
  if not conn then
    ngx.log(ngx.ERR, "laundry: db open failed: ", err)
    return
  end

  local rows, qerr = conn:query([[
    SELECT c.psk_index, c.psk_verify, c.device_id, c.active, c.expires_at,
           r.name AS route_name, r.kind AS route_kind, r.target AS route_target
    FROM credentials c
    LEFT JOIN routes r ON r.id = c.route_id
    WHERE c.active = 1
  ]])
  conn:close()
  if not rows then
    ngx.log(ngx.ERR, "laundry: refresh query failed: ", qerr)
    return
  end

  local gen = (tonumber(D_CREDS:get("__gen")) or 0) + 1
  for _, row in ipairs(rows) do
    row.__gen = gen
    D_CREDS:set(row.psk_index, cjson.encode(row))
  end
  D_CREDS:set("__gen", gen)

  -- Sweep stale keys from previous generations.
  for _, key in ipairs(D_CREDS:get_keys(0)) do
    if key ~= "__gen" then
      local v = D_CREDS:get(key)
      if v then
        local rec = cjson.decode(v)
        if not rec or rec.__gen ~= gen then
          D_CREDS:delete(key)
        end
      end
    end
  end
end

-- lookup(psk_index) -> cred table or nil. Applies active/expiry checks.
function _M.lookup(psk_index)
  local v = D_CREDS:get(psk_index)
  if not v then return nil end
  local cred = cjson.decode(v)
  if not cred then return nil end
  if tonumber(cred.active) ~= 1 then return nil end
  if cred.expires_at and tonumber(cred.expires_at) <= ngx.time() then
    return nil
  end
  return cred
end

-- record_connection / record_abuse are called on the request path but only touch
-- shared memory; the flush timer persists them.
function _M.record_connection(device_id, src_ip, route_name)
  local entry = cjson.encode({
    ts = ngx.time(), device_id = device_id, src_ip = src_ip, route_name = route_name,
  })
  D_CONN:rpush("q", entry)
end

function _M.record_abuse(src_ip)
  if not src_ip then return end
  local newval, err = D_ABUSE:incr(src_ip, 1, 0)
  if not newval and err == "not found" then
    D_ABUSE:set(src_ip, 1)
  end
end

-- Persist queued connections and abuse counters, then reset the buffers.
function _M.flush_writes()
  local conn = select(1, sqlite.open(cfg.db_path))
  if not conn then return end

  -- Connections: drain the list queue.
  while true do
    local item = D_CONN:lpop("q")
    if not item then break end
    local e = cjson.decode(item)
    if e then
      conn:exec(
        "INSERT INTO connections (ts, device_id, src_ip, route_name) VALUES (?, ?, ?, ?)",
        { e.ts, e.device_id, e.src_ip or sqlite.NULL, e.route_name or sqlite.NULL })
    end
  end

  -- Abuse: upsert per-IP counts, then clear the in-memory tally.
  local now = ngx.time()
  for _, ip in ipairs(D_ABUSE:get_keys(0)) do
    local n = D_ABUSE:get(ip)
    if n and n > 0 then
      conn:exec([[
        INSERT INTO abuse (src_ip, attempts, first_ts, last_ts)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(src_ip) DO UPDATE SET
          attempts = attempts + excluded.attempts,
          last_ts  = excluded.last_ts
      ]], { ip, n, now, now })
      D_ABUSE:delete(ip)
    end
  end

  conn:close()
end

-- Start the background timers on worker 0 only.
function _M.start_timers()
  if ngx.worker.id() ~= 0 then return end

  local function refresh_cb(premature)
    if premature then return end
    local ok, e = pcall(_M.refresh)
    if not ok then ngx.log(ngx.ERR, "laundry: refresh error: ", e) end
  end
  -- Prime immediately, then on interval.
  refresh_cb(false)
  ngx.timer.every(cfg.refresh_interval, refresh_cb)

  ngx.timer.every(cfg.flush_interval, function(premature)
    if premature then return end
    local ok, e = pcall(_M.flush_writes)
    if not ok then ngx.log(ngx.ERR, "laundry: flush error: ", e) end
  end)
end

return _M
