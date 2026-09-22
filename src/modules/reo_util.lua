-- reo_util.lua — small shared helpers for the Random Engine Failure script.
--
-- Installed to <X-Plane>/Resources/plugins/FlyWithLua/Modules/reo_util.lua and
-- loaded with require("reo_util"). FlyWithLua puts MODULES_DIRECTORY on
-- package.path (see Internals/FlyWithLua.ini), so the plain name resolves.
--
-- Lua 5.1 / LuaJIT only. Returns a table rather than using the deprecated
-- module(..., package.seeall) idiom, which leaks its contents into _G.

local M = {}

function M.trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function M.parse_bool(v)
    v = string.lower(M.trim(v))
    return (v == "true" or v == "1" or v == "yes" or v == "on")
end

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Common timestamp string for log lines.
function M.now_ts()
    return os.date("%Y-%m-%d %H:%M:%S")
end

return M
