# Settings and Health reorganisation — plan (2026-10-03)

Status: agreed (see Decisions), not started. Built from two read-only sweeps of the app on
branch `ecg-taps-one-clock` (after 8AB/8AC). Line numbers are from that sweep and
will drift; symbol names won't.

Open questions for the user are marked **Q**.

---

## Part 1 — Settings

### What is wrong today
- **Buzz settings are scattered.** Buzz-pattern rows in four places
  (Notifications per alert, Band notifications per channel and per app, Alarm —
  where the row is permanently disabled, `alarm.dart:652`); a second rhythm system
  ("Fallback rhythm", `band_notifications.dart:263`); HR zone alert under The band
  with no pattern; "Buzz the band" in device Tools; the shortcut buzz token in
  Automation; probes in Device lab.
- **Duplicates.** Band notifications has two entrances (Settings › The band
  `settings.dart:672` and Notifications › Android Relay `:1282`); quiet hours exist
  globally (`settings.dart:1295`) and per relay channel
  (`band_notifications.dart:295`); Touch windows / pause between double taps in both
  Gestures and Device lab; Expected sleep schedule in Preferences and Alarm › Wake;
  Storage on Profile while Data is in Settings; Language on Profile while Units and
  Appearance are in Preferences.
- **Naming.** "Android Relay" / "Relay" / "Relay to the band" / "Buzz on app
  notifications" for one feature; "Band alerts" (battery) vs "Band notifications"
  (relay); "Haptics" vs "Buzz pattern" vs "Extended haptics opset"; several labels
  not localised.
- **Depth.** Pattern probe = 5 taps deep at the bottom of a long page; a
  notification's buzz pattern = 5–6 taps.
- **Lab items in user pages.** Device lab is behind a feature flag on the band's
  device page, not dev mode; Gestures shows draft tap counts and threshold
  adjusters; Live devices sits in Profile › Quick access.
- **8AC gap.** Neither caller of the buzz editor passes the band profile, so the
  notes / "what the band plays" preview never shows (fixed in 8AC phase G).

