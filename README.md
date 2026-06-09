# X‑Plane 12 — Random Engine Failure (FlyWithLua)

A FlyWithLua script for X‑Plane 12 that randomly schedules and triggers a throttle reduction on one engine of multi‑engine aircraft. Includes an ImGui settings window and structured logging.

## Files
- `src/main.lua` — The Lua script (install this into FlyWithLua Scripts as `random_engine_out.lua`).
- `deploy.ps1` — PowerShell deployment helper for Windows.
- `deploy.bat` — Convenience wrapper to run `deploy.ps1` even if PowerShell execution policy is restricted.

## Quick deploy (Windows)
- Default X‑Plane path assumed: `C:\X-Plane 12`
- Default installed name: `random_engine_out.lua`

From a terminal in the project root:

```powershell
# Option A: With defaults (C:\X-Plane 12)
./deploy.ps1

# Option B: Provide a custom install path
./deploy.ps1 -XPlanePath "D:\Games\X-Plane 12"

# Option C: Change the installed filename
./deploy.ps1 -ScriptName random_engine_out.lua

# Optional flags
./deploy.ps1 -DryRun        # Show what would happen without changing files
./deploy.ps1 -Force         # Overwrite without creating a .bak timestamped backup
```

If PowerShell script execution is blocked, use the batch wrapper:

```cmd
deploy.bat -XPlanePath "D:\Games\X-Plane 12"
```

## Manual install (if you prefer)
Copy `src/main.lua` to:

```
C:\X-Plane 12\Resources\plugins\FlyWithLua\Scripts\random_engine_out.lua
```

## Using the script in X‑Plane
1. Start X‑Plane and load a multi‑engine aircraft.
2. From the FlyWithLua menu, open “Random Engine Failure Settings”.
3. Click "Schedule New Random Failure".
4. Watch `Log.txt` for lines prefixed with `Random Engine Failure:` to see initialization, schedule, trigger, and one‑time clamp messages.

You should also see on load:
```
Random Engine Failure script loaded successfully!
```

## Troubleshooting
- Script quarantined: Ensure we bind `THROTTLE_RATIO` as a table. This repo already uses `THROTTLE_RATIO = dataref_table("sim/flightmodel/engine/ENGN_thro")`.
- Single‑engine aircraft: the script will disable itself and log a message.
- FlyWithLua not installed: `deploy.ps1` will still create the `Scripts` folder, but you must install the plugin for the script to run.
- Reload after updating: Use FlyWithLua → "Reload all Lua scripts" or restart X‑Plane.

## Development notes
- The script uses per‑frame enforcement with a one‑time clamp log to avoid spam.
- Logs include throttle snapshots and timestamps to help diagnose behavior.