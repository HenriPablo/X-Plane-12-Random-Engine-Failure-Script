-- X-Plane 12 Random Engine Failure Script
-- For use with FlyWithLua

-- =============================================================================
-- VERIFICATION SECTION (Simple check to see if script is running)
-- =============================================================================
logMsg("Random Engine Failure script loaded successfully!")

-- =============================================================================
-- CONFIGURATION / PARAMETERS
-- =============================================================================
local MIN_WAIT_MINUTES = 0.5      -- Minimum time to wait before first potential failure
local MAX_WAIT_MINUTES = 2     -- Maximum time to wait before first potential failure
local MIN_THROTTLE_REDUCTION = 0.5  -- At least 50% power reduction
local MAX_THROTTLE_REDUCTION = 1.0  -- Up to 100% power reduction (idle)

-- GUI State
local show_settings_window = true
local show_status_window = true

-- Internal state
local failure_triggered = false
local failure_time = 0
local target_engine = -1
local reduction_amount = 0
local script_enabled = true
local clamp_logged = false

-- =============================================================================
-- DATAREFS
-- =============================================================================
-- Number of engines on current aircraft
dataref("NUM_ENGINES", "sim/aircraft/engine/acf_num_engines", "readonly")
-- Array of throttle settings (0.0 to 1.0) — actual engine throttle ratio (read-only)
THROTTLE_RATIO = dataref_table("sim/flightmodel/engine/ENGN_thro")
-- Writable throttle command when override is enabled
THROTTLE_RATIO_USE = dataref_table("sim/flightmodel/engine/ENGN_thro_use")
-- Pilot command (what your hardware/commands are asking for) per engine
COCKPIT_THROTTLE = dataref_table("sim/cockpit2/engine/actuators/throttle_ratio")
-- Override throttle control (1 = override active)
dataref("THROTTLE_OVERRIDE", "sim/operation/override/override_throttles", "writable")

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

function setup_random_failure()
    if (NUM_ENGINES or 0) < 2 then
        logMsg("Random Engine Failure: Single engine aircraft detected. Script inactive.")
        script_enabled = false
        return
    end

    script_enabled = true
    failure_triggered = false
    THROTTLE_OVERRIDE = 0
    clamp_logged = false

    -- Baseline log of current state
    logMsg(string.format("Random Engine Failure: [%s] Initialized. Engines: %d, Throttles: %s",
        now_ts(), NUM_ENGINES or -1, throttle_snapshot()))

    -- Pick a random engine (0-indexed in dataref array)
    target_engine = math.random(0, NUM_ENGINES - 1)
    
    -- Pick a random reduction (0.9 means 90% loss, leaving 10% power)
    reduction_amount = MIN_THROTTLE_REDUCTION + (math.random() * (MAX_THROTTLE_REDUCTION - MIN_THROTTLE_REDUCTION))
    
    -- Pick a random time
    local wait_seconds = math.random(MIN_WAIT_MINUTES * 60, MAX_WAIT_MINUTES * 60)
    failure_time = os.clock() + wait_seconds

    local scheduled_ts = os.date("%Y-%m-%d %H:%M:%S", os.time() + wait_seconds)
    local max_allowed = 1.0 - reduction_amount
    local curr_th = THROTTLE_RATIO[target_engine] or -1
    logMsg(string.format("Random Engine Failure: [%s] Schedule set: engine=%d, wait=%ds (at %s), reduction=%.1f%%, max_allowed=%.2f, curr_throttle=%.2f, snapshot=%s",
        now_ts(), target_engine + 1, wait_seconds, scheduled_ts, reduction_amount * 100, max_allowed, curr_th, throttle_snapshot()))
end

function process_failure()
    if not script_enabled then return end

    -- Only run if not already triggered and we have a valid failure time
    if not failure_triggered and failure_time > 0 then
        if os.clock() >= failure_time then
            failure_triggered = true
            THROTTLE_OVERRIDE = 1 -- Activate override
            local max_allowed = 1.0 - reduction_amount
            local curr = THROTTLE_RATIO[target_engine] or -1
            logMsg(string.format("Random Engine Failure: [%s] FAILURE TRIGGERED on engine %d | reduction=%.1f%% | max_allowed=%.2f | curr_throttle=%.2f | snapshot=%s | override=1",
                now_ts(), target_engine + 1, reduction_amount * 100, max_allowed, curr, throttle_snapshot()))
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

-- =============================================================================
-- GUI (ImGui)
-- =============================================================================

function engine_failure_gui()
    if not show_settings_window then return end

    imgui.Begin("Random Engine Failure Settings")
    
    if imgui.Button("Schedule New Random Failure") then
        setup_random_failure()
    end
    
    if failure_triggered then
        imgui.TextUnformatted("STATUS: FAILURE ACTIVE!")
        imgui.TextUnformatted("Engine: " .. (target_engine + 1))
        if imgui.Button("Clear Failure / Reset") then
            failure_triggered = false
            THROTTLE_OVERRIDE = 0
            setup_random_failure()
        end
    else
        if script_enabled then
            local remaining = math.max(0, math.floor(failure_time - os.clock()))
            imgui.TextUnformatted(string.format("Next Failure in: %d seconds", remaining))
            imgui.TextUnformatted("Target Engine: (Hidden until failure)")
        else
            imgui.TextUnformatted("Script Disabled (Single Engine?)")
        end
    end

    imgui.Separator()
    imgui.TextUnformatted("Config (Edit script to change defaults):")
    imgui.TextUnformatted(string.format("Wait: %d - %d min", MIN_WAIT_MINUTES, MAX_WAIT_MINUTES))
    imgui.TextUnformatted(string.format("Reduction: %d%% - %d%%", MIN_THROTTLE_REDUCTION*100, MAX_THROTTLE_REDUCTION*100))

    if imgui.Button("Hide Window") then
        show_settings_window = false
    end

    imgui.End()
end

-- Add a menu item to show the window again if closed
add_macro("Random Engine Failure Settings", "show_settings_window = true", "show_settings_window = false", "activate")

-- =============================================================================
-- FLYWITHLUA HOOKS
-- =============================================================================

-- Initial setup when script is loaded/reloaded
setup_random_failure()

-- Every frame loop
do_every_frame("process_failure()")

-- Draw status on screen if debugging or desired
function draw_failure_status()
    if failure_triggered then
        draw_string(20, 40, "ENGINE FAILURE ACTIVE: ENGINE " .. (target_engine + 1), "red")
    end
end

do_every_draw("draw_failure_status()")
-- Register ImGui callback only if available (some FlyWithLua builds lack ImGui)
if type(do_on_imgui) == "function" and imgui ~= nil then
    do_on_imgui("engine_failure_gui()")
else
    logMsg("Random Engine Failure: ImGui not available in this FlyWithLua build — GUI disabled.")
end