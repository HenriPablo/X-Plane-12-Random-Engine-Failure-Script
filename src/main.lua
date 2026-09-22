-- X-Plane 12 Random Engine Failure Script
-- For use with FlyWithLua
--
-- This file is the loader: config, datarefs, the flight clock, and the callback
-- shims FlyWithLua registers by name. The deck, the emergency catalog and the
-- GUI live in Modules/reo_*.lua — deploy them with the deploy script, or the
-- require() calls below will fail loudly.

-- =============================================================================
-- VERIFICATION SECTION (Simple check to see if script is running)
-- =============================================================================
logMsg("Random Engine Failure script loaded successfully!")

-- =============================================================================
-- CONFIGURATION / DEFAULTS
-- =============================================================================
-- These are defaults. They can be overridden per-flight by an optional config
-- file next to this script (see load_config below). X-Plane does not pass
-- command-line arguments to FlyWithLua, so a config file is the supported way
-- to control the script without editing it. An external launcher can write the
-- file before starting X-Plane (see tools/practice-launch.bat).
local DEFAULT_ENABLED = true            -- Master switch: run the failure logic at all
local DEFAULT_SESSION_MINUTES = 25      -- Nominal flying-time length of a practice session
local DEFAULT_CLEAN_FLIGHT_CHANCE = 0.35 -- Fraction of flights that get no failure at all
local DEFAULT_START_DELAY_MINUTES = 0   -- Guaranteed quiet minutes of flight before any failure
local DEFAULT_FAILURE_DEADLINE_MINUTES = 0 -- Backstop: fire by this point of flight (0 = no backstop)
local DEFAULT_REQUIRE_AIRBORNE = true   -- Only count time once the wheels leave the ground
local DEFAULT_MIN_REDUCTION = 0.3       -- Floor for the power reduction (fraction of throttle lost)
local DEFAULT_MAX_REDUCTION = 1.0       -- Ceiling for the power reduction (1.0 = driven to idle)
local DEFAULT_DEBUG_REVEAL = false      -- Show countdown / deck state in the GUI (spoils surprise)

-- Runtime config (populated by load_config)
local cfg = {
    enabled = DEFAULT_ENABLED,
    session_minutes = DEFAULT_SESSION_MINUTES,
    clean_flight_chance = DEFAULT_CLEAN_FLIGHT_CHANCE,
    start_delay_minutes = DEFAULT_START_DELAY_MINUTES,
    failure_deadline_minutes = DEFAULT_FAILURE_DEADLINE_MINUTES,
    require_airborne = DEFAULT_REQUIRE_AIRBORNE,
    min_reduction = DEFAULT_MIN_REDUCTION,
    max_reduction = DEFAULT_MAX_REDUCTION,
    debug_reveal = DEFAULT_DEBUG_REVEAL,
}

-- =============================================================================
-- SHARED STATE
-- =============================================================================
-- One table, so the modules and this file are demonstrably looking at the same
-- values rather than at copies that drift.
local state = {
    -- Failure status
    failure_triggered = false,
    target_engine = -1,
    reduction_amount = 0,
    clamp_logged = false,
    script_enabled = true,  -- Effective on/off (starts from cfg.enabled, toggleable in-sim)
    initialized = false,    -- Have we successfully armed after detecting engines?

    -- Stage 1: pause-aware, airborne-anchored flight clock
    flight_elapsed = 0,     -- Seconds of actual flying time since arming
    last_tick = 0,          -- Previous SIM_TIME sample, for delta accumulation
    airborne = false,       -- Latched true on first liftoff after arming
    liftoff_logged = false,

    -- Stage 2/3: what this flight drew from the deck
    armed = false,          -- A failure is scheduled for this flight
    clean_flight = false,   -- This flight's card was "clean" — nothing will happen
    card_bucket = "none",   -- clean | early | mid | late
    card_severity = "none", -- light | heavy | total
    target_elapsed = 0,     -- Flying seconds at which the failure fires
    event = nil,            -- The card currently in play (scenario id, engine, ...)

    -- Stage 3: persistent deck state (survives across flights/sessions)
    deck = {},              -- Remaining timing cards, consumed from the end
    severity_deck = {},     -- Remaining severity cards, consumed from the end
    last_bucket = "none",   -- Previous flight's timing bucket (anti-repeat)
    last_severity = "none",
    flights_flown = 0,

    -- A card that was armed but never fired (the flight ended first, or a "late"
    -- card was scheduled past the end of your actual airborne time). It is held
    -- here and re-armed on the next flight instead of being silently spent —
    -- otherwise the deck's stated rates are a lie and long sessions drift clean.
    pending_bucket = "none",
    pending_severity = "none",

    -- Per-flight reset. sim/time/total_flight_time_sec restarts at zero whenever
    -- a new flight is loaded, so a decrease is our "new flight" signal.
    last_flight_time = 0,
}