### Option A — one Haptics hub (do in 8AD)
New **Haptics** row in Settings › The band, beside Alarm, Band notifications and
Gestures:
- **Patterns** — the named pattern store. Each pattern: name, notes (the
  intermediate representation), pre-baked plan, extended-opset flag. Actions:
  Record new (tap sequence, the simple editor), Advanced editor (notes; Play plays
  the user's notes), rename, delete, preview.
- **Safety** — "Allow long sequences" (off; caption "May cause harm to your
  device, use at your own risk"; lifts the 10 s runtime cap); a read-out of the
  30 commands / 2 min limit and the global band queue.
- **Test** — Buzz the band; preview any pattern.
- **Calibration** (dev mode only) — pattern / buzz / ECG probes, Copy all logs.

Every buzz-pattern row elsewhere (Notifications, Band notifications per channel
and per app, Alarm — which gets a working row, Fallback rhythm) becomes a
**picker** from the store with "Record new…" at the bottom. The probe drops to
3 taps.

### Option B — regroup Settings by task (own phase, 8AE, after A)
Top level:
1. **Band** — device and connection, Alarm, Gestures, Haptics.
2. **Alerts** — everything that notifies you on one screen: today's Notifications
   list + HR zone alert + app relay folded in as one group under one name ("App
   notifications on the band"); ONE global quiet hours (per-channel override as an
   advanced option, **Q** or drop it).
3. **You & preferences** — profile, units, appearance, language, sleep schedule
   (once), cycle tracking.
4. **Data & privacy** — export / backup / import, health write, contribute data,
   crash reports, barcode lookup, storage.
5. **Connections** — AI coach, automation (incl. shortcut buzz token), updates.
6. **Developer** (dev mode) — gallery, Live devices, Device lab (Gestures' draft
   adjusters move here), calibration probes.

Cost: many settings/device-page tests pin these rows; mostly moves and renames —
review separately from logic. Update `docs/navigation-depth.md`.

**Q:** Device lab behind dev mode, or keep it reachable from the band page for
tap testers? **Q:** per-channel quiet hours — keep as an override or remove?

---

## Part 2 — Health tab

Today: Health (`ui2/screens/health_screen.dart`) = one list with five sub-tabs:
Overview · Explore · Trends · Vitals · Labs. Other tabs: Home · Nutrition ·
Workout · Wellness (Profile and Coach are buttons on Home).

### What is wrong today
1. **No door to readiness/recovery** in Health (`ReadinessDetail` only from Home);
   **strain**'s rich `DayStrainDetail` only from Home and Workout.
2. **Sleep detail is buried**: Health → metric → scrub the chart → tap the day
   card (3+ taps and a gesture). Home's ring and Wellness → Recovery get there in
   1–2. Stale comment "Sleep is a tab of its own" (`health_screen.dart:1214`).
3. **Stress missing from Explore** although a comment says it's there; only via
   the Overview row.
4. **Skin temperature**: listed under "each one opens its chart" but its spec is
   suppressed ("Not shown as a trend"); shown three different ways (SD in Vitals,
   unlabelled "Temp" in SleepDetail, a third quantity in scrub).
5. **SpO2 absent on purpose** — no explanation where a user would look.
6. **Vitals rows lead nowhere** (heart rate, resp rate no onTap); HRV deep dive
   goes to `Investigate`, while other HRV paths go to `MetricDetail` — two HRV
   "details".
7. **Duplicates (AGENTS.md §4.10)**: HRV ×4 (Overview, Trends, Vitals, Explore);
   RHR and Sleep ×3; resp rate ×2; stress on Health and Wellness → Mind; the
   illness card on Home and Health with different advice text.
8. **Name drift**: "Heart rate · Resting" vs "Resting heart rate"; Vitals' "Heart
   rate" means the day's range; "Sleep" vs "Time asleep"; "Daytime sleep" vs
   "Naps".
9. **Mixed time scopes on one screen**: Overview = last night with 24-point
   sparklines; Trends = 30-day chart vs ≤28-day mean (sleep switches to "vs
   need"); Vitals = one chosen day except skin temp's own night; MetricDetail
   opens on Today even from a 30-day Trends card.
10. **Order/length**: Explore ≈ 25 rows; Labs fifth and clipped at 390 pt;
    Naps (a correction tool) is a permanent Overview section.
11. **Absent-data oddities (§4.1), to fix regardless**: sparklines drawn for a
    night held over from an earlier date; gap cards with an empty reason when a
    stress reading is missing on a night that had sleep; a Trends delta drawn
    against a "1-day average".

### Option H1 — tidy within the current sub-tabs (small)
- Overview: add Readiness and Strain rows (open `ReadinessDetail` /
  `DayStrainDetail`); Sleep row opens `SleepDetail` for last night directly
  (chart one tap further); move Naps into Sleep detail ("Daytime sleep").
- Explore: add Stress; drop or relabel Skin temp ("nightly deviation, no trend
  yet"); a one-line "Why no SpO2" note in Breathing.
- Vitals: every row tappable (→ the same `MetricDetail`); HRV deep dive goes to
  `MetricDetail('hrv')` with Investigate one tap further (one HRV detail).
- MetricDetail opened from a Trends card starts on 30 d.
- Names: one name per metric across tabs (a shared label table); one illness
  card text.
- Fix the three §4.1 oddities.

### Option H2 — organise by question, not by view (recommended, bigger)
Replace Overview/Explore/Trends/Vitals with four sub-tabs, each one time scope:
1. **Last night** — Readiness, Sleep (→ SleepDetail), HRV, RHR, resp rate,
   overnight stress, skin temp deviation, observations/illness. One night, no
   sparklines.
2. **Today** — strain (→ DayStrainDetail), steps, active minutes, calories, heart
   rate range, wear.
3. **Trends** — every metric with a history in one searchable list grouped by
   family (today's Explore), each opening MetricDetail on 30 d; Body clock and
   Consistency at the top.
4. **Labs** — unchanged, but no longer clipped (four tabs fit at 390 pt).
Each value appears once per scope; Home keeps its ring trio as the summary, and
Wellness → Recovery links into Health › Last night instead of a second
readiness/sleep hub. Cost: heavy test churn in `health_screen` and proof views;
do after Settings B.

**Q:** H1 now and H2 later, or go straight to H2? **Q:** should Wellness →
Recovery keep its own content or become a link?

---

## Decisions (user, 2026-10-03)
- Option A folds into 8AD. Option B is next after it ("I like the dev area
  category"): the Developer group is the dev area.
- Device lab goes behind dev mode (Developer group), off the band page.
- Per-channel quiet hours stay, but each channel gets a toggle "Override quiet
  hours" (default off = follows the global quiet hours); the channel's own
  Starts/Ends only show and apply while the override is on.
- Health: go with the recommendations ("the rest … sounds like a great next
  step"): H2 (Last night · Today · Trends · Labs), Wellness → Recovery becomes a
  link into Health › Last night (confirmed). Straight to H2. The §4.1 oddities are fixed in the same phase.

## Part 3 — Gesture practice tour (8AG)
User: "give them a little guided tour that shows them the tap/release/hold that
the ECG tester does. Much of that can be abstracted and reused. Generalize it to
also handle double tap chains. Let them practice it a few times. Have them set a
goal of 2, 4 or 6 times in a row and keep them on that page until they hit the
goal. The back button should still be visible, but add a coy-phrased
confirmation dialog to it."
- Extract the ECG touch probe's cue sequence (touch / hold / lift with timing
  windows and live feedback) into a reusable `GestureDrill` model: a list of cued
  steps (press, hold for N ms, release, pause) + a checker fed by the same
  classifier events the app uses (ECG contact mask for sensor touches; band
  double-tap events for tap chains, incl. chains of 2–5 double taps).
- A practice page reachable from Settings › Band › Gestures ("Practice"):
  pick a gesture (ECG touch count, double-tap chain length), pick a goal (2, 4 or
  6 in a row; chips), then cued attempts with a streak counter; a miss resets the
  streak and says what was off (too short a hold, gap too long, …). The page stays
  until the streak reaches the goal (then a done state + "Practice again").
- Back stays visible; before the goal it asks with a light, coy confirmation
  (e.g. "Leaving so soon? You're N away from your streak." — Keep practicing /
  Leave). System back and the app-bar back both go through it.
- Reuse: the ECG touch probe in the dev area uses the same drill model.

## Sequencing
1. 8AC (haptics compiler, pre-bake, global queue) — done (7adc86e5).
2. 8AD — done (260feba0). Haptics hub (Settings Option A) + pattern store + advanced editor +
   allow-long-sequences + tap-a-baseline in probes + multi-log vocabulary.
3. 8AE — done (4c5ab83e). Settings Option B (dev area; Device lab behind dev mode; quiet-hours
   override toggle).
3b. 8AE.5 — done (680990ae, 6b88ee65, 4ee13ef1, 0506e84f). Structural cleanup before H2 (user: "just before H2 is a good
   time"):
   - Extract a `HapticsService` from AppState (band queue, ledger, profile,
     `_runBandJob`/`_deliverBandSequence`, ended-event signal, pattern store);
     AppState composes it. Replace the source-reading guards that exist only
     because AppState can't be built in tests with behaviour tests against fakes.
   - One typed settings repository (sections for alert prefs, relay channels,
     patterns, app prefs) with a single save path, so pattern propagation is one
     write instead of three.
   - A single Capabilities lookup for visibility/availability (agreed): one
     object computed from platform, band generation/firmware, hardware, flags,
     dev mode, permissions and connection; `caps.of(Feature.x)` → available /
     hidden / disabled(reason); screens stop re-deriving gates.
   - Goldens: keep pixel goldens for painters and a few showcase screens; move
     ordinary settings/list screens to structural tests (finders, semantics,
     no-overflow at 360×640 and 390×844); light+dark at 1x for screens, 2x only
     for painters; CI uploads failure diffs; regeneration commits list fixtures +
     why. (Alchemist moved to H3.)
4. 8AF — done (ab9bad7e; review fixes 0049cfb4 after 8AE, 302f9293 after H2). Health H2.
   External review: GPT 6.1 Sol (`codex exec review -m gpt-6.1-sol --base main`)
   after 8AE (end of the 8-series work) and again after 8AF; take its pointers.
   STOP after 8AF (incl. its codex review): defer for manual on-device
   testing. Do not start H3 or 8AG until the user says.
4b. H3 (separate branch, later, only when the user asks) — trial alchemist
   on the painter goldens (labelled scenario grids; real-font platform goldens
   locally + Ahem CI goldens), then decide on a wider move.
   Also in H3: generate the README screenshots (screenshots/*.png, hand-made and
   stale since 2026-07-12) from the proof capture (`make proof` /
   EDGE_PROOF_DIR) with real fonts at fixed device sizes, via one script/make
   target, so they track the current UI (Health tabs, Settings, Haptics hub);
   update the README table to the current screens.
5. 8AG — Gesture practice tour (could go before 8AF; it lands in Settings ›
   Band › Gestures from 8AE).
