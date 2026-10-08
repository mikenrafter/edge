# Lexicon

Domain terms used in code, docs and UI. Names in code follow these. Add a term
in the same change that introduces it (AGENTS.md §6).

## Time
- **Instant** — a moment in time, stored as a UTC epoch (`…Ms` / `…Sec`).
- **Offset** — minutes east of UTC in force at an instant (`…_offset_min`); NULL when unknown.
- **Zone** — an IANA time zone id (e.g. `America/Denver`); finds DST midnights, unlike an offset.
- **Zone span** — a stretch of time during which the phone was in one zone (`zone_span`).
- **Day / day label** — the wearer's local calendar date `YYYY-MM-DD`; produced only by `data/day_label.dart`.
- **Day cut** — the persisted start/end instants of one day label (`day_cut`).
- **Wall time** — a recurring clock time without a date (alarm 07:00, bedtime 23:00).
- **Strap clock** — the band's RTC seconds; converted to instants only via `ClockRef`.
- **Monotonic time** — elapsed time for deadlines and timeouts (`Stopwatch`), never stored.

## Data
- **Raw record** — bytes from the band as received (`raw_records`, `raw_archive`).
- **Decoded row** — one decoded 1 Hz sample (`decoded_onehz`) or beat (`decoded_rr`).
- **Derivation** — turning decoded rows into day results and metric series.
- **Day result** — the versioned per-day output (`day_result`, PK day + algo version).
- **Provisional / finalized (frozen)** — a day result that may still be replaced / one that only a new algo version, a user override or a value-identical re-encode may touch.
- **Artifact** — a persisted derived result other than a day result, keyed by kind + scope + algo version + input revision (design 02).
- **Input revision** — a counter that changes whenever a day's inputs change.
- **Heavy** — work whose cost grows with stored data; runs only on a worker isolate (`@heavy`).
- **Live** — bounded per-packet or per-sample work allowed on the UI isolate (`@live`).

## Gestures, marks and journal
- **Gesture** — a recognised tap or motion pattern on the band.
- **Slot** — a gesture position the user binds an action to.
- **Rule** — a mapping from a gesture slot (and conditions) to an action.
- **Cue** — haptic feedback the band plays to acknowledge or prompt.
- **Mark / moment** — a timestamped point the user marked with a gesture, answered later in the follow-up.
- **Follow-up** — the screen where marked moments are answered.
- **Moment review** — deciding pending moments, queued until Save.
- **Range** — a moment pair with a start and an end (nap, workout).
- **Journal day** — the per-day journal record (tags, note, metrics); written only through its owner module.
- **Assumed water** — a glass the app assumes and the user keeps or removes.
- **Symptom** — a journal entry with severity, kind, area and side.

## Charts
- **Annotation** — an icon plus a dashed line (point) or a shaded span (range) drawn on a chart.
- **Cluster** — overlapping annotations drawn as `+n`; tapping steps through them.
- **Algo mark** — an annotation where the algorithm version changed; never clustered.

## Haptics
- **Band command** — one write to the band (a phrase of effects and its loop, after a wait). A pattern is sent as one or more; the budget (the command limit per 2 minutes) counts them. Chosen once, in `haptics/haptic_player.dart`.
- **Pulse** — a run of adjacent notes in a pattern: what one tap is, and the unit a band command plays.
- **Score** — a pattern drawn as music on a three-line staff in 4/4; its notes are coloured by the band command that plays them.

## Spectral archive (experimental)
- **Part** — one append-only encoded chunk of the spectral archive.
- **Pyramid** — the per-minute summary levels kept for a signal.

## ECG
- **Attempt** — one terminal of an ECG capture that was saved as its own reading: not readable, inconclusive or a result. Nothing is deleted when a retake follows.
- **Attempt group** — the attempts of one sitting: a reading joins the latest group when that group's latest attempt is non-final and the new one starts within 10 minutes after it ended (`attempt_group`, `attempt`).
- **Superseded** — an attempt a later attempt of its group replaced (`superseded_by`); hidden from the history list, kept for Details and exports.
- **ECG outcome** — what a saved reading is allowed to say, decided only by `ecgOutcome`: a band-reported rhythm, inconclusive, not readable, or partial. The band's own bytes (result code, average heart rate, reason mask) stay stored untouched.
