# Test Card — Random Engine Failure

Reusable procedures for verifying the script after a change. Work top to bottom;
the bench tests catch most things in five minutes without leaving the ramp.

> **Nothing in this project has been verified in the sim yet.** Phases 0–2 were
> written, linted and deployed, but never run. Expect to find things. Start at
> test 1 and don't skip the bench section.

---

## Before you start

```cmd
:: 1. Deploy the current source (script + modules)
deploy.bat

:: 2. Confirm both halves landed
dir "C:\X-Plane 12\Resources\plugins\FlyWithLua\Scripts\random_engine_out.lua"
dir "C:\X-Plane 12\Resources\plugins\FlyWithLua\Modules\reo_*.lua"
```

You should see five modules: `reo_util`, `reo_deck`, `reo_scenarios`,
`reo_history`, `reo_gui`.

### Bench config — fires in ~15 seconds on the ramp

Put this in `<X-Plane>\Resources\plugins\FlyWithLua\Scripts\random_engine_out.cfg`:

```
enabled = true
require_airborne = false
session_minutes = 1
clean_flight_chance = 0.0
debug_reveal = true
```

`require_airborne = false` starts the clock immediately, `session_minutes = 1`
compresses every bucket into one minute, and `clean_flight_chance = 0.0` stops
clean cards wasting your time. **All four are test-only.**

Reload with FlyWithLua → **Reload all Lua scripts** — no need to restart X-Plane
between code changes. (If a module edit ever seems not to take effect, *then*
restart X-Plane.)

### Restore before real practice

```
require_airborne = true
session_minutes = 25
clean_flight_chance = 0.35
failure_deadline_minutes = 18
debug_reveal = false
```

Or just re-run `tools\practice-launch.bat armed 0 25`, which rewrites the file.

---

## Reading the log

```cmd
findstr /C:"Random Engine Failure" "C:\X-Plane 12\Log.txt"
```

Expected sequence on a first-ever run:

| Order | Log line (fragment) |
| --- | --- |
| 1 | `script loaded successfully!` |
| 2 | `created training history at ...history.csv` (later runs: `training history has N entries`) |
| 3 | `config loaded from ... deadline=0.0min ...` |
| 4 | `no saved deck state — starting a fresh deck` (first run only) |
| 5 | `Initialized. Engines: 1, Throttles: [1: 0.00]` |
| 6 | `new timing deck shuffled \| 9 cards (6 failure, 3 clean = 33% clean)` |
| 7 | `new severity deck shuffled \| 6 cards.` |
| 8 | `Card drawn: EARLY/HEAVY \| engine=1, fires at 0.2 min ...` |
| 9 | `Airborne — flight clock started` (skipped when `require_airborne = false`) |
| 10 | `FAILURE TRIGGERED on engine 1 after 0.2 min of flight` |
| 11 | `Clamp applied on engine 1` — **once**, not per frame |
| 12 | `history += C172/early/heavy outcome=fired` |

With the bench config's `clean_flight_chance = 0.0`, line 6 should read
`9 cards`→`6 cards (6 failure, 0 clean = 0% clean)`.

### Red flags

| Log line | Meaning |
| --- | --- |
| `FATAL — could not load module` | The `Modules\reo_*.lua` files aren't deployed. Re-run `deploy.bat`. |
| `attempt to index a nil value` / `attempt to call a nil value` | A bug in the module split — note the file and line, that's the whole diagnosis. |
| `ImGui not available in this FlyWithLua build` | Should now be impossible on NG+ 2.8.14. If you see it, `float_wnd_create` went missing. |
| `FAILURE TRIGGERED` within seconds of loading a flight | The re-trigger bug is back. See test 9. |
| `WARNING could not write deck state` / `could not append to history` | File permissions on the Scripts folder. |

---

## Bench tests (on the ramp, engine running, parking brake set)

### 1. Cold load — C172

**Do:** Start X-Plane with the bench config, load a C172 at any airport.
**Pass:**
- A window titled **Random Engine Failure Settings** is visible.
- Status shows a card is armed (with `debug_reveal = true` you'll see the bucket,
  severity, countdown and target engine).
- These two files now exist in the Scripts folder:
  `random_engine_out.state` and `random_engine_out.history.csv`.

