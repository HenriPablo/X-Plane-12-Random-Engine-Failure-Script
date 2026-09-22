-- reo_scenarios.lua — the emergency catalog.
--
-- The deck decides *when* something goes wrong; a scenario decides *what*. Each
-- entry owns its own effect, so adding an emergency does not mean touching the
-- clock, the deck or the GUI.
--
-- Entry contract:
--   id, label            identity and a human-readable name
--   applies(ac)          may this scenario be dealt to this aircraft?
--   arm(ev)              choose the specifics (which engine, how much)
--   fire(ev)             make it happen
--   enforce(ev)          per-frame upkeep; nil if the sim holds the failure itself
--   clear(ev)            undo it and release any override
--   expected_actions     control inputs that count as "responding" (grading)
--   metrics              which measurements are meaningful for this scenario
--   ias_target           reference speed the recovery should be flown at
--
-- Only engine_out is populated today. Most future entries will set a
-- sim/operation/failures/rel_* dataref in fire() and need no enforce() at all —
-- X-Plane holds those failures itself. That is the point of the indirection.

local M = {}

local reo, state, util

M.SCENARIOS = {}

M.SCENARIOS["engine_out"] = {
    id = "engine_out",
    label = "Partial/total power loss",

    applies = function(ac)
        return (ac.engines or 0) >= 1
    end,

    -- Pick the engine and the exact power loss. The severity card has already
    -- been drawn; the band it names is clamped into the configured reduction
    -- range so the config still governs how bad things can get.
    arm = function(ev)
        ev.engine = math.random(0, (NUM_ENGINES or 1) - 1)

        local band = reo.deck.SEVERITY_BANDS[ev.severity]
        local cfg = reo.cfg
        local lo = util.clamp(band[1], cfg.min_reduction, cfg.max_reduction)
        local hi = util.clamp(band[2], cfg.min_reduction, cfg.max_reduction)
        ev.reduction = lo + (math.random() * (hi - lo))

        -- Mirror onto the shared state the clock and GUI read.
        state.target_engine = ev.engine
        state.reduction_amount = ev.reduction
        return ev
    end,

    -- Taking the override is all that is needed; enforce() does the work from
    -- here, every frame, until cleared.
    fire = function(ev)
        THROTTLE_OVERRIDE = 1
        state.clamp_logged = false
    end,

    -- Drive every engine each frame: the failed one clamped to its cap, the rest
    -- following pilot input so hardware throttles keep working normally.
    enforce = function(ev)
        THROTTLE_OVERRIDE = 1

        local max_allowed = 1.0 - state.reduction_amount
        local target = state.target_engine
        local n = math.max(0, (NUM_ENGINES or 0))
        for i = 0, n - 1 do
            local pilot_cmd = COCKPIT_THROTTLE[i] or 0.0
            if i == target then
                -- Failed engine: clamp to cap but allow pilot to pull back further
                local desired = math.min(pilot_cmd, max_allowed)
                if not state.clamp_logged and (THROTTLE_RATIO[i] or 0) > desired then
                    logMsg(string.format(
                        "Random Engine Failure: [%s] Clamp applied on engine %d | prev_actual=%.2f -> cmd=%.2f | max_allowed=%.2f | snapshot=%s",
                        util.now_ts(), i + 1, THROTTLE_RATIO[i] or -1, desired, max_allowed,
                        reo.throttle_snapshot()))
                    state.clamp_logged = true
                end
                THROTTLE_RATIO_USE[i] = desired
            else
                -- Good engine(s): forward pilot input so hardware keeps working
                THROTTLE_RATIO_USE[i] = pilot_cmd
            end
        end
    end,

    clear = function(ev)
        THROTTLE_OVERRIDE = 0
    end,

    expected_actions = { "mixture", "prop", "throttle" },
    metrics = { "reaction_s", "correct_engine", "ias_band", "bank", "alt_loss" },
    ias_target = "vyse_or_glide",
}

function M.get(id)
    return M.SCENARIOS[id]
end

-- Every scenario that may be dealt to the current aircraft. The deck only deals
-- engine_out today, but this is the seam a scenario deck will draw from.
function M.applicable(ac)
    local out = {}
    for id, sc in pairs(M.SCENARIOS) do
        if sc.applies == nil or sc.applies(ac) then
            out[#out + 1] = id
        end
    end
    table.sort(out) -- stable order regardless of pairs() iteration
    return out
end

function M.init(context)
    reo = context
    state = context.state
    util = context.util
    return M
end

return M
