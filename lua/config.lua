-- config.lua — single source of runtime settings, read once per worker.
--
-- Values come from environment variables (declare them with `env` in nginx.conf)
-- with safe defaults. The server_key (keyed-hash pepper) is mandatory and is
-- read from a file if LAUNDRY_SERVER_KEY_FILE is set, else from LAUNDRY_SERVER_KEY.

local _M = {}

local function getenv(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  return v
end

local function getbool(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  v = v:lower()
  return not (v == "0" or v == "false" or v == "no" or v == "off")
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  -- trim trailing whitespace/newline so a keyfile edited by hand still works
  return (data:gsub("%s+$", ""))
end

local cache

function _M.get()
  if cache then return cache end

  local server_key
  local key_file = getenv("LAUNDRY_SERVER_KEY_FILE")
  if key_file then
    server_key = read_file(key_file)
  else
    server_key = getenv("LAUNDRY_SERVER_KEY")
  end

  cache = {
    db_path          = getenv("LAUNDRY_DB", "/etc/laundry/laundry.db"),
    server_key       = server_key,
    refresh_interval = tonumber(getenv("LAUNDRY_REFRESH_INTERVAL", "5")),
    flush_interval   = tonumber(getenv("LAUNDRY_FLUSH_INTERVAL", "5")),
    -- Spoofed Server header, applied to every response. Bare "nginx" by default.
    server_header    = getenv("LAUNDRY_SERVER_HEADER", "nginx"),
    -- Decoy target. kind "internal" serves /var/www/decoy locally; kind "upstream"
    -- proxies to decoy_target (a URL), so the decoy can be local or remote.
    decoy_kind       = getenv("LAUNDRY_DECOY_KIND", "internal"),
    decoy_target     = getenv("LAUNDRY_DECOY_TARGET", ""),
    -- Timing normalization: every gated request is padded to at least
    -- floor_ms + random(0..jitter_ms) so hit/miss/malformed are indistinguishable.
    timing_floor_ms  = tonumber(getenv("LAUNDRY_TIMING_FLOOR_MS", "40")),
    timing_jitter_ms = tonumber(getenv("LAUNDRY_TIMING_JITTER_MS", "15")),
    -- Strip the client Authorization header before proxying, so the PSK (hidden)
    -- and failed creds (decoy) never reach the backend. Independent per path,
    -- both strip by default; set the relevant flag to false to forward.
    strip_auth_decoy  = getbool("LAUNDRY_STRIP_AUTH_DECOY", true),
    strip_auth_hidden = getbool("LAUNDRY_STRIP_AUTH_HIDDEN", true),
  }
  return cache
end

return _M