Both files being created is the single best signal the whole chain works — the
deck persisted and the history module initialised.

### 2. Ground fire

**Do:** Set ~50% throttle and wait for the countdown.
**Pass:** Power drops on one engine; `FAILURE TRIGGERED` then exactly one
`Clamp applied` line. Red `ENGINE FAILURE ACTIVE: ENGINE n` text appears on screen.
**Watch for:** `Clamp applied` repeating every frame — that would mean
`state.clamp_logged` isn't sticking.

### 3. Good-engine check — BE58 Baron (the important one)

**Do:** With a failure active, sweep **both** throttles full aft then full forward.
**Pass:** The failed engine is capped at its limit and never exceeds it; the
healthy engine tracks your input 1:1 all the way to full power. Pulling the
failed engine *below* its cap must still work — the clamp is a ceiling, not a
setting.

This is the test that caught the original override bug (commit `22e9f45`), so
it's worth doing every time the enforcement loop changes.

### 4. Clear Failure / Reset

**Do:** Click **Clear Failure / Reset**.
**Pass:** Override releases, the previously failed engine responds normally, and
the log shows a fresh `Card drawn`.

### 5. Draw New Scenario Card

**Do:** With a card armed but not fired, click **Draw New Scenario Card**.
**Pass:** Log shows `held-over card X/Y returned to the deck` followed by a new
`Card drawn:` line. The returned card is not lost — total deck count is preserved.

### 6. Disable / Enable

**Do:** Click **Disable (Normal Flight)**, wait past the countdown, then **Enable**.
**Pass:** Status reads `DISABLED (normal flight)`; no failure occurs while
disabled; any active override is released immediately; enabling draws a new card.

### 7. Window lifecycle

**Do:** Click **Hide Window**. Then reopen from FlyWithLua → **Macros** →
*Random Engine Failure Settings*. Then close it with the window's **X** instead.
**Pass:** No crash, no frozen sim, reopens cleanly each time.
**Why it matters:** destroying a window from inside its own ImGui builder is
unsafe; the Hide button defers it by a frame deliberately.

### 8. Held-over card

**Do:** Set `session_minutes = 60`, `require_airborne = false`, reload, and note
the drawn card (e.g. `LATE/TOTAL`, firing at ~50 min). Don't wait for it — load a
new flight.
**Pass:**
- Log: `New flight detected — re-arming for the next one`.
- Log: `Card RE-ARMED (held over): LATE/TOTAL` — **same bucket and severity**,
  but a freshly rolled firing time. The target engine is re-rolled too, so in a
  twin it may differ; in the C172 it is always engine 1, which is not a failure.
- `history.csv` gains exactly one row with `outcome = expired`, whose `notes`
  read `scheduled 50.0 min; flight reached 0.4 min`.
- `random_engine_out.state` still shows `pending_bucket = late`.

The `expired` row and the held-over card must **both** happen. They are not
alternatives: the row records that the flight wasted the card, the pending entry
ensures the deck doesn't lose it.

### 9. Reposition after a fired card ← regression test

A bug found by code reading on 2026-09-21 and fixed before first flight: the
new-flight handler released the trigger but left the card armed with a stale
clock, so a flight following one that had already fired re-fired the failure
within a frame of loading — on the ramp.

**Do:** Bench config. Let the failure fire (test 2). Then load a new flight.
**Pass:** Between `New flight detected` and the next `Card drawn`/`Card RE-ARMED`
there is **no** `FAILURE TRIGGERED` line, and the engine is not clamped while you
sit on the ramp.
**Also check:** `history.csv` has exactly **one** row for that original card
(`outcome = fired`), not two.

### 10. Deadline backstop

**Do:** `session_minutes = 60`, `failure_deadline_minutes = 5`, reload until you
draw a `late` card.
**Pass:** The log reads `fires at 5.0 min` — the late window (0.65–1.00 × 60 min
= 39–60 min) is pulled back to the 5-minute deadline.
**Then:** add `start_delay_minutes = 10` with the deadline still at 5.
**Pass:** `fires at 10.0 min` — the quiet period wins the conflict, by design.

### 11. Clean card

