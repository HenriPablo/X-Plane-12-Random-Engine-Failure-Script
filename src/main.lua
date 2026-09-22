-- X-Plane 12 Random Engine Failure Script
-- For use with FlyWithLua

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

-- GUI State. FlyWithLua NG+ builds ImGui windows via float_wnd_create rather
-- than a do_on_imgui callback (which does not exist in any FlyWithLua build),
-- so we hold a window handle and let the builder draw into it.
local settings_wnd = nil
local want_close_window = false -- Destroying a window inside its own builder is
                                -- unsafe, so the close button sets this flag and
                                -- a later callback does the destroying.

-- Internal state
local failure_triggered = false
local target_engine = -1
local reduction_amount = 0
local script_enabled = true   -- Effective on/off (starts from cfg.enabled, toggleable in-sim)
local initialized = false     -- Have we successfully armed after detecting engines?
local clamp_logged = false

-- Stage 1: pause-aware, airborne-anchored flight clock
local flight_elapsed = 0      -- Seconds of actual flying time since arming
local last_tick = 0           -- Previous SIM_TIME sample, for delta accumulation
local airborne = false        -- Latched true on first liftoff after arming
local liftoff_logged = false

-- Stage 2/3: what this flight drew from the deck
local armed = false           -- A failure is scheduled for this flight
local clean_flight = false    -- This flight's card was "clean" — nothing will happen
local card_bucket = "none"    -- clean | early | mid | late
local card_severity = "none"  -- light | heavy | total
local target_elapsed = 0      -- Flying seconds at which the failure fires

-- Stage 3: persistent deck state (survives across flights/sessions)
local deck = {}               -- Remaining timing cards, consumed from the end
local severity_deck = {}       -- Remaining severity cards, consumed from the end
local last_bucket = "none"    -- Previous flight's timing bucket (anti-repeat)
local last_severity = "none"
local flights_flown = 0

-- A card that was armed but never fired (the flight ended first, or a "late"
-- card was scheduled past the end of your actual airborne time). It is held
-- here and re-armed on the next flight instead of being silently spent —
-- otherwise the deck's stated rates are a lie and long sessions drift clean.
local pending_bucket = "none"
local pending_severity = "none"

-- Per-flight reset. sim/time/total_flight_time_sec restarts at zero whenever a
-- new flight is loaded, so a decrease is our "new flight" signal.
local last_flight_time = 0

-- Seed the RNG so the failure pattern differs between sessions. The first few
-- draws after seeding correlate with the seed on some Lua builds, so burn them.
math.randomseed(os.time())
math.random(); math.random(); math.random()

-- =============================================================================
-- DATAREFS
-- =============================================================================
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
-- SCENARIO DEFINITIONS
-- =============================================================================
-- Timing buckets, expressed as a fraction of session_minutes of *flying* time.
-- "clean" is handled separately: it has no window because nothing fires.
local BUCKET_WINDOWS = {
    early = { 0.05, 0.25 }, -- climb-out / departure
    mid   = { 0.25, 0.65 }, -- cruise / practice area
    late  = { 0.65, 1.00 }, -- descent / pattern
}
local BUCKET_ORDER = { "early", "mid", "late" }

-- Severity bands as absolute throttle-loss fractions. Each is clamped to the
-- configured [min_reduction, max_reduction] range so the config still governs.
local SEVERITY_BANDS = {
    light = { 0.30, 0.55 }, -- noticeable partial loss, still climbing/level-able
    heavy = { 0.55, 0.85 }, -- serious partial loss, descent inevitable
    total = { 1.00, 1.00 }, -- driven to idle
}
local SEVERITY_ORDER = { "light", "heavy", "total" }

local CARDS_PER_BUCKET = 2 -- 2 each of early/mid/late = 6 failure cards per deck

local function is_valid_bucket(name)
    return name == "clean" or BUCKET_WINDOWS[name] ~= nil
end

local function is_valid_severity(name)
    return SEVERITY_BANDS[name] ~= nil
end

