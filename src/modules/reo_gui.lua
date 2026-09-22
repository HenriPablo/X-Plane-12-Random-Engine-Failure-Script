-- reo_gui.lua — the in-sim settings panel and its window lifecycle.
--
-- FlyWithLua has no do_on_imgui callback (an earlier version of this script
-- probed for one and silently ran without a GUI for months). NG+ 2.8+ creates
-- ImGui windows with float_wnd_create and calls a named builder function with
-- (wnd, x, y); the builder draws contents only and must not call
-- imgui.Begin/imgui.End, because FlyWithLua owns the frame.
--
-- The builder has to be reachable as a global by name, so the loader registers a
-- thin global shim that calls M.build().

local M = {}

local reo, cfg, state, util

local settings_wnd = nil
local want_close = false -- Destroying a window inside its own builder is unsafe,
                         -- so the close button sets this and housekeeping() does
                         -- the destroying a frame later.

-- Draws the panel contents. Called by FlyWithLua via the global shim.
function M.build(wnd, x, y)
    -- Master enable/disable — the in-sim way to fly a normal (no-failure) session.
    if state.script_enabled then
        if imgui.Button("Disable (Normal Flight)") then
            reo.actions.disable()
        end
    else
        if imgui.Button("Enable (Arm Failure)") then
            reo.actions.enable()
        end
    end

    if imgui.Button("Draw New Scenario Card") then
        -- Honour the label: a manual reroll really does deal a different card,
        -- with any held-over one put back in the deck rather than binned.
        reo.actions.draw_new()
    end

    if state.failure_triggered then
        imgui.TextUnformatted("STATUS: FAILURE ACTIVE!")
        imgui.TextUnformatted("Engine: " .. (state.target_engine + 1))
        if imgui.Button("Clear Failure / Reset") then
            reo.actions.clear()
        end
    else
        if not state.script_enabled then
            imgui.TextUnformatted("STATUS: DISABLED (normal flight)")
        elseif not state.initialized then
            imgui.TextUnformatted("STATUS: Waiting for engines to initialize...")
        elseif cfg.require_airborne and not state.airborne then
            imgui.TextUnformatted("STATUS: Armed — clock starts at liftoff.")
        else
            -- Deliberately vague: knowing the countdown is what made the old
            -- behaviour predictable. Flip debug_reveal to get the numbers back.
            imgui.TextUnformatted(string.format("STATUS: Flying for %.1f min. Anything could happen.",
                state.flight_elapsed / 60))
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
    imgui.TextUnformatted(string.format("Reduction: %.0f%% - %.0f%%",
        cfg.min_reduction * 100, cfg.max_reduction * 100))
    imgui.TextUnformatted(string.format("Flights flown: %d", state.flights_flown))

    if cfg.debug_reveal then
        imgui.Separator()
        imgui.TextUnformatted("-- DEBUG REVEAL (spoilers) --")
        imgui.TextUnformatted(string.format("Card: %s / %s", state.card_bucket, state.card_severity))
        if state.armed and not state.failure_triggered then
            imgui.TextUnformatted(string.format("Fires at %.1f min (%.1f min to go)",
                state.target_elapsed / 60,
                math.max(0, (state.target_elapsed - state.flight_elapsed) / 60)))
            imgui.TextUnformatted(string.format("Target engine: %d", state.target_engine + 1))
        elseif state.clean_flight then
            imgui.TextUnformatted("Clean flight — nothing armed.")
        end
        imgui.TextUnformatted(string.format("Cards left: %d timing, %d severity",
            #state.deck, #state.severity_deck))
        imgui.TextUnformatted(string.format("Held over: %s / %s",
            state.pending_bucket, state.pending_severity))
    end

    if imgui.Button("Hide Window") then
        want_close = true
    end
end

function M.open()
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

function M.close()
    want_close = false
    if settings_wnd ~= nil then
        float_wnd_destroy(settings_wnd)
        settings_wnd = nil
    end
end

-- FlyWithLua calls this when the user clicks the window's X. The window is
-- already gone by then, so just drop our handle — destroying it again crashes.
function M.on_closed(wnd)
    settings_wnd = nil
    want_close = false
end

-- Cheap per-frame check for the deferred teardown above.
function M.housekeeping()
    if want_close then M.close() end
end

function M.init(context)
    reo = context
    cfg = context.cfg
    state = context.state
    util = context.util
    return M
end

return M
