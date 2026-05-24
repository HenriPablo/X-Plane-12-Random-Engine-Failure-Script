-- X-Plane 12 Random Engine Failure Script
-- For use with FlyWithLua

-- =============================================================================
-- VERIFICATION SECTION (Simple check to see if script is running)
-- =============================================================================
logMsg("Random Engine Failure script loaded successfully!")

-- =============================================================================
-- CONFIGURATION / PARAMETERS
-- =============================================================================
local MIN_WAIT_MINUTES = 5      -- Minimum time to wait before first potential failure
local MAX_WAIT_MINUTES = 30     -- Maximum time to wait before first potential failure
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

-- =============================================================================
-- DATAREFS
-- =============================================================================
-- Number of engines on current aircraft
dataref("NUM_ENGINES", "sim/flightmodel/engines/num_engines", "readonly")
-- Array of throttle settings (0.0 to 1.0)
dataref("THROTTLE_RATIO", "sim/flightmodel/engine/ENGN_thro", "writable")
-- Override throttle control (1 = override active)
dataref("THROTTLE_OVERRIDE", "sim/operation/override/override_throttles", "writable")

-- =============================================================================
-- CORE LOGIC
-- =============================================================================

function setup_random_failure()
    if NUM_ENGINES < 2 then
        logMsg("Random Engine Failure: Single engine aircraft detected. Script inactive.")
        script_enabled = false
        return
    end

    script_enabled = true
    failure_triggered = false
    THROTTLE_OVERRIDE = 0

    -- Pick a random engine (0-indexed in dataref array)
    target_engine = math.random(0, NUM_ENGINES - 1)
    
    -- Pick a random reduction (0.9 means 90% loss, leaving 10% power)
    reduction_amount = MIN_THROTTLE_REDUCTION + (math.random() * (MAX_THROTTLE_REDUCTION - MIN_THROTTLE_REDUCTION))
    
    -- Pick a random time
    local wait_seconds = math.random(MIN_WAIT_MINUTES * 60, MAX_WAIT_MINUTES * 60)
    failure_time = os.clock() + wait_seconds
    
    logMsg(string.format("Random Engine Failure: Scheduled for engine %d in %d seconds (Reduction: %.1f%%)", 
        target_engine + 1, wait_seconds, reduction_amount * 100))
end

function process_failure()
    if not script_enabled then return end

    -- Only run if not already triggered and we have a valid failure time
    if not failure_triggered and failure_time > 0 then
        if os.clock() >= failure_time then
            failure_triggered = true
            THROTTLE_OVERRIDE = 1 -- Activate override
            logMsg("Random Engine Failure: FAILURE TRIGGERED on engine " .. (target_engine + 1))
        end
    end

    -- If failure is active, enforce the throttle limit
    if failure_triggered then
        -- We must keep setting THROTTLE_OVERRIDE = 1 to ensure it stays overridden
        THROTTLE_OVERRIDE = 1
        
        local max_allowed = 1.0 - reduction_amount
        if THROTTLE_RATIO[target_engine] > max_allowed then
            THROTTLE_RATIO[target_engine] = max_allowed
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
do_on_imgui("engine_failure_gui()")