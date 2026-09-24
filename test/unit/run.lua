-- Unit tests for the FFI-backed modules. Run under OpenResty's `resty` so
-- libsodium / libsqlite3 and LuaJIT FFI are available:
--     resty test/unit/run.lua
-- We stub a minimal ngx so routing.lua can run outside a request.

do
  local script = (arg and arg[0]) or ""
  local dir = script:match("^(.*)/[^/]*$") or "."
  package.path = dir .. "/../../lua/?.lua;" .. package.path
end

_G.ngx = _G.ngx or {}
ngx.var  = setmetatable({ uri = "/" }, { __index = function() return nil end })
ngx.time = os.time

local crypto  = require "crypto"
local sqlite  = require "sqlite"
local routing = require "routing"

local pass, fail = 0, 0
local function check(name, cond)
  if cond then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name) end
end

print("== crypto ==")
assert(crypto.init())
local key = "pepper-key-for-tests"
local h1 = crypto.keyed_blake2b(key, "hello")
local h2 = crypto.keyed_blake2b(key, "hello")
check("blake2b deterministic", h1 == h2)
check("blake2b hex length is 64", #h1 == 64)
check("blake2b changes with key", crypto.keyed_blake2b("other", "hello") ~= h1)
check("blake2b changes with msg", crypto.keyed_blake2b(key, "world") ~= h1)

local pw = crypto.pwhash_str("s3cr3t-psk")
check("argon2 encodes", type(pw) == "string" and pw:find("argon2") ~= nil)
check("argon2 verify accepts correct", crypto.pwhash_verify(pw, "s3cr3t-psk"))
check("argon2 verify rejects wrong", not crypto.pwhash_verify(pw, "nope"))

check("memeq equal", crypto.memeq("abc", "abc"))
check("memeq unequal", not crypto.memeq("abc", "abd"))
check("memeq length mismatch", not crypto.memeq("abc", "abcd"))
check("random_hex length", #crypto.random_hex(16) == 32)
check("random_hex uniqueness", crypto.random_hex(16) ~= crypto.random_hex(16))

print("== sqlite ==")
local path = os.tmpname()
local db = assert(sqlite.open(path))
assert(db:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER)"))
assert(db:exec("INSERT INTO t (name, n) VALUES (?, ?)", { "alice", 5 }))
assert(db:exec("INSERT INTO t (name, n) VALUES (?, ?)", { "bob", sqlite.NULL }))
local rows = assert(db:query("SELECT id, name, n FROM t ORDER BY id"))
check("sqlite row count", #rows == 2)
check("sqlite text column", rows[1].name == "alice")
check("sqlite int column", tonumber(rows[1].n) == 5)
check("sqlite null column", rows[2].n == nil)
local none = assert(db:query("SELECT * FROM t WHERE name = ?", { "nobody" }))
check("sqlite empty result", #none == 0)
db:close()
os.remove(path)

print("== routing ==")
local loc, _ = routing.apply({ route_kind = "upstream", route_target = "http://h:80" })
check("upstream -> @hidden_upstream", loc == "@hidden_upstream")
check("upstream sets $hidden_upstream", rawget(ngx.var, "hidden_upstream") == "http://h:80")
check("internal -> /__laundry_<name><uri>",
      (routing.apply({ route_kind = "internal", route_target = "site" })) == "/__laundry_site/")
check("internal rejects traversal",
      (routing.apply({ route_kind = "internal", route_target = "../evil" })) == nil)
check("unknown kind rejected", (routing.apply({ route_kind = "bogus" })) == nil)
check("missing route rejected", (routing.apply({})) == nil)

print("")
print(string.format("==== %d passed, %d failed ====", pass, fail))
os.exit(fail == 0 and 0 or 1)