-- Seed the RNG so the failure pattern differs between sessions. The first few
-- draws after seeding correlate with the seed on some Lua builds, so burn them.
math.randomseed(os.time())
math.random(); math.random(); math.random()

-- =============================================================================
-- DATAREFS
-- =============================================================================
-- Bound here rather than in the modules: dataref() creates a global whichever
-- file calls it, so keeping them in one place makes the set obvious.
-- Number of engines on current aircraft
dataref("NUM_ENGINES", "sim/aircraft/engine/acf_num_engines", "readonly")
-- Total sim running time in seconds (monotonic source for our own clock)
dataref("SIM_TIME", "sim/time/total_running_time_sec", "readonly")
-- Sim pause state (1 = paused). Used so a coffee break does not burn the window.
dataref("SIM_PAUSED", "sim/time/paused", "readonly")
-- Ground contact (1 = any gear on the ground). Anchors the clock at liftoff.
dataref("ON_GROUND", "sim/flightmodel/failures/onground_any", "readonly")
-- Elapsed time of the current flight. Resets to zero on every new flight, which
-- is how we notice a reposition/reload and re-arm for the next one.
dataref("FLIGHT_TIME", "sim/time/total_flight_time_sec", "readonly")
-- Array of throttle settings (0.0 to 1.0) — actual engine throttle ratio (read-only)
THROTTLE_RATIO = dataref_table("sim/flightmodel/engine/ENGN_thro")
-- Writable throttle command when override is enabled
THROTTLE_RATIO_USE = dataref_table("sim/flightmodel/engine/ENGN_thro_use")
-- Pilot command (what your hardware/commands are asking for) per engine
COCKPIT_THROTTLE = dataref_table("sim/cockpit2/engine/actuators/throttle_ratio")
-- Override throttle control (1 = override active)
dataref("THROTTLE_OVERRIDE", "sim/operation/override/override_throttles", "writable")

-- =============================================================================
-- MODULES
-- =============================================================================
-- FlyWithLua puts MODULES_DIRECTORY on package.path (Internals/FlyWithLua.ini),
-- so these resolve to <FlyWithLua>/Modules/<name>.lua. A missing module means
-- the deploy step was skipped, which is worth saying plainly rather than dying
-- with a bare stack trace.
local modules_ok = true

local function need(name)
    local ok, mod = pcall(require, name)
    if not ok or type(mod) ~= "table" then
        modules_ok = false
        logMsg("Random Engine Failure: FATAL — could not load module '" .. name ..
            "'. Run the deploy script so Modules/" .. name ..
            ".lua is installed, then reload. (" .. tostring(mod) .. ")")
        return nil
    end
    return mod
end

local util = need("reo_util")
local deck_mod = need("reo_deck")
local scenarios = need("reo_scenarios")
local history = need("reo_history")
local gui = need("reo_gui")

