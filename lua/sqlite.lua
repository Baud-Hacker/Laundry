-- sqlite.lua — minimal, self-contained libsqlite3 binding via LuaJIT FFI.
--
-- Deliberately tiny: open/close, exec (no results), and query (read rows as a
-- Lua array of maps). Values are bound as text/int; that covers the whole
-- laundry schema and keeps us free of any external Lua SQLite package.

local ffi = require "ffi"

ffi.cdef [[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

int sqlite3_open(const char *filename, sqlite3 **ppDb);
int sqlite3_close_v2(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3 *db);
int sqlite3_busy_timeout(sqlite3 *db, int ms);

int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                       sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *stmt);
int sqlite3_finalize(sqlite3_stmt *stmt);
int sqlite3_reset(sqlite3_stmt *stmt);

int sqlite3_bind_text(sqlite3_stmt *stmt, int i, const char *txt, int n, void(*)(void*));
int sqlite3_bind_int64(sqlite3_stmt *stmt, int i, int64_t v);
int sqlite3_bind_null(sqlite3_stmt *stmt, int i);

int sqlite3_column_count(sqlite3_stmt *stmt);
const char *sqlite3_column_name(sqlite3_stmt *stmt, int i);
int sqlite3_column_type(sqlite3_stmt *stmt, int i);
const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int i);
int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int i);
]]

-- Load libsqlite3 tolerantly: some distros ship only a versioned .so.
local function load_lib(names)
  for _, n in ipairs(names) do
    local ok, lib = pcall(ffi.load, n)
    if ok then return lib end
  end
  error("could not load libsqlite3 (tried: " .. table.concat(names, ", ") .. ")")
end

local C = load_lib({ "sqlite3", "libsqlite3.so.0", "libsqlite3" })

-- Result / status codes we care about.
local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101
local SQLITE_NULL = 5

-- SQLITE_TRANSIENT tells sqlite to copy bound text (safe with Lua GC).
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)

local Conn = {}
Conn.__index = Conn

local _M = { _VERSION = "0.1.0" }

-- Sentinel to bind an explicit SQL NULL (Lua nil can't sit in an array).
_M.NULL = setmetatable({}, { __tostring = function() return "NULL" end })

-- open(path) -> conn, err
function _M.open(path)
  local pdb = ffi.new("sqlite3*[1]")
  if C.sqlite3_open(path, pdb) ~= SQLITE_OK then
    local msg = pdb[0] ~= nil and ffi.string(C.sqlite3_errmsg(pdb[0])) or "open failed"
    if pdb[0] ~= nil then C.sqlite3_close_v2(pdb[0]) end
    return nil, msg
  end
  C.sqlite3_busy_timeout(pdb[0], 3000)
  return setmetatable({ db = pdb[0], closed = false }, Conn)
end

function Conn:_err(prefix)
  return (prefix or "sqlite") .. ": " .. ffi.string(C.sqlite3_errmsg(self.db))
end

local function bind_params(self, stmt, params)
  local n = params and #params or 0
  for i = 1, n do
    local v = params[i]
    local rc
    if v == _M.NULL or v == nil then
      rc = C.sqlite3_bind_null(stmt, i)
    elseif type(v) == "number" then
      rc = C.sqlite3_bind_int64(stmt, i, v)
    else
      v = tostring(v)
      rc = C.sqlite3_bind_text(stmt, i, v, #v, SQLITE_TRANSIENT)
    end
    if rc ~= SQLITE_OK then return self:_err("bind") end
  end
end

-- query(sql, params) -> rows (array of {colname=value}), err
function Conn:query(sql, params)
  local pstmt = ffi.new("sqlite3_stmt*[1]")
  if C.sqlite3_prepare_v2(self.db, sql, #sql, pstmt, nil) ~= SQLITE_OK then
    return nil, self:_err("prepare")
  end
  local stmt = pstmt[0]
  local berr = bind_params(self, stmt, params)
  if berr then C.sqlite3_finalize(stmt); return nil, berr end

  local ncol = C.sqlite3_column_count(stmt)
  local names = {}
  for i = 0, ncol - 1 do
    names[i] = ffi.string(C.sqlite3_column_name(stmt, i))
  end

  local rows = {}
  while true do
    local rc = C.sqlite3_step(stmt)
    if rc == SQLITE_ROW then
      local row = {}
      for i = 0, ncol - 1 do
        if C.sqlite3_column_type(stmt, i) == SQLITE_NULL then
          row[names[i]] = nil
        else
          local txt = C.sqlite3_column_text(stmt, i)
          row[names[i]] = txt ~= nil and ffi.string(txt) or nil
        end
      end
      rows[#rows + 1] = row
    elseif rc == SQLITE_DONE then
      break
    else
      local err = self:_err("step")
      C.sqlite3_finalize(stmt)
      return nil, err
    end
  end
  C.sqlite3_finalize(stmt)
  return rows
end

-- exec(sql, params) -> true, err   (for writes / DDL; ignores any result rows)
function Conn:exec(sql, params)
  local pstmt = ffi.new("sqlite3_stmt*[1]")
  local tail = ffi.new("const char*[1]")
  local ptr = sql
  -- Support multiple statements separated by ';' (used for schema.sql).
  while ptr ~= nil and ffi.string(ptr) ~= "" do
    if C.sqlite3_prepare_v2(self.db, ptr, -1, pstmt, tail) ~= SQLITE_OK then
      return nil, self:_err("prepare")
    end
    local stmt = pstmt[0]
    if stmt == nil then break end -- trailing whitespace / comment only
    local berr = bind_params(self, stmt, params)
    if berr then C.sqlite3_finalize(stmt); return nil, berr end
    local rc = C.sqlite3_step(stmt)
    if rc ~= SQLITE_DONE and rc ~= SQLITE_ROW then
      local err = self:_err("step")
      C.sqlite3_finalize(stmt)
      return nil, err
    end
    C.sqlite3_finalize(stmt)
    ptr = tail[0]
  end
  return true
end

function Conn:close()
  if not self.closed and self.db ~= nil then
    C.sqlite3_close_v2(self.db)
    self.closed = true
  end
end

return _M
