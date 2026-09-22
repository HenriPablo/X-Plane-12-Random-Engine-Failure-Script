-- reo_deck.lua — the scenario deck and its persistent memory.
--
-- Rather than rolling fresh dice every flight, the script deals from a deck and
-- writes the remaining cards to disk. A spent card cannot come back until the
-- deck recycles, which turns "it probably won't be early again" into "it can't
-- be early again yet".
--
-- Loaded with require("reo_deck"); call M.init(reo) once with the shared context
-- table so the module can see cfg, mutable state and the util helpers.

local M = {}

local reo, cfg, state, util

-- =============================================================================
-- CARD DEFINITIONS
-- =============================================================================
-- Timing buckets, expressed as a fraction of session_minutes of *flying* time.
-- "clean" is handled separately: it has no window because nothing fires.
M.BUCKET_WINDOWS = {
    early = { 0.05, 0.25 }, -- climb-out / departure
    mid   = { 0.25, 0.65 }, -- cruise / practice area
    late  = { 0.65, 1.00 }, -- descent / pattern
}
M.BUCKET_ORDER = { "early", "mid", "late" }

-- Severity bands as absolute throttle-loss fractions. Each is clamped to the
-- configured [min_reduction, max_reduction] range so the config still governs.
M.SEVERITY_BANDS = {
    light = { 0.30, 0.55 }, -- noticeable partial loss, still climbing/level-able
    heavy = { 0.55, 0.85 }, -- serious partial loss, descent inevitable
    total = { 1.00, 1.00 }, -- driven to idle
}
M.SEVERITY_ORDER = { "light", "heavy", "total" }

M.CARDS_PER_BUCKET = 2 -- 2 each of early/mid/late = 6 failure cards per deck

function M.is_valid_bucket(name)
    return name == "clean" or M.BUCKET_WINDOWS[name] ~= nil
end

function M.is_valid_severity(name)
    return M.SEVERITY_BANDS[name] ~= nil
end

-- =============================================================================
-- PERSISTENT STATE (the "learning" memory)
-- =============================================================================
-- The deck lives in a small key=value file next to the config. Because the
-- remaining cards are written back after every draw, a failure that has already
-- been used cannot come back until the whole deck recycles.

local function state_path()
    return (SCRIPT_DIRECTORY or "") .. "random_engine_out.state"
end

M.state_path = state_path