-- Helper: format an engines throttle snapshot like [1: 0.73, 2: 0.70]
local function throttle_snapshot()
    local parts = {}
    local n = math.max(0, NUM_ENGINES or 0)
    for i = 0, n - 1 do
        parts[#parts + 1] = string.format("%d: %.2f", i + 1, THROTTLE_RATIO[i] or -1)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
end

-- The context every module shares. `actions` is filled in below, once the
-- functions it points at exist.
local reo = {
    cfg = cfg,
    state = state,
    util = util,
    deck = deck_mod,
    scenarios = scenarios,
    history = history,
    gui = gui,
    actions = {},
    throttle_snapshot = throttle_snapshot,
}

-- init() must run on every load, not just the first. require() caches modules in
-- package.loaded, so a cached module would otherwise keep pointing at the
-- previous load's state table while this file builds a fresh one. Re-binding on
-- init makes that harmless either way.
if modules_ok then
    deck_mod.init(reo)
    scenarios.init(reo)
    history.init(reo)
    gui.init(reo)
end

-- Convenience: the scenario in play (only one exists today).
local function current_scenario()
    return scenarios.get((state.event and state.event.scenario) or "engine_out")
end

-- =============================================================================
-- CONFIG FILE
-- =============================================================================

-- Reads an optional key=value config file (# comments allowed) placed next to
-- this script, e.g. <FlyWithLua>/Scripts/random_engine_out.cfg. Missing file or
-- keys simply fall back to the defaults above.
local function load_config()
    local dir = SCRIPT_DIRECTORY or ""
    local path = dir .. "random_engine_out.cfg"
    local f = io.open(path, "r")
    if not f then
        logMsg("Random Engine Failure: no config file at " .. path .. " — using defaults.")
        return
    end

    for raw in f:lines() do
        local line = util.trim(raw)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
            if k then
                k = string.lower(k)
                v = util.trim(v)
                if k == "enabled" then
                    cfg.enabled = util.parse_bool(v)
                elseif k == "session_minutes" then
                    cfg.session_minutes = tonumber(v) or cfg.session_minutes
                elseif k == "clean_flight_chance" then
                    cfg.clean_flight_chance = tonumber(v) or cfg.clean_flight_chance
                elseif k == "start_delay_minutes" then
                    cfg.start_delay_minutes = tonumber(v) or cfg.start_delay_minutes
                elseif k == "failure_deadline_minutes" then
                    cfg.failure_deadline_minutes = tonumber(v) or cfg.failure_deadline_minutes
                elseif k == "require_airborne" then
                    cfg.require_airborne = util.parse_bool(v)
                elseif k == "min_reduction" then
                    cfg.min_reduction = tonumber(v) or cfg.min_reduction
                elseif k == "max_reduction" then
                    cfg.max_reduction = tonumber(v) or cfg.max_reduction
                elseif k == "debug_reveal" then
                    cfg.debug_reveal = util.parse_bool(v)
                elseif k == "min_wait_minutes" or k == "max_wait_minutes" then
                    -- Retired in favour of session_minutes + timing buckets.
                    logMsg("Random Engine Failure: config key '" .. k ..
                        "' is no longer used — see session_minutes / start_delay_minutes.")
                end
            end
        end
    end
    f:close()

    -- Sanity-clamp anything the user (or a launcher) may have written.
    cfg.session_minutes = math.max(1, cfg.session_minutes)
    cfg.clean_flight_chance = util.clamp(cfg.clean_flight_chance, 0.0, 0.8)
    cfg.start_delay_minutes = math.max(0, cfg.start_delay_minutes)
    cfg.failure_deadline_minutes = math.max(0, cfg.failure_deadline_minutes)
    cfg.min_reduction = util.clamp(cfg.min_reduction, 0.0, 1.0)
    cfg.max_reduction = util.clamp(cfg.max_reduction, cfg.min_reduction, 1.0)

    logMsg(string.format(
        "Random Engine Failure: config loaded from %s | enabled=%s, session=%.0fmin, clean_chance=%.0f%%, start_delay=%.1fmin, deadline=%.1fmin, require_airborne=%s, reduction=%.0f-%.0f%%",
        path, tostring(cfg.enabled), cfg.session_minutes, cfg.clean_flight_chance * 100,
        cfg.start_delay_minutes, cfg.failure_deadline_minutes, tostring(cfg.require_airborne),
        cfg.min_reduction * 100, cfg.max_reduction * 100))
end

-- =============================================================================
-- CORE LOGIC
-- =============================================================================

-- Draws this flight's scenario card and arms accordingly. Assumes engines are
-- present (caller checks). Returns true once armed (or deliberately clean).
function setup_random_failure()
    if (NUM_ENGINES or 0) < 1 then
        logMsg("Random Engine Failure: No engines detected — cannot schedule yet.")
        return false
    end

    -- Reset the flight clock and any previous failure.
    state.failure_triggered = false
    THROTTLE_OVERRIDE = 0
    state.clamp_logged = false
    state.flight_elapsed = 0
    state.last_tick = SIM_TIME
    state.airborne = not cfg.require_airborne
    state.liftoff_logged = false
    state.armed = false
    state.clean_flight = false
    state.target_elapsed = 0
    state.card_severity = "none"
    state.event = nil

    -- Baseline log of current state
    logMsg(string.format("Random Engine Failure: [%s] Initialized. Engines: %d, Throttles: %s",
        util.now_ts(), NUM_ENGINES or -1, throttle_snapshot()))

    -- Stage 3: the card decides everything about this flight. A card that was
    -- armed but never fired is re-armed first; only if there is none do we deal
    -- a new one. The card's identity (bucket + severity) carries over, but the
    -- exact second and the target engine are re-rolled — so a missed card comes
    -- back without becoming something you can memorise.
    local resumed = false
    if state.pending_bucket ~= "none" and state.pending_severity ~= "none" then
        state.card_bucket = state.pending_bucket
        state.card_severity = state.pending_severity
        resumed = true
    else
        state.card_bucket = deck_mod.draw_timing_card()
    end
    state.flights_flown = state.flights_flown + 1

    -- Open the training record for this card. It gets exactly one row, written
    -- when the card resolves: clean here, fired in process_failure, or expired
    -- if the flight ends with it still armed.
    state.event = history.new_event({ bucket = state.card_bucket })

    if state.card_bucket == "clean" then
        state.clean_flight = true
        state.last_bucket = state.card_bucket
        state.pending_bucket = "none"
        state.pending_severity = "none"
        history.record(state.event, "clean")
        deck_mod.save_state()
        logMsg(string.format(
            "Random Engine Failure: [%s] Card drawn: CLEAN — no failure this flight (flight #%d, %d timing cards left).",
            util.now_ts(), state.flights_flown, #state.deck))
        return true
    end

    -- Severity comes from its own deck so the light/heavy/total mix stays even.
    if not resumed then
        state.card_severity = deck_mod.draw_severity_card()
    end

    -- The scenario picks the specifics: which engine, and exactly how much power
    -- it loses within the severity band.
    local scenario = scenarios.get("engine_out")
    state.event.scenario = scenario.id
    state.event.severity = state.card_severity
    scenario.arm(state.event)

    -- Timing: a random point inside the bucket's slice of the session, floored
    -- by start_delay_minutes so a launcher can still guarantee quiet time.
    local window = deck_mod.BUCKET_WINDOWS[state.card_bucket]
    local session_seconds = cfg.session_minutes * 60
    local fraction = window[1] + (math.random() * (window[2] - window[1]))
    state.target_elapsed = math.max(fraction * session_seconds, cfg.start_delay_minutes * 60)

    -- Backstop: a "late" card scheduled past the end of your real airborne time
    -- would never fire. Pull it back to the deadline — but never inside the
    -- guaranteed-quiet period, which wins if the two conflict.
    if cfg.failure_deadline_minutes > 0 then
        local deadline = math.max(cfg.failure_deadline_minutes * 60, cfg.start_delay_minutes * 60)
        if state.target_elapsed > deadline then
            state.target_elapsed = deadline
        end
    end
    state.armed = true
    state.event.target_elapsed = state.target_elapsed

    -- Hold the card until it actually fires (see process_failure).
    state.pending_bucket = state.card_bucket
    state.pending_severity = state.card_severity
    state.last_bucket = state.card_bucket
    state.last_severity = state.card_severity
    deck_mod.save_state()

    local max_allowed = 1.0 - state.reduction_amount
    logMsg(string.format(
        "Random Engine Failure: [%s] Card %s: %s/%s | engine=%d, fires at %.1f min of %s time, reduction=%.1f%%, max_allowed=%.2f | flight #%d, %d timing / %d severity cards left | snapshot=%s",
        util.now_ts(), resumed and "RE-ARMED (held over)" or "drawn",
        string.upper(state.card_bucket), string.upper(state.card_severity), state.target_engine + 1,
        state.target_elapsed / 60, cfg.require_airborne and "AIRBORNE" or "armed",
        state.reduction_amount * 100, max_allowed, state.flights_flown,
        #state.deck, #state.severity_deck, throttle_snapshot()))
    return true
end

-- Deferred/retrying initializer. X-Plane may load this script before the
-- aircraft is fully initialized, so we keep checking (cheaply) until engines
-- appear, then schedule exactly once. Runs from do_sometimes.
function try_initialize()
    if not state.script_enabled then return end
    if state.initialized then return end
    if (NUM_ENGINES or 0) < 1 then return end -- retry next tick

    if setup_random_failure() then
        state.initialized = true
    end
end

-- Stage 1: accumulate our own flight clock at 1 Hz. Only advances while the sim
-- is unpaused and (optionally) the aircraft is airborne, so taxi time, startup
-- and water breaks never eat into the window. Rolling our own counter also
-- means we do not care whether total_running_time_sec ticks during a pause.
function update_flight_clock()
    local now = SIM_TIME or 0
    local delta = now - state.last_tick
    state.last_tick = now

    -- A new flight (reposition, restart, or loading a saved situation) sends the
    -- sim's flight timer backwards. Re-arm, so flight two gets its own card
    -- rather than inheriting a clock that already ran past the target — and so a
    -- card that did not fire on flight one is held over rather than lost.
    local ft = FLIGHT_TIME or 0
    if ft < state.last_flight_time - 2 then
        state.last_flight_time = ft
        if state.script_enabled then
            logMsg(string.format(
                "Random Engine Failure: [%s] New flight detected — re-arming for the next one.",
                util.now_ts()))
            -- The flight ended with a card still armed. Record that it never got
            -- the chance to fire: a run of these means the deadline is set wrong
            -- for how long you actually stay airborne. The card itself is still
            -- held over in the .state file, so nothing is lost from the deck.
            if state.armed and not state.failure_triggered then
                history.record(state.event, "expired", {
                    notes = string.format("scheduled %.1f min; flight reached %.1f min",
                        state.target_elapsed / 60, state.flight_elapsed / 60),
                })
            end
            state.failure_triggered = false
            THROTTLE_OVERRIDE = 0
            state.initialized = false -- try_initialize re-arms on its next tick
        end
        return
    end
    state.last_flight_time = ft

    if not state.script_enabled or not state.initialized then return end
    if (SIM_PAUSED or 0) ~= 0 then return end

    -- Latch airborne on first liftoff; it stays true for the rest of the flight
    -- so touch-and-goes keep accumulating time across circuits.
    if not state.airborne and (ON_GROUND or 1) == 0 then
        state.airborne = true
        if not state.liftoff_logged then
            state.liftoff_logged = true
            logMsg(string.format("Random Engine Failure: [%s] Airborne — flight clock started.",
                util.now_ts()))
        end
    end

    if not state.airborne then return end
    -- Guard against sim-time jumps (flight reload, teleport, time acceleration).
    if delta > 0 and delta < 5 then
        state.flight_elapsed = state.flight_elapsed + delta
    end
end

function process_failure()
    -- Deferred window teardown (see the Hide Window button). Cheap flag check,
    -- and it must run even when the script is disabled.
    gui.housekeeping()

    if not state.script_enabled then return end

    -- Only run if armed, not already triggered, and the clock has caught up.
    if state.armed and not state.failure_triggered then
        if state.flight_elapsed >= state.target_elapsed then
            state.failure_triggered = true
            current_scenario().fire(state.event)
            -- The card has now been played, so it is no longer held over.
            state.pending_bucket = "none"
            state.pending_severity = "none"
            history.record(state.event, "fired", {
                fired_at_min = string.format("%.1f", state.flight_elapsed / 60),
            })
            deck_mod.save_state()
            local max_allowed = 1.0 - state.reduction_amount
            local curr = THROTTLE_RATIO[state.target_engine] or -1
            logMsg(string.format("Random Engine Failure: [%s] FAILURE TRIGGERED on engine %d after %.1f min of flight | card=%s/%s | reduction=%.1f%% | max_allowed=%.2f | curr_throttle=%.2f | snapshot=%s | override=1",
                util.now_ts(), state.target_engine + 1, state.flight_elapsed / 60,
                state.card_bucket, state.card_severity,
                state.reduction_amount * 100, max_allowed, curr, throttle_snapshot()))
        end
    end

    -- If failure is active, let the scenario hold it there.
    if state.failure_triggered then
        local scenario = current_scenario()
        if scenario.enforce then scenario.enforce(state.event) end
    end
end

-- =============================================================================
-- ACTIONS (what the GUI buttons do)
-- =============================================================================

-- Turns the failure logic off and releases any active override.
local function disable_script()
    state.script_enabled = false
    state.failure_triggered = false
    state.armed = false
    current_scenario().clear(state.event)
    logMsg("Random Engine Failure: disabled (normal flight — no failure will occur).")
end

-- Turns the logic back on and forces a fresh draw on the next tick.
local function enable_script()
    state.script_enabled = true
    state.initialized = false
    logMsg("Random Engine Failure: enabled — will draw a scenario card once engines are detected.")
end

reo.actions.disable = disable_script
reo.actions.enable = enable_script

reo.actions.draw_new = function()
    deck_mod.return_pending_to_deck()
    enable_script()
    setup_random_failure()
    state.initialized = true
end

reo.actions.clear = function()
    state.failure_triggered = false
    current_scenario().clear(state.event)
    setup_random_failure()
    state.initialized = true
end

-- =============================================================================
-- GLOBAL SHIMS
-- =============================================================================
-- FlyWithLua resolves callbacks from strings against globals, so these names
-- must exist in _G even though the implementations live in modules.

-- Nil-guarded: the macro below is registered before we know whether the modules
-- loaded, so clicking it with a broken install should log, not throw.

function engine_failure_gui(wnd, x, y)
    if gui then gui.build(wnd, x, y) end
end

function open_settings_window()
    if gui then gui.open() end
end

function close_settings_window()
    if gui then gui.close() end
end

function on_settings_window_closed(wnd)
    if gui then gui.on_closed(wnd) end
end

-- Draw status on screen if debugging or desired
function draw_failure_status()
    if state.failure_triggered then
        draw_string(20, 40, "ENGINE FAILURE ACTIVE: ENGINE " .. (state.target_engine + 1), "red")
    end
end

-- Menu entry to bring the window back after hiding it.
add_macro("Random Engine Failure Settings", "open_settings_window()", "close_settings_window()", "activate")

-- =============================================================================
-- FLYWITHLUA HOOKS
-- =============================================================================

if not modules_ok then
    logMsg("Random Engine Failure: modules missing — logic NOT registered, normal flight only.")
    return
end

-- Load config and persistent deck state, then set the effective enable state.
load_config()
deck_mod.load_state()
state.script_enabled = cfg.enabled
if not state.script_enabled then
    logMsg("Random Engine Failure: disabled by config (enabled=false) — normal flight.")
end

-- Deferred init: keep checking for engines until we can draw a card (retries).
do_sometimes("try_initialize()")

-- Flight clock: once per second is plenty and keeps the per-frame path cheap.
do_often("update_flight_clock()")

-- Every frame loop
do_every_frame("process_failure()")

do_every_draw("draw_failure_status()")

-- Open the settings window on load, so there is always a visible indication of
-- whether the script is armed. Hide it from the FlyWithLua macro menu.
open_settings_window()