**Do:** `clean_flight_chance = 0.5`, reload until `Card drawn: CLEAN`.
**Pass:** No failure that flight; one `history.csv` row with `outcome = clean`
and an empty `engine`/`severity`.

### 12. History file integrity

**Do:** Accumulate a handful of events, then open `random_engine_out.history.csv`
in Excel.
**Pass:** Header row plus one row per event; columns line up; `icao` reads `C172`
/ `BE58`; `engine` is 1-based (matching the log and the GUI, not the 0-based
dataref); `grade` reads `unscored`; the grading columns are empty.
**Watch for:** any row where a value has shifted a column — that means a comma
got through `csv_field()`.

### 13. Deck reset isolation

**Do:** Delete `random_engine_out.state`. Reload.
**Pass:** Log says `no saved deck state — starting a fresh deck`, and
`history.csv` is **untouched** — same row count as before. Your training record
must survive a deck reshuffle.

### 16. Disable on a clean card ← regression test

A crash found by code reading on 2026-09-21 and fixed before first flight. A
clean card's event carries `scenario = ""`, and because the empty string is
truthy in Lua it slipped past the `or "engine_out"` fallback in
`current_scenario()`, which then returned `nil` and was indexed.

**Do:** Set `clean_flight_chance = 0.8` (the maximum) and reload until the log
reads `Card drawn: CLEAN`. Then click **Disable (Normal Flight)**.
**Pass:** Status switches to `DISABLED (normal flight)`, the log shows
`disabled (normal flight — no failure will occur)`, and there is **no**
`attempt to index a nil value` anywhere in `Log.txt`.
**Then:** click **Enable (Arm Failure)** and confirm a fresh card is drawn.

---

## Flight tests

Restore the real config first. These are the ones that tell you whether the
thing is actually useful, rather than merely working.

### 14. C172 — 25-minute block

```cmd
set FAILURE_DEADLINE=18
tools\practice-launch.bat armed 0 25
```

**Fly:** A normal circuit or a departure to the practice area.
**Pass:** The failure arrives at a plausible point in the flight, the aircraft
remains flyable, and you can run the checklist against it. Afterwards the log
should show the card firing within your actual airborne time, and `history.csv`
should have an `outcome = fired` row with a sensible `fired_at_min`.
**Note:** with `session_minutes = 25` and a real 15–18 min airborne time, the
`failure_deadline_minutes = 18` is doing the work here. Without it, late cards
land past your landing.

### 15. BE58 Baron — asymmetric

**Fly:** Same, in the twin.
**Pass:** The log names which engine failed; confirm that's the one that actually
lost power, and that the live engine stays fully controllable. Fly it as a real
engine-out: identify, verify, blue line, secure.
**Worth noting for yourself:** whether you reached for the correct engine first.
Phase 3 will measure that automatically (`correct_engine`), and it's the metric
most worth having in a twin.

---

## Pilot notes

- **`Log.txt` is a full spoiler.** It logs the drawn card, its target time and the
  target engine at draw time. Read it after landing, or treat a session as
  debugging rather than practice.
- **`history.csv` is spoiler-free** — it only records what already resolved. Safe
  to open any time, including mid-session.
- **`debug_reveal = true` is for testing only.** It puts the countdown and target
  engine in the GUI, which removes the entire point of the deck.

## Known quirks — not bugs, don't chase them

- Each manual **Draw New Scenario Card** increments the GUI's "Flights flown"
  counter. Rapid reroll testing inflates it.
- A manually rerolled card that was armed leaves **no** history row. The card
  goes back into the deck, so nothing is lost — it just isn't training data.
- Rapid reroll testing legitimately piles up `clean` rows.
- If FlyWithLua reloads all scripts mid-flight with a card still armed, no
  `expired` row is written — the Lua state is destroyed first. The card itself
  survives in `.state`.

## Unconfirmed details — verify on first run

- `float_wnd_create(340, 320, 1, true)` passes decoration `1`. The function
  exists in `FlyWithLua.xpl`, but that argument's visual meaning was never
  confirmed. If the window looks wrong (no title bar, odd chrome, wrong size),
  that argument is the first thing to change.
- `do_sometimes`' cadence is believed to be ~10 s but wasn't verifiable from the
  local docs. It bounds how long the gap in test 9 lasts, so read it off the
  first run's log timestamps.