-- =============================================================================
-- CONFIG FILE
-- =============================================================================

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function parse_bool(v)
    v = string.lower(trim(v))
    return (v == "true" or v == "1" or v == "yes" or v == "on")
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

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

    for line in f:lines() do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
            if k then
                k = string.lower(k)
                v = trim(v)
                if k == "enabled" then
                    cfg.enabled = parse_bool(v)
                elseif k == "session_minutes" then
                    cfg.session_minutes = tonumber(v) or cfg.session_minutes
                elseif k == "clean_flight_chance" then
                    cfg.clean_flight_chance = tonumber(v) or cfg.clean_flight_chance
                elseif k == "start_delay_minutes" then
                    cfg.start_delay_minutes = tonumber(v) or cfg.start_delay_minutes
                elseif k == "failure_deadline_minutes" then
                    cfg.failure_deadline_minutes = tonumber(v) or cfg.failure_deadline_minutes
                elseif k == "require_airborne" then
                    cfg.require_airborne = parse_bool(v)
                elseif k == "min_reduction" then
                    cfg.min_reduction = tonumber(v) or cfg.min_reduction
                elseif k == "max_reduction" then
                    cfg.max_reduction = tonumber(v) or cfg.max_reduction
                elseif k == "debug_reveal" then
                    cfg.debug_reveal = parse_bool(v)
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
    cfg.clean_flight_chance = clamp(cfg.clean_flight_chance, 0.0, 0.8)
    cfg.start_delay_minutes = math.max(0, cfg.start_delay_minutes)
    cfg.failure_deadline_minutes = math.max(0, cfg.failure_deadline_minutes)
    cfg.min_reduction = clamp(cfg.min_reduction, 0.0, 1.0)
    cfg.max_reduction = clamp(cfg.max_reduction, cfg.min_reduction, 1.0)

    logMsg(string.format(
        "Random Engine Failure: config loaded from %s | enabled=%s, session=%.0fmin, clean_chance=%.0f%%, start_delay=%.1fmin, deadline=%.1fmin, require_airborne=%s, reduction=%.0f-%.0f%%",
        path, tostring(cfg.enabled), cfg.session_minutes, cfg.clean_flight_chance * 100,
        cfg.start_delay_minutes, cfg.failure_deadline_minutes, tostring(cfg.require_airborne),
        cfg.min_reduction * 100, cfg.max_reduction * 100))
end

-- =============================================================================
-- PERSISTENT STATE (the "learning" memory)
-- =============================================================================
-- The deck lives in a small key=value file next to the config. Because the
-- remaining cards are written back after every draw, a failure that has already
-- been used cannot come back until the whole deck recycles. That is what makes
-- "we lost it 20 seconds in, so the next one is late or not at all" true rather
-- than merely likely.

local function state_path()
    return (SCRIPT_DIRECTORY or "") .. "random_engine_out.state"
end

