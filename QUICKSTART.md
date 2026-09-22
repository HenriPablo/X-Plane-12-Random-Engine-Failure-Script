# Quick Start

The short version. For how the deck works and why, see [README.md](README.md).

---

## 1. Install it

From the project root:

```cmd
:: Windows
deploy.bat
```

```bash
# Linux / macOS
./deploy.sh
```

That copies `src/main.lua` to `<X-Plane>/Resources/plugins/FlyWithLua/Scripts/random_engine_out.lua`,
copies `src/modules/reo_*.lua` into `FlyWithLua/Modules/`, and backs up any
previous copies. Both halves are required — the script logs
`FATAL — could not load module` and stays inert without the modules. If X-Plane
isn't at `C:\X-Plane 12` (Windows) or `~/X-Plane 12` (Linux/macOS):

```cmd
deploy.bat -XPlanePath "D:\Games\X-Plane 12"
```

**Re-run this after every edit to `src/main.lua`.** Editing the file in this repo
changes nothing in the sim until you deploy.

---

## 2. Launch a session

```cmd
:: Windows — from the project root
tools\practice-launch.bat armed
```

```bash
# Linux / macOS
./tools/practice-launch.sh armed
```

> ⚠️ **The word `armed` is not optional.** Without it the launcher writes
> `enabled = false` and you will fly a perfectly normal, failure-free session.
> That setting is **sticky** — it stays in the config file until something
> rewrites it, so starting X-Plane directly (not via the launcher) reuses
> whatever the last launch wrote. If you've flown several quiet flights in a row,
> check this first.

### Launcher arguments

`practice-launch.bat [mode] [quiet-minutes] [session-minutes]`

| Command | Effect |
| --- | --- |
| `practice-launch.bat` | Normal flight — failures **disabled** |
| `practice-launch.bat armed` | Armed, 25-minute session, failure possible from liftoff |
| `practice-launch.bat armed 10` | Armed, but guaranteed quiet for the first 10 min of flight |
| `practice-launch.bat armed 0 50` | Armed, 50-minute session (timing spreads over twice the distance) |

Set these first if you need them:

```cmd
set XPLANE_PATH=D:\Games\X-Plane 12
set CLEAN_FLIGHT_CHANCE=0.2      :: fewer no-failure flights (default 0.35)
set DEBUG_REVEAL=true            :: show the drawn card + countdown (spoilers)
```

---

## 3. Fly

1. Load an aircraft with at least one engine. The script arms itself
   automatically once it detects them.
2. Take off. **The clock starts at liftoff**, not at load — taxi, startup and
   run-up cost you nothing. It also pauses when the sim pauses.
3. At some point in the session, one engine loses power. Which engine, when, and
   how badly are all drawn from the deck. Sometimes nothing happens at all —
   that's by design (see `clean_flight_chance`).
4. Recover: identify, verify, feather/secure as appropriate. The power loss is
   enforced every frame, so you cannot throttle your way out of it.

Verify what the script did in `<X-Plane>\Log.txt` — search for
`Random Engine Failure:`. It logs the card drawn, its target time, liftoff, the
trigger, and the deck remainder. **It is a full spoiler**, so read it after the
flight, not before.

---

## 4. Options

All of these live in `<X-Plane>\Resources\plugins\FlyWithLua\Scripts\random_engine_out.cfg`.
The launcher rewrites the first three; edit the file by hand for the rest.
Start from [`src/random_engine_out.cfg.example`](src/random_engine_out.cfg.example),
which documents every key inline.

| Key | What it does | Default |
| --- | --- | --- |
| `enabled` | `false` = normal flight, nothing will happen | `true` |
| `session_minutes` | Session length in **flying** minutes; failure timing scales to it | `25` |
| `start_delay_minutes` | Guaranteed quiet minutes after liftoff | `0` |
| `failure_deadline_minutes` | Fire by this minute of flight at the latest (`0` = no backstop) | `0` |
| `clean_flight_chance` | Share of flights with no failure at all (0.0–0.8) | `0.35` |
| `min_reduction` / `max_reduction` | How much power a failure can take (`1.0` = driven to idle) | `0.3` / `1.0` |
| `require_airborne` | `false` starts the clock on the ground — for testing only | `true` |
| `debug_reveal` | Show the card and countdown in-sim. Ruins the surprise | `false` |

Anything missing from the file falls back to the default. Changes take effect on
FlyWithLua → **Reload all Lua scripts**, or on the next X-Plane start.

