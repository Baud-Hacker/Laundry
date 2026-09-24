-- routing.lua — turn a validated credential into an internal redirect target.
--
-- Two kinds, chosen per credential in the DB:
--   upstream : proxy to an arbitrary URL. We stash it in $hidden_upstream and
--              hand control to the @hidden_upstream location (variable proxy_pass).
--   internal : serve local content. `target` names a location configured as
--              @hidden_<target> in site.conf (its own root / app).

local _M = {}

-- Extract host[:port] from a URL, for the upstream Host header / SNI.
local function url_host(u)
  return (u:gsub("^%a+://", "")):match("^([^/]+)")
end

-- apply(cred) -> location_name, err
function _M.apply(cred)
  local kind, target = cred.route_kind, cred.route_target
  if not kind then
    return nil, "credential has no route bound"
  end

  if kind == "upstream" then
    if not target or target == "" then return nil, "empty upstream target" end
    ngx.var.hidden_upstream = target
    ngx.var.hidden_host = url_host(target) or ""
    return "@hidden_upstream"
  elseif kind == "internal" then
    if not target or target == "" then return nil, "empty internal target" end
    -- Only allow a simple name so a bad DB row can't redirect somewhere odd.
    if not target:match("^[%w_%-]+$") then
      return nil, "invalid internal target: " .. tostring(target)
    end
    -- Redirect into a dedicated, more-specific prefix location (/__laundry_<name>/).
    -- Because it out-ranks `location /`, any index/try_files internal redirect
    -- stays inside it and never re-runs the access phase.
    return "/__laundry_" .. target .. ngx.var.uri
  end

  return nil, "unknown route kind: " .. tostring(kind)
end

return _M
