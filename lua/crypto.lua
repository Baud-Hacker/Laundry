-- crypto.lua — libsodium-backed primitives for laundry.
--
-- Uses BLAKE2b (keyed) as the fast lookup index and Argon2id as the memory-hard
-- at-rest verifier. All secret comparisons go through sodium_memcmp (constant time).
-- Bound to libsodium directly via LuaJIT FFI so we carry no extra Lua deps.

local ffi = require "ffi"

ffi.cdef [[
int    sodium_init(void);
int    crypto_generichash(unsigned char *out, size_t outlen,
                          const unsigned char *in, unsigned long long inlen,
                          const unsigned char *key, size_t keylen);
size_t crypto_generichash_bytes(void);
size_t crypto_generichash_keybytes_max(void);

int    crypto_pwhash_str(char *out,
                         const char *passwd, unsigned long long passwdlen,
                         unsigned long long opslimit, size_t memlimit);
int    crypto_pwhash_str_verify(const char *str,
                                const char *passwd, unsigned long long passwdlen);
size_t crypto_pwhash_strbytes(void);
unsigned long long crypto_pwhash_opslimit_interactive(void);
size_t crypto_pwhash_memlimit_interactive(void);

int    sodium_memcmp(const void *b1_, const void *b2_, size_t len);
void   randombytes_buf(void *buf, size_t size);
]]

-- Load libsodium tolerantly: some distros ship only a versioned .so.
local function load_lib(names)
  for _, n in ipairs(names) do
    local ok, lib = pcall(ffi.load, n)
    if ok then return lib end
  end
  error("could not load libsodium (tried: " .. table.concat(names, ", ") .. ")")
end

local sodium = load_lib({ "sodium", "libsodium.so.23", "libsodium.so.26", "libsodium" })

local _M = { _VERSION = "0.1.0" }

local HASHLEN = 32 -- BLAKE2b output we key the cache with

local initialized = false

-- Must be called once per worker before any other function.
function _M.init()
  if initialized then return true end
  -- sodium_init() returns 0 on success, 1 if already initialized, -1 on failure.
  if sodium.sodium_init() < 0 then
    return nil, "libsodium init failed"
  end
  initialized = true
  return true
end

local function to_hex(buf, len)
  local hex = ffi.new("char[?]", len * 2 + 1)
  local digits = "0123456789abcdef"
  local out = {}
  for i = 0, len - 1 do
    local b = buf[i]
    out[#out + 1] = digits:sub(math.floor(b / 16) + 1, math.floor(b / 16) + 1)
    out[#out + 1] = digits:sub((b % 16) + 1, (b % 16) + 1)
  end
  return table.concat(out)
end
_M.to_hex = to_hex

-- keyed_blake2b(server_key, message) -> lowercase hex digest (32 bytes).
-- server_key is the out-of-DB pepper; message is the presented PSK.
function _M.keyed_blake2b(server_key, message)
  if not initialized then return nil, "crypto not initialized" end
  if type(server_key) ~= "string" or #server_key == 0 then
    return nil, "server_key required"
  end
  local out = ffi.new("unsigned char[?]", HASHLEN)
  local rc = sodium.crypto_generichash(
    out, HASHLEN,
    message, #message,
    server_key, #server_key)
  if rc ~= 0 then return nil, "generichash failed" end
  return to_hex(out, HASHLEN)
end

-- pwhash_str(passwd) -> Argon2id encoded string for at-rest storage.
function _M.pwhash_str(passwd)
  if not initialized then return nil, "crypto not initialized" end
  local strbytes = tonumber(sodium.crypto_pwhash_strbytes())
  local out = ffi.new("char[?]", strbytes)
  local ops = sodium.crypto_pwhash_opslimit_interactive()
  local mem = sodium.crypto_pwhash_memlimit_interactive()
  local rc = sodium.crypto_pwhash_str(out, passwd, #passwd, ops, mem)
  if rc ~= 0 then return nil, "pwhash failed (out of memory?)" end
  return ffi.string(out)
end

-- pwhash_verify(encoded, passwd) -> boolean. Constant-time internally.
function _M.pwhash_verify(encoded, passwd)
  if not initialized then return false end
  if type(encoded) ~= "string" or #encoded == 0 then return false end
  return sodium.crypto_pwhash_str_verify(encoded, passwd, #passwd) == 0
end

-- memeq(a, b) -> boolean. Constant-time equality for equal-length secrets.
function _M.memeq(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if #a ~= #b then return false end
  if #a == 0 then return true end
  return sodium.sodium_memcmp(a, b, #a) == 0
end

-- random_hex(nbytes) -> hex string of cryptographically random bytes.
function _M.random_hex(nbytes)
  if not initialized then return nil, "crypto not initialized" end
  nbytes = nbytes or 32
  local buf = ffi.new("unsigned char[?]", nbytes)
  sodium.randombytes_buf(buf, nbytes)
  return to_hex(buf, nbytes)
end

return _M