### Want failures more often?

Lower `clean_flight_chance` — `0.0` means every flight gets one:

```
clean_flight_chance = 0.0
```

Then delete `random_engine_out.state` so the deck rebuilds with the new mix.

Also make sure `session_minutes` matches your **airborne** time, not your
wall-clock block. A 25-minute practice block in a C172 is maybe 15–18 minutes
wheels-up once you've started, taxied and run up — and a late-session card
scheduled for minute 22 of a 25-minute session has nowhere to fire.

Two things now protect you from that. A card that doesn't fire is **held over**
and re-armed on your next flight rather than spent, so it can't go missing. And
`failure_deadline_minutes` pulls late cards back to a time you'll actually reach:

```
failure_deadline_minutes = 18
```

Of the two, **the deadline is the one that reduces quiet flights.** Carry-over
only stops cards being lost — the flight it expired on was still a quiet one. So
if failures feel too rare, count the `outcome = expired` rows in
`history.csv`: each one is a flight that went quiet because its card was
scheduled past your landing. More than a couple means lower the deadline.

---

## 5. Your training record

Every scenario the script deals gets one row in:

```
<X-Plane>\Resources\plugins\FlyWithLua\Scripts\random_engine_out.history.csv
```

Open it in Excel. One row per card, with the aircraft, what was dealt, and how
it resolved:

| `outcome` | Meaning |
| --- | --- |
| `fired` | The failure happened — `fired_at_min` is how far into the flight |
| `clean` | A clean card; nothing was going to happen that flight |
| `expired` | The flight ended with the card still armed. `notes` shows what it was scheduled for versus how far you actually got |

A run of `expired` rows is the file telling you `session_minutes` or
`failure_deadline_minutes` doesn't match how long you really stay airborne.

The grading columns (`reaction_s`, `correct_engine`, `max_bank`, …) are present
but empty — they're filled in a later phase. `grade` reads `unscored` for now.

Unlike `Log.txt`, this file is safe to read before a flight: it's a record of
what already happened, not a spoiler for what's coming. Deleting
`random_engine_out.state` to reshuffle the deck does **not** touch it.

## 6. Reset the deck

The script remembers what it dealt you, in:

```
<X-Plane>\Resources\plugins\FlyWithLua\Scripts\random_engine_out.state
```

Delete that file to reshuffle from scratch. Worth doing after changing
`clean_flight_chance` or when starting a fresh training block.

---

## 7. Nothing is happening — checklist

Run through these in order:

```cmd
:: 1. Is it actually enabled? Look for "enabled = false".
type "C:\X-Plane 12\Resources\plugins\FlyWithLua\Scripts\random_engine_out.cfg"

:: 2. Is the deployed script current? Compare against src\main.lua.
dir "C:\X-Plane 12\Resources\plugins\FlyWithLua\Scripts\random_engine_out.lua"

:: 3. What did it decide? (spoilers)
findstr /C:"Random Engine Failure" "C:\X-Plane 12\Log.txt"
```

In the log you want to see a line reading `Card drawn: EARLY/HEAVY | ...`. If you
instead see:

- `disabled by config (enabled=false)` → you launched without `armed` (step 2 above).
- `config loaded ... wait=0.5-2.0min` → the deployed script is an **old version**.
  Re-run `deploy.bat`.
- `no config file at ...` → the launcher never wrote one; check `XPLANE_PATH`.
- `Card drawn: CLEAN` → working as intended, this flight gets nothing. Lower
  `clean_flight_chance` if that's happening too often.
- `FATAL — could not load module` → the `Modules/reo_*.lua` files are missing.
  Re-run `deploy.bat`, which copies them.
- nothing at all → FlyWithLua isn't loading the script. Check it appears in
  X-Plane's Plugins menu and that the file isn't in `Scripts (Quarantine)`.

## The in-sim window

A window titled **Random Engine Failure Settings** opens on load and shows
whether the script is armed — check it if you're unsure. If you close it, reopen
it from the FlyWithLua **Macros** menu. It gives you:

- **Disable (Normal Flight)** / **Enable (Arm Failure)** — fly a quiet session
  without touching the config.
- **Draw New Scenario Card** — reroll now. Any held-over card goes back into the
  deck rather than being binned.
- **Clear Failure / Reset** — release the throttle override after a failure and
  arm the next one.

Status is deliberately vague ("Flying for 12.4 min. Anything could happen.")
unless you set `debug_reveal = true`.
