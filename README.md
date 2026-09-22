# X‑Plane 12 — Random Engine Failure (FlyWithLua)

A FlyWithLua script for X‑Plane 12 that randomly schedules and triggers a throttle reduction on one engine of single- or multi-engine aircraft. Includes an ImGui settings window and structured logging.

Failure timing is driven by a **shuffled scenario deck** that remembers what it dealt you last flight, so failures are spread across the session instead of always landing in the first two minutes — and a configurable share of flights get no failure at all.

> **Just want to fly?** See **[QUICKSTART.md](QUICKSTART.md)** — install, launch, options, and a
> "nothing is happening" checklist. This document is the deep dive: design rationale,
> datarefs, and how the deck is built.

## Files
- `QUICKSTART.md` — Short how-to: deploy, launch, the options that matter.
- `src/main.lua` — The Lua script (install this into FlyWithLua Scripts as `random_engine_out.lua`).
- `src/random_engine_out.cfg.example` — Sample per-flight config file (see “Configuring per flight”).
- `tools/practice-launch.bat` / `tools/practice-launch.sh` — One-command launcher that writes the config, then starts X‑Plane (Windows / Linux‑macOS).
- `deploy.ps1` — PowerShell deployment helper for Windows.
- `deploy.bat` — Convenience wrapper to run `deploy.ps1` even if PowerShell execution policy is restricted.
- `deploy.sh` — Bash deployment helper for Linux/macOS.

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

## Quick deploy (Linux / macOS)

```bash
./deploy.sh                                    # defaults (~/X-Plane 12)
./deploy.sh --xplane-path "/games/X-Plane 12"  # custom install path
./deploy.sh --script-name random_engine_out.lua
./deploy.sh --dry-run                          # show actions, change nothing
./deploy.sh --force                            # overwrite without a .bak backup
```

## Manual install (if you prefer)
Copy `src/main.lua` to:

```
C:\X-Plane 12\Resources\plugins\FlyWithLua\Scripts\random_engine_out.lua
```

## Using the script in X‑Plane
1. Start X‑Plane and load an aircraft with at least one engine.
2. The “Random Engine Failure Settings” window opens automatically; reopen it from the FlyWithLua **Macros** menu if you hide it.
3. It draws a scenario card automatically once engines are detected. Use **Disable (Normal Flight)** to fly without a failure, **Enable (Arm Failure)** to re‑arm, or **Draw New Scenario Card** to reroll immediately.
4. Take off. The clock only starts at liftoff and only runs while the sim is unpaused, so taxi time and coffee breaks never burn the window.
5. Watch `Log.txt` for lines prefixed with `Random Engine Failure:` to see the card drawn, the liftoff timestamp, the trigger, and the one‑time clamp message.

The settings window deliberately does **not** show a countdown — knowing the number is what made the old behaviour predictable. Set `debug_reveal = true` in the config to get the spoilers back while testing.

## How the scenario deck works

Rather than rolling fresh dice every flight, the script deals from a deck and writes the remaining cards to disk. A card that has been spent cannot come back until the deck recycles, which is what turns *"it probably won't be early again"* into *"it can't be early again yet."*

**Timing deck** — two cards each of `early` (5–25% into the session), `mid` (25–65%) and `late` (65–100%), plus enough `clean` cards to hit `clean_flight_chance`. At the default 0.35 that is a 9‑card deck: 3 clean, 2 early, 2 mid, 2 late.

**Severity deck** — two cards each of `light` (30–55% power loss), `heavy` (55–85%) and `total` (driven to idle), drawn separately so the mix stays even regardless of timing.

Both decks are arranged so consecutive flights never repeat the same bucket. Clean cards are exempt — forbidding *those* from repeating would make clean and failure flights alternate, which is its own kind of predictable.

Percentages over a full deck are exact, not merely average. With the defaults you get exactly 1 clean flight in 3, and never two `early` failures back to back.

### Held-over cards

That exactness depends on one more rule: **a card that was armed but never fired is not spent.** If the flight ends first — or a `late` card was scheduled past the end of your real airborne time — the card is stored as `pending_bucket` / `pending_severity` and re-armed on the next flight. Its bucket and severity carry over; the exact second and the target engine are re-rolled, so a card coming back is not a card you can predict.

Without this, long `session_minutes` values quietly bias you toward quiet flights: every unreachable `late` card would vanish from the deck having done nothing. Use `failure_deadline_minutes` to stop them being scheduled out of reach in the first place.

A new flight is detected via `sim/time/total_flight_time_sec` going backwards, so repositioning or restarting re-arms cleanly rather than inheriting a clock that already ran past the target.

### Deck memory

The remaining cards live in `random_engine_out.state`, next to the config:

```
C:\X-Plane 12\Resources\plugins\FlyWithLua\Scripts\random_engine_out.state
```

Delete it to reset the rotation — worth doing after changing `clean_flight_chance`, or when starting a fresh training block.

You should also see on load:
```
Random Engine Failure script loaded successfully!
```

## Controlling whether/when it runs

By default the script arms automatically for any aircraft with engines. There are three ways to change that per flight — no code editing required.

X‑Plane does **not** pass command-line arguments to FlyWithLua scripts, so there is no `X-Plane.exe --no-failure` style flag. The supported mechanisms are:

**1. In‑sim toggle (quickest).** Open the settings window and click **Disable (Normal Flight)**. This releases any active override and guarantees a normal session. Re‑enable any time.

**2. Config file (persists across restarts).** Copy `src/random_engine_out.cfg.example` next to the installed script and rename it to `random_engine_out.cfg`:

```
C:\X-Plane 12\Resources\plugins\FlyWithLua\Scripts\random_engine_out.cfg
```

Keys (all optional; missing ones use defaults):

| Key | Meaning | Default |
| --- | --- | --- |
| `enabled` | `false` = normal flight, no failure | `true` |
| `session_minutes` | Nominal session length in **flying** minutes; timing scales to it | `25` |
| `clean_flight_chance` | Share of flights that draw a `clean` card and get no failure (0.0–0.8) | `0.35` |
| `start_delay_minutes` | Guaranteed quiet minutes **after liftoff**; floors the drawn time | `0` |
| `failure_deadline_minutes` | Latest point of flight a failure may fire; caps the drawn time so late cards can't overshoot your real airborne time (`0` = no backstop) | `0` |
| `require_airborne` | Start the clock at liftoff rather than at arming (`false` for ground testing) | `true` |
| `min_reduction` / `max_reduction` | Range the light/heavy/total severity bands are clamped into | `0.3` / `1.0` |
| `debug_reveal` | Show the drawn card, countdown and remaining deck in the GUI | `false` |

Retired: `min_wait_minutes` / `max_wait_minutes` are ignored (and logged) — timing now comes from `session_minutes` plus the card deck.

The file is read on load and on “Reload all Lua scripts”.

**3. Launcher (the “from the command line” answer).** `tools/practice-launch.bat` writes the config and then starts X‑Plane, so a single command controls the session:

```cmd
:: Windows
tools\practice-launch.bat              :: normal flight (failures disabled)
tools\practice-launch.bat armed        :: failures enabled, 25-minute session
tools\practice-launch.bat armed 10     :: enabled, at least 10 min of quiet flying first
tools\practice-launch.bat armed 0 50   :: enabled, 50-minute session (two pomodoros)
```

```bash
# Linux / macOS
./tools/practice-launch.sh             # normal flight (failures disabled)
./tools/practice-launch.sh armed       # failures enabled, 25-minute session
./tools/practice-launch.sh armed 10    # enabled, at least 10 min of quiet flying first
./tools/practice-launch.sh armed 0 50  # enabled, 50-minute session (two pomodoros)
```

Set `XPLANE_PATH` first if X‑Plane isn’t at the default location (`C:\X-Plane 12` on Windows, `~/X-Plane 12` on Linux/macOS). `CLEAN_FLIGHT_CHANCE` and `DEBUG_REVEAL` are also honoured as environment overrides.

The launchers rewrite `random_engine_out.cfg` from scratch, so any key they don’t emit falls back to the script default. They never touch `random_engine_out.state`, so the deck rotation carries across launches.

## Troubleshooting
- Script quarantined: Ensure we bind `THROTTLE_RATIO` as a table. This repo already uses `THROTTLE_RATIO = dataref_table("sim/flightmodel/engine/ENGN_thro")`.
- No-engine aircraft: the script stays idle and keeps re-checking for engines (no permanent self-disable), so it also handles aircraft that finish loading a moment after the script does.
- FlyWithLua not installed: `deploy.ps1` will still create the `Scripts` folder, but you must install the plugin for the script to run.
- Reload after updating: Use FlyWithLua → "Reload all Lua scripts" or restart X‑Plane.

## Development notes
- The script uses per‑frame enforcement with a one‑time clamp log to avoid spam.
- Logs include throttle snapshots and timestamps to help diagnose behavior.
- The flight clock is accumulated by the script itself at 1 Hz from `sim/time/total_running_time_sec` deltas, gated on `sim/time/paused` and `sim/flightmodel/failures/onground_any`. Rolling our own counter means the script does not depend on whether the sim's running-time dataref advances while paused, and deltas above 5 s are discarded so a flight reload or teleport cannot skip the window.
- `airborne` latches on first liftoff and stays set, so touch‑and‑goes keep accumulating time across circuits rather than resetting each pattern.