-- Splits "a,b,c" into a list, discarding tokens that fail the validator.
local function parse_card_list(v, validator)
    local out = {}
    for token in string.gmatch(v, "[^,]+") do
        token = string.lower(trim(token))
        if validator(token) then
            out[#out + 1] = token
        end
    end
    return out
end

local function load_state()
    local f = io.open(state_path(), "r")
    if not f then
        logMsg("Random Engine Failure: no saved deck state — starting a fresh deck.")
        return
    end

    for line in f:lines() do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
            if k then
                k = string.lower(k)
                v = trim(v)
                if k == "deck" then
                    deck = parse_card_list(v, is_valid_bucket)
                elseif k == "severity_deck" then
                    severity_deck = parse_card_list(v, is_valid_severity)
                elseif k == "last_bucket" then
                    if is_valid_bucket(v) then last_bucket = v end
                elseif k == "last_severity" then
                    if is_valid_severity(v) then last_severity = v end
                elseif k == "pending_bucket" then
                    if BUCKET_WINDOWS[v] ~= nil then pending_bucket = v end
                elseif k == "pending_severity" then
                    if is_valid_severity(v) then pending_severity = v end
                elseif k == "flights" then
                    flights_flown = tonumber(v) or 0
                end
            end
        end
    end
    f:close()

    logMsg(string.format(
        "Random Engine Failure: deck state loaded | flights=%d, timing_cards_left=%d, severity_cards_left=%d, last=%s/%s, pending=%s/%s",
        flights_flown, #deck, #severity_deck, last_bucket, last_severity,
        pending_bucket, pending_severity))
end

local function save_state()
    local path = state_path()
    local f = io.open(path, "w")
    if not f then
        logMsg("Random Engine Failure: WARNING could not write deck state to " .. path)
        return
    end
    f:write("# Random Engine Failure — auto-generated deck state. Delete to reset.\n")
    f:write("# 'deck' is consumed from the END of the list.\n")
    f:write("deck = " .. table.concat(deck, ",") .. "\n")
    f:write("severity_deck = " .. table.concat(severity_deck, ",") .. "\n")
    f:write("last_bucket = " .. last_bucket .. "\n")
    f:write("last_severity = " .. last_severity .. "\n")
    f:write("# A card armed but not yet fired. Re-armed next flight, not spent.\n")
    f:write("pending_bucket = " .. pending_bucket .. "\n")
    f:write("pending_severity = " .. pending_severity .. "\n")
    f:write("flights = " .. tostring(flights_flown) .. "\n")
    f:close()
end

-- =============================================================================
-- DECK LOGIC
-- =============================================================================

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

-- Arranges a shuffled deck so no two consecutive cards share a bucket, also
-- honouring the card we flew last. Back-to-back "early" is precisely what made
-- the old script predictable, and a plain shuffle still produces it ~15% of the
-- time. `free_card` (if given) is exempt: clean flights are allowed to repeat,
-- because forbidding that would force clean and failure flights to alternate —
-- its own, worse, kind of predictable.
--
-- Shuffling first and then taking the first admissible card keeps the ordering
-- random rather than patterned. If a repeat is unavoidable (possible only with
-- extreme deck compositions) we take what is left instead of looping forever.
local function arrange_no_adjacent(cards, previous, free_card)
    local pool = {}
    for _, c in ipairs(cards) do pool[#pool + 1] = c end
    shuffle(pool)

    local ordered = {}
    local prev = previous
    while #pool > 0 do
        local pick
        for i = 1, #pool do
            if pool[i] == free_card or pool[i] ~= prev then
                pick = i
                break
            end
        end
        pick = pick or 1
        prev = pool[pick]
        ordered[#ordered + 1] = prev
        table.remove(pool, pick)
    end

    -- ordered[1] should be played first, but the deck is consumed from the end.
    local reversed = {}
    for i = #ordered, 1, -1 do reversed[#reversed + 1] = ordered[i] end
    return reversed
end

-- Builds a fresh timing deck: CARDS_PER_BUCKET of each failure bucket, plus
-- however many "clean" cards are needed to hit clean_flight_chance. Solving
-- clean / (clean + failures) = chance gives clean = failures * c / (1 - c).
local function build_deck()
    local fresh = {}
    for _, bucket in ipairs(BUCKET_ORDER) do
        for _ = 1, CARDS_PER_BUCKET do
            fresh[#fresh + 1] = bucket
        end
    end

    local failure_cards = #fresh
    local c = cfg.clean_flight_chance
    local clean_cards = 0
    if c > 0 then
        clean_cards = math.floor((failure_cards * c / (1 - c)) + 0.5)
        clean_cards = clamp(clean_cards, 0, 18)
    end
    for _ = 1, clean_cards do
        fresh[#fresh + 1] = "clean"
    end

    local arranged = arrange_no_adjacent(fresh, last_bucket, "clean")
    logMsg(string.format(
        "Random Engine Failure: new timing deck shuffled | %d cards (%d failure, %d clean = %.0f%% clean)",
        #arranged, failure_cards, clean_cards, (clean_cards / #arranged) * 100))
    return arranged
end

local function build_severity_deck()
    local fresh = {}
    for _, sev in ipairs(SEVERITY_ORDER) do
        for _ = 1, CARDS_PER_BUCKET do
            fresh[#fresh + 1] = sev
        end
    end
    local arranged = arrange_no_adjacent(fresh, last_severity, nil)
    logMsg(string.format("Random Engine Failure: new severity deck shuffled | %d cards.", #arranged))
    return arranged
end

local function draw_timing_card()
    if #deck == 0 then deck = build_deck() end
    return table.remove(deck)
end

local function draw_severity_card()
    if #severity_deck == 0 then severity_deck = build_severity_deck() end
    return table.remove(severity_deck)
end

-- Puts a held-over card back into the decks so an explicit manual reroll does
-- not quietly destroy it. Inserted at the front (decks are consumed from the
-- end) so it resurfaces later in the rotation rather than immediately.
local function return_pending_to_deck()
    if pending_bucket == "none" then return end
    table.insert(deck, 1, pending_bucket)
    if pending_severity ~= "none" then
        table.insert(severity_deck, 1, pending_severity)
    end
    logMsg(string.format(
        "Random Engine Failure: held-over card %s/%s returned to the deck.",
        pending_bucket, pending_severity))
    pending_bucket = "none"
    pending_severity = "none"
end

-- =============================================================================
-- CORE LOGIC
-- =============================================================================

-- Helper: format an engines throttle snapshot like [1: 0.73, 2: 0.70]
local function throttle_snapshot()
    local parts = {}
    local n = math.max(0, NUM_ENGINES or 0)
    for i = 0, n - 1 do
        parts[#parts + 1] = string.format("%d: %.2f", i + 1, THROTTLE_RATIO[i] or -1)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
end

-- Helper: common timestamp string
local function now_ts()
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- Draws this flight's scenario card and arms accordingly. Assumes engines are
-- present (caller checks). Returns true once armed (or deliberately clean).
function setup_random_failure()
    if (NUM_ENGINES or 0) < 1 then
        logMsg("Random Engine Failure: No engines detected — cannot schedule yet.")
        return false
    end

    -- Reset the flight clock and any previous failure.
    failure_triggered = false
    THROTTLE_OVERRIDE = 0
    clamp_logged = false
    flight_elapsed = 0
    last_tick = SIM_TIME
    airborne = not cfg.require_airborne
    liftoff_logged = false
    armed = false
    clean_flight = false
    target_elapsed = 0
    card_severity = "none"

    -- Baseline log of current state
    logMsg(string.format("Random Engine Failure: [%s] Initialized. Engines: %d, Throttles: %s",
        now_ts(), NUM_ENGINES or -1, throttle_snapshot()))

    -- Stage 3: the card decides everything about this flight. A card that was
    -- armed but never fired is re-armed first; only if there is none do we deal
    -- a new one. The card's identity (bucket + severity) carries over, but the
    -- exact second and the target engine are re-rolled — so a missed card comes
    -- back without becoming something you can memorise.
    local resumed = false
    if pending_bucket ~= "none" and pending_severity ~= "none" then
        card_bucket = pending_bucket
        card_severity = pending_severity
        resumed = true
    else
        card_bucket = draw_timing_card()
    end
    flights_flown = flights_flown + 1

    if card_bucket == "clean" then
        clean_flight = true
        last_bucket = card_bucket
        pending_bucket = "none"
        pending_severity = "none"
        save_state()
        logMsg(string.format(
            "Random Engine Failure: [%s] Card drawn: CLEAN — no failure this flight (flight #%d, %d timing cards left).",
            now_ts(), flights_flown, #deck))
        return true
    end

    -- Pick a random engine (0-indexed in dataref array)
    target_engine = math.random(0, NUM_ENGINES - 1)

    -- Severity comes from its own deck so the light/heavy/total mix stays even.
    if not resumed then
        card_severity = draw_severity_card()
    end
    local band = SEVERITY_BANDS[card_severity]
    local band_lo = clamp(band[1], cfg.min_reduction, cfg.max_reduction)
    local band_hi = clamp(band[2], cfg.min_reduction, cfg.max_reduction)
    reduction_amount = band_lo + (math.random() * (band_hi - band_lo))

    -- Timing: a random point inside the bucket's slice of the session, floored
    -- by start_delay_minutes so a launcher can still guarantee quiet time.
    local window = BUCKET_WINDOWS[card_bucket]
    local session_seconds = cfg.session_minutes * 60
    local fraction = window[1] + (math.random() * (window[2] - window[1]))
    target_elapsed = math.max(fraction * session_seconds, cfg.start_delay_minutes * 60)

    -- Backstop: a "late" card scheduled past the end of your real airborne time
    -- would never fire. Pull it back to the deadline — but never inside the
    -- guaranteed-quiet period, which wins if the two conflict.
    if cfg.failure_deadline_minutes > 0 then
        local deadline = math.max(cfg.failure_deadline_minutes * 60, cfg.start_delay_minutes * 60)
        if target_elapsed > deadline then
            target_elapsed = deadline
        end
    end
    armed = true

    -- Hold the card until it actually fires (see process_failure).
    pending_bucket = card_bucket
    pending_severity = card_severity
    last_bucket = card_bucket
    last_severity = card_severity
    save_state()

    local max_allowed = 1.0 - reduction_amount
    logMsg(string.format(
        "Random Engine Failure: [%s] Card %s: %s/%s | engine=%d, fires at %.1f min of %s time, reduction=%.1f%%, max_allowed=%.2f | flight #%d, %d timing / %d severity cards left | snapshot=%s",
        now_ts(), resumed and "RE-ARMED (held over)" or "drawn",
        string.upper(card_bucket), string.upper(card_severity), target_engine + 1,
        target_elapsed / 60, cfg.require_airborne and "AIRBORNE" or "armed",
        reduction_amount * 100, max_allowed, flights_flown, #deck, #severity_deck,
        throttle_snapshot()))
    return true
end

-- Deferred/retrying initializer. X-Plane may load this script before the
-- aircraft is fully initialized, so we keep checking (cheaply) until engines
-- appear, then schedule exactly once. Runs from do_sometimes.
function try_initialize()
    if not script_enabled then return end
    if initialized then return end
    if (NUM_ENGINES or 0) < 1 then return end -- retry next tick

    if setup_random_failure() then
        initialized = true
    end
end

-- Stage 1: accumulate our own flight clock at 1 Hz. Only advances while the sim
-- is unpaused and (optionally) the aircraft is airborne, so taxi time, startup
-- and water breaks never eat into the window. Rolling our own counter also
-- means we do not care whether total_running_time_sec ticks during a pause.
function update_flight_clock()
    local now = SIM_TIME or 0
    local delta = now - last_tick
    last_tick = now

    -- A new flight (reposition, restart, or loading a saved situation) sends the
    -- sim's flight timer backwards. Re-arm, so flight two gets its own card
    -- rather than inheriting a clock that already ran past the target — and so a
    -- card that did not fire on flight one is held over rather than lost.
    local ft = FLIGHT_TIME or 0
    if ft < last_flight_time - 2 then
        last_flight_time = ft
        if script_enabled then
            logMsg(string.format(
                "Random Engine Failure: [%s] New flight detected — re-arming for the next one.",
                now_ts()))
            failure_triggered = false
            THROTTLE_OVERRIDE = 0
            initialized = false -- try_initialize re-arms on its next tick
        end
        return
    end
    last_flight_time = ft

    if not script_enabled or not initialized then return end
    if (SIM_PAUSED or 0) ~= 0 then return end

    -- Latch airborne on first liftoff; it stays true for the rest of the flight
    -- so touch-and-goes keep accumulating time across circuits.
    if not airborne and (ON_GROUND or 1) == 0 then
        airborne = true
        if not liftoff_logged then
            liftoff_logged = true
            logMsg(string.format("Random Engine Failure: [%s] Airborne — flight clock started.", now_ts()))
        end
    end

    if not airborne then return end
    -- Guard against sim-time jumps (flight reload, teleport, time acceleration).
    if delta > 0 and delta < 5 then
        flight_elapsed = flight_elapsed + delta
    end
end

function process_failure()
    -- Deferred window teardown (see the Hide Window button). Cheap flag check,
    -- and it must run even when the script is disabled. close_settings_window is
    -- a global defined further down; globals resolve at call time, not here.
    if want_close_window then close_settings_window() end

    if not script_enabled then return end

    -- Only run if armed, not already triggered, and the clock has caught up.
    if armed and not failure_triggered then
        if flight_elapsed >= target_elapsed then
            failure_triggered = true
            THROTTLE_OVERRIDE = 1 -- Activate override
            -- The card has now been played, so it is no longer held over.
            pending_bucket = "none"
            pending_severity = "none"
            save_state()
            local max_allowed = 1.0 - reduction_amount
            local curr = THROTTLE_RATIO[target_engine] or -1
            logMsg(string.format("Random Engine Failure: [%s] FAILURE TRIGGERED on engine %d after %.1f min of flight | card=%s/%s | reduction=%.1f%% | max_allowed=%.2f | curr_throttle=%.2f | snapshot=%s | override=1",
                now_ts(), target_engine + 1, flight_elapsed / 60, card_bucket, card_severity,
                reduction_amount * 100, max_allowed, curr, throttle_snapshot()))
        end
    end

    -- If failure is active, enforce the throttle limit
    if failure_triggered then
        -- Keep override active and drive ALL engines every frame
        THROTTLE_OVERRIDE = 1

        local max_allowed = 1.0 - reduction_amount
        local n = math.max(0, (NUM_ENGINES or 0))
        for i = 0, n - 1 do
            local pilot_cmd = COCKPIT_THROTTLE[i] or 0.0
            if i == target_engine then
                -- Failed engine: clamp to cap but allow pilot to pull back further
                local desired = math.min(pilot_cmd, max_allowed)
                if not clamp_logged and (THROTTLE_RATIO[i] or 0) > desired then
                    logMsg(string.format(
                        "Random Engine Failure: [%s] Clamp applied on engine %d | prev_actual=%.2f -> cmd=%.2f | max_allowed=%.2f | snapshot=%s",
                        now_ts(), i + 1, THROTTLE_RATIO[i] or -1, desired, max_allowed, throttle_snapshot()))
                    clamp_logged = true
                end
                THROTTLE_RATIO_USE[i] = desired
            else
                -- Good engine(s): forward pilot input so hardware keeps working
                THROTTLE_RATIO_USE[i] = pilot_cmd
            end
        end
    end
end

-- Turns the failure logic off and releases any active override.
local function disable_script()
    script_enabled = false
    failure_triggered = false
    armed = false
    THROTTLE_OVERRIDE = 0
    logMsg("Random Engine Failure: disabled (normal flight — no failure will occur).")
end

-- Turns the logic back on and forces a fresh draw on the next tick.
local function enable_script()
    script_enabled = true
    initialized = false
    logMsg("Random Engine Failure: enabled — will draw a scenario card once engines are detected.")
end

-- =============================================================================
-- GUI (ImGui)
-- =============================================================================

-- FlyWithLua NG+ owns the window frame and calls the builder with (wnd, x, y),
-- so this function draws contents only — no imgui.Begin/End. The name is passed
-- to float_wnd_set_imgui_builder as a string, so it must stay global.
function engine_failure_gui(wnd, x, y)
    -- Master enable/disable — the in-sim way to fly a normal (no-failure) session.
    if script_enabled then
        if imgui.Button("Disable (Normal Flight)") then
            disable_script()
        end
    else
        if imgui.Button("Enable (Arm Failure)") then
            enable_script()
        end
    end

    if imgui.Button("Draw New Scenario Card") then
        -- Honour the label: a manual reroll really does deal a different card,
        -- with any held-over one put back in the deck rather than binned.
        return_pending_to_deck()
        enable_script()
        setup_random_failure()
        initialized = true
    end

    if failure_triggered then
        imgui.TextUnformatted("STATUS: FAILURE ACTIVE!")
        imgui.TextUnformatted("Engine: " .. (target_engine + 1))
        if imgui.Button("Clear Failure / Reset") then
            failure_triggered = false
            THROTTLE_OVERRIDE = 0
            setup_random_failure()
            initialized = true
        end
    else
        if not script_enabled then
            imgui.TextUnformatted("STATUS: DISABLED (normal flight)")
        elseif not initialized then
            imgui.TextUnformatted("STATUS: Waiting for engines to initialize...")
        elseif cfg.require_airborne and not airborne then
            imgui.TextUnformatted("STATUS: Armed — clock starts at liftoff.")
        else
            -- Deliberately vague: knowing the countdown is what made the old
            -- behaviour predictable. Flip debug_reveal to get the numbers back.
            imgui.TextUnformatted(string.format("STATUS: Flying for %.1f min. Anything could happen.",
                flight_elapsed / 60))
        end
    end

    imgui.Separator()
    imgui.TextUnformatted("Config (random_engine_out.cfg, or edit defaults):")
    imgui.TextUnformatted(string.format("Session: %.0f min | Clean flights: %.0f%%",
        cfg.session_minutes, cfg.clean_flight_chance * 100))
    imgui.TextUnformatted(string.format("Quiet time after liftoff: %.1f min", cfg.start_delay_minutes))
    if cfg.failure_deadline_minutes > 0 then
        imgui.TextUnformatted(string.format("Fires by: %.1f min of flight at the latest",
            cfg.failure_deadline_minutes))
    end
    imgui.TextUnformatted(string.format("Reduction: %.0f%% - %.0f%%", cfg.min_reduction * 100, cfg.max_reduction * 100))
    imgui.TextUnformatted(string.format("Flights flown: %d", flights_flown))

    if cfg.debug_reveal then
        imgui.Separator()
        imgui.TextUnformatted("-- DEBUG REVEAL (spoilers) --")
        imgui.TextUnformatted(string.format("Card: %s / %s", card_bucket, card_severity))
        if armed and not failure_triggered then
            imgui.TextUnformatted(string.format("Fires at %.1f min (%.1f min to go)",
                target_elapsed / 60, math.max(0, (target_elapsed - flight_elapsed) / 60)))
            imgui.TextUnformatted(string.format("Target engine: %d", target_engine + 1))
        elseif clean_flight then
            imgui.TextUnformatted("Clean flight — nothing armed.")
        end
        imgui.TextUnformatted(string.format("Cards left: %d timing, %d severity", #deck, #severity_deck))
        imgui.TextUnformatted(string.format("Held over: %s / %s", pending_bucket, pending_severity))
    end

    if imgui.Button("Hide Window") then
        -- Destroying a window from inside its own builder is unsafe; let the
        -- per-frame housekeeping in process_failure() do it a moment later.
        want_close_window = true
    end
end

-- Creates the floating ImGui window. Previous versions probed for do_on_imgui,
-- which does not exist in any FlyWithLua build — so the GUI never appeared and
-- there was no in-sim sign of whether the script was armed. NG+ 2.8+ builds
-- ImGui windows through float_wnd_create instead.
function open_settings_window()
    if settings_wnd ~= nil then return end
    if type(float_wnd_create) ~= "function" or imgui == nil then
        logMsg("Random Engine Failure: this FlyWithLua build has no ImGui window API — GUI unavailable.")
        return
    end
    settings_wnd = float_wnd_create(340, 320, 1, true)
    float_wnd_set_title(settings_wnd, "Random Engine Failure Settings")
    float_wnd_set_imgui_builder(settings_wnd, "engine_failure_gui")
    float_wnd_set_onclose(settings_wnd, "on_settings_window_closed")
end

function close_settings_window()
    want_close_window = false
    if settings_wnd ~= nil then
        float_wnd_destroy(settings_wnd)
        settings_wnd = nil
    end
end

-- FlyWithLua calls this when the user clicks the window's X. The window is
-- already gone by then, so just drop our handle — destroying it again crashes.
function on_settings_window_closed(wnd)
    settings_wnd = nil
    want_close_window = false
end

-- Menu entry to bring the window back after hiding it.
add_macro("Random Engine Failure Settings", "open_settings_window()", "close_settings_window()", "activate")

-- =============================================================================
-- FLYWITHLUA HOOKS
-- =============================================================================

-- Load config and persistent deck state, then set the effective enable state.
load_config()
load_state()
script_enabled = cfg.enabled
if not script_enabled then
    logMsg("Random Engine Failure: disabled by config (enabled=false) — normal flight.")
end

-- Deferred init: keep checking for engines until we can draw a card (retries).
do_sometimes("try_initialize()")

-- Flight clock: once per second is plenty and keeps the per-frame path cheap.
do_often("update_flight_clock()")

-- Every frame loop
do_every_frame("process_failure()")

-- Draw status on screen if debugging or desired
function draw_failure_status()
    if failure_triggered then
        draw_string(20, 40, "ENGINE FAILURE ACTIVE: ENGINE " .. (target_engine + 1), "red")
    end
end

do_every_draw("draw_failure_status()")

-- Open the settings window on load, so there is always a visible indication of
-- whether the script is armed. Hide it from the FlyWithLua macro menu.
open_settings_window()
