-- auth.lua — silent Basic-auth gate, run in the access phase.
--
-- Golden rule: an unauthenticated OR invalid request is INDISTINGUISHABLE from a
-- normal anonymous visit — same status, headers, body, and (via timing padding)
-- latency. We never emit WWW-Authenticate, never 401, never a distinct error.
-- Only a valid PSK causes an internal redirect to the hidden route.

local config  = require "config"
local crypto  = require "crypto"
local store   = require "store"
local routing = require "routing"

local _M = {}
local cfg

-- init_worker phase: prepare crypto, cache, and background timers.
function _M.init_worker()
  cfg = config.get()
  math.randomseed(ngx.now() * 1000 + ngx.worker.pid())
  if not cfg.server_key then
    ngx.log(ngx.ERR, "laundry: LAUNDRY_SERVER_KEY(_FILE) not set — gate is inert, ",
                     "serving decoy only")
  end
  local ok, err = crypto.init()
  if not ok then ngx.log(ngx.ERR, "laundry: crypto init: ", err) end
  local ok2, err2 = store.init(cfg)
  if not ok2 then ngx.log(ngx.ERR, "laundry: store init: ", err2); return end
  store.start_timers()
end

-- Pad the request so hit/miss/malformed all take >= floor + jitter ms.
local function pad_timing(start_ms)
  local target = (cfg.timing_floor_ms or 0)
  local jitter = cfg.timing_jitter_ms or 0
  if jitter > 0 then target = target + math.random(0, jitter) end
  local elapsed = (ngx.now() * 1000) - start_ms
  local remaining_ms = target - elapsed
  if remaining_ms > 0 then
    ngx.sleep(remaining_ms / 1000)
  end
end

-- Parse "Authorization: Basic <b64(device:psk)>". Returns device_id, psk or nil.
local function parse_basic(hdr)
  if not hdr then return nil end
  local b64 = hdr:match("^%s*[Bb][Aa][Ss][Ii][Cc]%s+(%S+)%s*$")
  if not b64 then return nil end
  local raw = ngx.decode_base64(b64)
  if not raw then return nil end
  local device_id, psk = raw:match("^([^:]*):(.*)$")
  if not device_id or not psk or psk == "" then return nil end
  return device_id, psk
end

-- Extract the host[:port] from a URL, for the upstream Host header / SNI.
local function url_host(u)
  return (u:gsub("^%a+://", "")):match("^([^/]+)")
end

-- What to forward as the upstream Authorization header: "" (nginx omits it) when
-- stripping, else the client's original header.
local function fwd_auth(strip)
  return strip and "" or (ngx.var.http_authorization or "")
end

-- Resolve the decoy location, setting the upstream var when remote. Pure: it
-- decides and returns a location name but never calls ngx.exec itself.
local function decoy_location()
  if cfg and cfg.decoy_kind == "upstream" then
    ngx.var.decoy_upstream = cfg.decoy_target
    ngx.var.decoy_host = url_host(cfg.decoy_target) or ""
    ngx.var.fwd_auth = fwd_auth((not cfg) or cfg.strip_auth_decoy)
    return "@decoy_upstream"
  end
  return "/__laundry_decoy" .. ngx.var.uri -- local content under /var/www/decoy
end

-- decide() runs all the risky logic (parsing, crypto, lookup, routing) and
-- returns the location to dispatch to. It NEVER calls ngx.exec — that happens in
-- run(), outside the pcall, because ngx.exec unwinds via a Lua error that a pcall
-- would otherwise swallow. On any non-authenticated outcome it returns the decoy.
function _M.decide()
  if not cfg or not cfg.server_key then
    return decoy_location() -- misconfigured: reveal nothing, ever
  end

  local _device_id, psk = parse_basic(ngx.var.http_authorization)
  if not psk then return decoy_location() end

  local idx = crypto.keyed_blake2b(cfg.server_key, psk)
  if not idx then return decoy_location() end

  local cred = store.lookup(idx)
  if not cred then
    store.record_abuse(ngx.var.remote_addr)
    return decoy_location()
  end

  -- Defense in depth for a full DB+pepper compromise: verify the memory-hard
  -- Argon2id record once per key, then trust the fast index match thereafter.
  -- (An attacker cannot reach this branch without already knowing pepper+PSK,
  --  so it is not an online DoS vector.)
  if not store.is_verified(idx) then
    if crypto.pwhash_verify(cred.psk_verify, psk) then
      store.mark_verified(idx)
    else
      store.record_abuse(ngx.var.remote_addr)
      return decoy_location()
    end
  end

  local loc, rerr = routing.apply(cred)
  if not loc then
    ngx.log(ngx.ERR, "laundry: routing failed (device=", cred.device_id, "): ", rerr)
    return decoy_location()
  end

  ngx.var.fwd_auth = fwd_auth(cfg.strip_auth_hidden)
  store.record_connection(cred.device_id, ngx.var.remote_addr, cred.route_name)
  return loc
end

-- nginx access-phase entrypoint. Decides under pcall (fail-safe to the decoy on
-- any error — never a 500, which would be a tell), pads for timing uniformity,
-- then performs the single ngx.exec outside the protected call.
function _M.run()
  local start_ms = ngx.now() * 1000
  local ok, loc = pcall(_M.decide)
  if not ok then
    ngx.log(ngx.ERR, "laundry: decide error, falling back to decoy: ", loc)
    loc = decoy_location()
  elseif not loc then
    loc = decoy_location()
  end
  pad_timing(start_ms)
  return ngx.exec(loc)
end

return _M
