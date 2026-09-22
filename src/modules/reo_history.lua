-- reo_history.lua — the training record.
--
-- Every scenario the deck deals gets exactly one row in
-- <Scripts>/random_engine_out.history.csv, appended when the event resolves.
-- This is the file that answers "what have I actually practised, and am I
-- getting better at it?" — Log.txt is a debug dump, not a training record.
--
-- Deliberately separate from random_engine_out.state: deleting the deck to
-- reshuffle must never erase your history.
--
-- The column set is the full schema, including the grading columns that stay
-- empty until Phase 3 fills them. Writing them now means the header never has
-- to change, so a spreadsheet or script built against this file keeps working.
--
-- Known gap: if FlyWithLua reloads all scripts mid-flight with a card still
-- armed, the Lua state is destroyed before we can write an `expired` row. The
-- card itself is not lost — it is held over via the .state file — but that
-- flight leaves no row behind.

local M = {}

local reo, state, util

local SCHEMA_VERSION = 1
local MAX_ROWS = 5000 -- Keep load-time aggregation (Phase 4) cheap.

local COLUMNS = {
    "v", "ts_iso", "flight_id", "icao", "engines", "scenario", "bucket",
    "severity", "engine", "fired_at_min", "reaction_s", "correct_engine",
    "ias_target", "ias_min", "ias_in_band_pct", "max_bank", "max_slip",
    "alt_loss_ft", "hdg_dev", "ap_pct", "outcome", "grade", "notes",
}

local function history_path()
    return (SCRIPT_DIRECTORY or "") .. "random_engine_out.history.csv"
end

M.path = history_path

-- Which aircraft this was flown in. FlyWithLua hands us PLANE_ICAO directly, so
-- there is no need to decode sim/aircraft/view/acf_ICAO as a byte array. Some
-- third-party aircraft leave the ICAO blank, hence the filename fallback.
local function aircraft_id()
    local icao = PLANE_ICAO
    if type(icao) == "string" then
        icao = util.trim(icao)
        if icao ~= "" then return icao end
    end
    local file = AIRCRAFT_FILENAME
    if type(file) == "string" and file ~= "" then
        return (file:gsub("%.acf$", ""))
    end
    return "unknown"
end

local function row_count()
    local f = io.open(history_path(), "r")
    if not f then return nil end
    local n = 0
    for _ in f:lines() do n = n + 1 end
    f:close()
    return n
end

local function write_header()
    local f = io.open(history_path(), "w")
    if not f then
        logMsg("Random Engine Failure: WARNING could not create history file at " .. history_path())
        return false
    end
    f:write(table.concat(COLUMNS, ",") .. "\n")
    f:close()
    return true
end

-- Builds the record for a card as it is dealt. Resolution fields (outcome,
-- timings, grades) are filled in later by record().
function M.new_event(fields)
    local ev = {
        ts = util.now_ts(),
        -- Groups rows that belong to the same flight. Seconds are plenty: one
        -- card is dealt per flight.
        flight_id = tostring(os.time()),
        icao = aircraft_id(),
        engines = math.max(0, NUM_ENGINES or 0),
        scenario = "",
        bucket = "",
        severity = "",
    }
    if fields then
        for k, v in pairs(fields) do ev[k] = v end
    end
    return ev
end

-- Appends one row. `extra` may carry any column value (fired_at_min, notes, and
-- from Phase 3 the grading metrics). One open/append per event — never per
-- sample, and never from the per-frame path.
function M.record(ev, outcome, extra)
    if ev == nil then return end
    if ev.recorded then return end -- Never log the same card twice.
    ev.recorded = true

    local row = {
        v = SCHEMA_VERSION,
        ts_iso = ev.ts,
        flight_id = ev.flight_id,
        icao = ev.icao,
        engines = ev.engines,
        scenario = ev.scenario,
        bucket = ev.bucket,
        severity = ev.severity,
        -- Datarefs are 0-indexed; the logs and the GUI both count from 1, so the
        -- history matches what you actually saw.
        engine = ev.engine and (ev.engine + 1) or nil,
        outcome = outcome,
        grade = "unscored", -- Phase 3 replaces this with a real verdict.
    }
    if extra then
        for k, v in pairs(extra) do row[k] = v end
    end

    local f = io.open(history_path(), "a")
    if not f then
        logMsg("Random Engine Failure: WARNING could not append to history file at " .. history_path())
        return
    end
    local cells = {}
    for i = 1, #COLUMNS do
        cells[i] = util.csv_field(row[COLUMNS[i]])
    end
    f:write(table.concat(cells, ",") .. "\n")
    f:close()

    logMsg(string.format(
        "Random Engine Failure: history += %s/%s/%s outcome=%s (%s)",
        ev.icao, ev.bucket ~= "" and ev.bucket or "-",
        ev.severity ~= "" and ev.severity or "-", outcome, history_path()))
end

function M.init(context)
    reo = context
    state = context.state
    util = context.util

    local n = row_count()
    if n == nil then
        if write_header() then
            logMsg("Random Engine Failure: created training history at " .. history_path())
        end
    elseif n > MAX_ROWS then
        -- Rotation is a rare path (5000+ rows), so it must not be the thing that
        -- breaks loading if os.rename misbehaves on some platform. Failing to
        -- rotate is harmless: we simply keep appending to a long file.
        local old = history_path() .. ".old"
        local ok = pcall(function()
            os.remove(old)
            assert(os.rename(history_path(), old))
        end)
        if ok then
            write_header()
            logMsg(string.format(
                "Random Engine Failure: history had %d rows — rotated to %s and started fresh.",
                n, old))
        else
            logMsg(string.format(
                "Random Engine Failure: history has %d rows but could not be rotated — still appending.",
                n))
        end
    else
        logMsg(string.format("Random Engine Failure: training history has %d entries.",
            math.max(0, n - 1))) -- minus the header
    end

    return M
end

return M