-- Splits "a,b,c" into a list, discarding tokens that fail the validator.
local function parse_card_list(v, validator)
    local out = {}
    for token in string.gmatch(v, "[^,]+") do
        local card = string.lower(util.trim(token))
        if validator(card) then
            out[#out + 1] = card
        end
    end
    return out
end

function M.load_state()
    local f = io.open(state_path(), "r")
    if not f then
        logMsg("Random Engine Failure: no saved deck state — starting a fresh deck.")
        return
    end

    for raw in f:lines() do
        local line = util.trim(raw)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
            if k then
                k = string.lower(k)
                v = util.trim(v)
                if k == "deck" then
                    state.deck = parse_card_list(v, M.is_valid_bucket)
                elseif k == "severity_deck" then
                    state.severity_deck = parse_card_list(v, M.is_valid_severity)
                elseif k == "last_bucket" then
                    if M.is_valid_bucket(v) then state.last_bucket = v end
                elseif k == "last_severity" then
                    if M.is_valid_severity(v) then state.last_severity = v end
                elseif k == "pending_bucket" then
                    if M.BUCKET_WINDOWS[v] ~= nil then state.pending_bucket = v end
                elseif k == "pending_severity" then
                    if M.is_valid_severity(v) then state.pending_severity = v end
                elseif k == "flights" then
                    state.flights_flown = tonumber(v) or 0
                end
            end
        end
    end
    f:close()

    logMsg(string.format(
        "Random Engine Failure: deck state loaded | flights=%d, timing_cards_left=%d, severity_cards_left=%d, last=%s/%s, pending=%s/%s",
        state.flights_flown, #state.deck, #state.severity_deck,
        state.last_bucket, state.last_severity,
        state.pending_bucket, state.pending_severity))
end

function M.save_state()
    local path = state_path()
    local f = io.open(path, "w")
    if not f then
        logMsg("Random Engine Failure: WARNING could not write deck state to " .. path)
        return
    end
    f:write("# Random Engine Failure — auto-generated deck state. Delete to reset.\n")
    f:write("# 'deck' is consumed from the END of the list.\n")
    f:write("deck = " .. table.concat(state.deck, ",") .. "\n")
    f:write("severity_deck = " .. table.concat(state.severity_deck, ",") .. "\n")
    f:write("last_bucket = " .. state.last_bucket .. "\n")
    f:write("last_severity = " .. state.last_severity .. "\n")
    f:write("# A card armed but not yet fired. Re-armed next flight, not spent.\n")
    f:write("pending_bucket = " .. state.pending_bucket .. "\n")
    f:write("pending_severity = " .. state.pending_severity .. "\n")
    f:write("flights = " .. tostring(state.flights_flown) .. "\n")
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

M.arrange_no_adjacent = arrange_no_adjacent

-- Builds a fresh timing deck: CARDS_PER_BUCKET of each failure bucket, plus
-- however many "clean" cards are needed to hit clean_flight_chance. Solving
-- clean / (clean + failures) = chance gives clean = failures * c / (1 - c).
local function build_deck()
    local fresh = {}
    for _, bucket in ipairs(M.BUCKET_ORDER) do
        for _ = 1, M.CARDS_PER_BUCKET do
            fresh[#fresh + 1] = bucket
        end
    end

    local failure_cards = #fresh
    local c = cfg.clean_flight_chance
    local clean_cards = 0
    if c > 0 then
        clean_cards = math.floor((failure_cards * c / (1 - c)) + 0.5)
        clean_cards = util.clamp(clean_cards, 0, 18)
    end
    for _ = 1, clean_cards do
        fresh[#fresh + 1] = "clean"
    end

    local arranged = arrange_no_adjacent(fresh, state.last_bucket, "clean")
    logMsg(string.format(
        "Random Engine Failure: new timing deck shuffled | %d cards (%d failure, %d clean = %.0f%% clean)",
        #arranged, failure_cards, clean_cards, (clean_cards / #arranged) * 100))
    return arranged
end

local function build_severity_deck()
    local fresh = {}
    for _, sev in ipairs(M.SEVERITY_ORDER) do
        for _ = 1, M.CARDS_PER_BUCKET do
            fresh[#fresh + 1] = sev
        end
    end
    local arranged = arrange_no_adjacent(fresh, state.last_severity, nil)
    logMsg(string.format("Random Engine Failure: new severity deck shuffled | %d cards.", #arranged))
    return arranged
end

function M.draw_timing_card()
    if #state.deck == 0 then state.deck = build_deck() end
    return table.remove(state.deck)
end

function M.draw_severity_card()
    if #state.severity_deck == 0 then state.severity_deck = build_severity_deck() end
    return table.remove(state.severity_deck)
end

-- Puts a held-over card back into the decks so an explicit manual reroll does
-- not quietly destroy it. Inserted at the front (decks are consumed from the
-- end) so it resurfaces later in the rotation rather than immediately.
function M.return_pending_to_deck()
    if state.pending_bucket == "none" then return end
    table.insert(state.deck, 1, state.pending_bucket)
    if state.pending_severity ~= "none" then
        table.insert(state.severity_deck, 1, state.pending_severity)
    end
    logMsg(string.format(
        "Random Engine Failure: held-over card %s/%s returned to the deck.",
        state.pending_bucket, state.pending_severity))
    state.pending_bucket = "none"
    state.pending_severity = "none"
end

function M.init(context)
    reo = context
    cfg = context.cfg
    state = context.state
    util = context.util
    return M
end

return M
