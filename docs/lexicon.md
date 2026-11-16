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
- **Older-version fallback** — the read seam serving an older algo version's stored value for a day when the current version's row has none, always labelled (`from_older_version`: version + why the current one is missing; `Metric.fromOlderVersion`). The value is the stored one, never recomputed.
- **Profile-owed day** — a day whose metric abstained for a missing profile field (`need_input:name=age|sex|height_cm|weight_kg`); held unfinalized with its raw (`profile_repass:<day>`) until the field is supplied or the raw-hold window passes.
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
- **Cluster** — overlapping annotations sharing an icon and a `+n` count; tapping steps through their labels. Thin events retain their first and last time positions with shading between them. Duration ranges retain their edges, with at most one extra line on either side.
- **Main sleep** — the night's annotation on the day chart (`AnnotationKind.mainSleep`): the longest valid sleep entry of the day, a range from onset to wake. It has priority: never in a `+n`, the last icon given up, and its label is the chart's default label while nothing is focused. A nap is not main sleep.
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

## Layout shift

- **Pending content**: the layout reserved for a read that has not returned. It paints bars and neutral plots, excludes values from accessibility and disables actions. It becomes explicit absence or a retry state when the read settles without data.
- **Layout shift** — content moving, resizing, recolouring or being covered after it was painted; scored by `lib/layout_shift` (docs/LAYOUT_SHIFT.md).
- **Interaction window** — the time after a user action in which a shift is expected and costs less.
- **Intent pair** — an action's source element and the element it is meant to change (copy button → copied text).
- **Animation chain** — animation spans sharing a chain id, played back to back to hold attention instead of a delay.
- **Settle time** — ms from an interaction until the screen last changed (move, resize, recolour, appear, disappear); scored as load time. Still changing when observation ends = unsettled, full cost.
- **Flashbang** — a bright frame before the app's own background; the launch window is never brighter than #222.

## Wake journal

- **Wake epoch**: the absolute alarm occurrence, stored as epoch seconds. It groups the observed events for one wake, including early Natural and Gradual delivery.
- **Wake journal**: durable wake events, answers and tuning history in `wake_trace`. `DbWakeJournal` owns answer writes and outcome reads. `DbSnoozeStore` atomically writes pending snooze state with its journal transition. Journal-bearing kinds survive diagnostic pruning and backup restore; foreign run state stays excluded.
- **Observed night**: `WakeNightTimeline`, the ordered events for one wake epoch. The planned `WakeTimeline` remains the alarm schedule. Non-firing decisions, armed status and failed deliveries do not establish an observed fire.
- **Time to wake**: elapsed time from the first observed Natural, Gradual or backup fire to the first "I'm up" acknowledgement. Missing bounds or an acknowledgement before the fire leave it unknown.
- **Snooze transition**: a snooze with its original wake epoch, event time and count, or a terminal `snooze_stop`. Stop reasons are `dismissed`, `im_up`, `limit` at the three-hour scheduling bound, and `timeout` for an expired chain, including one found on restart.
- **Dream response**: the wearer's `dream` or `normal` answer on the wake's first acknowledgement. Its preceding wake path has priority Natural, then delivered Gradual, then backup alarm. Skip writes nothing; an unknown path stays absent.
- **Wake outcome**: the observed interval, snooze count and optional dream response joined to the matching canonical main-sleep day. Recovery comes from that day's readiness; main-sleep TST comes only from sleep accounting. Missing values stay absent.
- **Natural wake tuning**: a product policy that adjusts the stable-run trigger offset and window lead once per canonical sleep night after seven complete nights. `DbWakeJournal` owns durable parameters and atomically records each applied change with a reason. Dream context weights Natural answers at 1 and other wake paths at .25; it is not stage accuracy. Alcohol nights are excluded, while cannabis alone does not exclude a night.

- **Wake-up group**: one wake epoch shown as a collapsed row, with its observed clock span and time to wake. Opening it shows one row per kind; Natural repeats and snoozes carry counts at their first delivery. Raw journal events stay intact.
- **Wake-up zoom**: the optional sleep-chart view of a dense end-of-night wake cluster. It labels both window bounds and changes only the displayed time window. The preference defaults on and is owned by `Prefs`.

## Sleep staging

- **Experimental sleep staging (HMM)**: the opt-in offline hidden Markov model identified as `StagingMethod.hmm628`. It estimates wake, light, deep and REM from measured epochs, preserves unobserved gaps and never supplies Natural wake decisions. It is not validated against polysomnography and is not a medical device.
- **Measured nightly baselines**: `hr_min_night`, the upstream 10th-percentile HR order statistic, and `rmssd_mean_night`, the mean measured epoch RMSSD, within the first 120 elapsed minutes of the selected session. Analytics owns their calculation for every staging method; absent measurements stay null.

## Live wake evidence

- **Wake evidence**: timestamped HR and movement summaries calculated by analytics. Insufficient measurements remain absent and cannot approve autonomous early delivery.
- **Confounder profile**: Edge's journal-derived thresholds for one sleep occurrence. Presets combine by maximum thresholds and durations, minimum movement ceilings, and shared condition flags.
- **Wake night context**: the journal profile cached by `WakeNightContext` for one occurrence, saved schedule and journal revision. Read failures return default policy with neutral diagnostics.

- **Natural learning track**: bounded Natural wake parameters learned only from
  nights with the same recorded active confounder set. Track 0 is clean; other
  preset sets use stable bit-set numbers. User sets also include sorted track
  identities. Each track needs seven complete nights; user tracks first observe
  for at least 28 days and cannot borrow nights from a different active set.
  Unknown journal context never trains a track. Alcohol intake changes learning
  context even when it precedes the live detector's late-intake cutoff.
- **Water moment**: one explicitly logged glass with its own identifier, local
  date and clock minute. Two glasses in one minute remain two moments. A daily
  water total is an aggregate and does not establish a glass's timestamp.
- **Reminder sleep eligibility**: the shared decision for a reminder's target
  instant, checked against quiet hours, expected sleep and recorded sleep.
  Suppression diagnostics use that order when causes overlap. Interval starts
  are included and ends are excluded. Missing evidence remains unknown.

## Typical day

- **Typical day**: the local 24-hour view of the existing alertness forecast,
  saved quiet and sleep windows, and the wearer's optional large-meal times.
- **First recorded caffeine**: the earliest explicitly timed caffeine moment
  inside an observed wake-to-next-sleep interval. A daily total's latest clock
  time does not establish it.
- **Bedtime caffeine residual**: the modeled remaining mg from explicit timed
  doses at the next observed sleep onset, using a fixed five-hour half-life.
  Incomplete amounts remain unknown.

- **Meal candidate**: an unvalidated awake, low-motion HR-rise interval offered
  in Review activities. Only the wearer's confirmation creates a meal moment;
  a candidate never supplies food amounts or nutrition.

## Tracks

- **Track**: an editable activity, consumed substance or condition definition,
  with roles, affected systems, optional kinetics and logging history.
- **Sub-activity**: a named variant within a track, with optional kinetics
  overrides. Variants share the track's learning.
- **Track event**: a recorded occurrence with an optional amount and instant.
  Existing workout, medication, nutrition and moment records keep their own
  owners; the Tracks feed reads them without copying them.
- **Setup history**: inclusive local date ranges when the wearer did or did not
  do an activity. No unadjusted data means that track state is their baseline.
- **Kinetics lock**: a per-field choice that prevents automatic learning from
  changing that value. Unknown values remain absent.

- **Matched night**: a comparison with similar bedtime, sleep debt, load,
  weekday and prior rolling baseline, with known logging and enough recording
  coverage. An association that cannot separate overlapping tracks stays absent.
- **Learning period**: the global observation floor followed by each field's
  kinetics-derived gate. Period adjustments and kinetic steps are bounded and
  recorded in the learning audit.

## Guides
- **Navigation node** — a declared shell tab, sub-tab, page or sub-page, present even while its content loads. Guide steps name their node in `guide_navigation.dart`.
- **Hop** — one real navigation action towards a step: Back, a shell tab, a sub-tab, or a page entry. Virtual grouping nodes do not add a hop.
- **Layout sibling** — the previous or next unit in the target's enclosing vertical layout; transforms and viewport clipping do not change this relation.
- **Placeholder** — replacement text bars or a muted plot sine, painted without replacing its existing surface. Icons, images and card titles keep their source paint.

## Pulse flag delivery

- **Processing origin**: immutable provenance on a derive job: recent band sync,
  historical import/backfill, or reanalysis. It controls pulse alert eligibility
  and never changes the analytics result.
- **Pulse arrival budget**: at most 36 hours between a pulse record's timestamp
  and its first arrival. A new daily flag can interrupt only for a newly inserted
  pulse record within this budget. Eligibility expires 36 hours after arrival;
  independent of when a delayed derive job runs.
- **Daily pulse flag**: a stored day-level irregularity-rule result. It supplies
  no episode start, end, or diagnosis. Its data-sufficiency value is a heuristic,
  not the probability of atrial fibrillation.
- **Pulse history revision**: install-local delivery metadata in
  `compute_freshness`, incremented before imports or restores change history.
  A queued or running context from an earlier revision cannot interrupt. This
  metadata is excluded from restore, and does not version analytics output.
  Schema 87 also carries legacy medical claims for already flagged pulse days
  into their dedicated daily delivery keys.

## Observations

An observation entry is a stored daily detector finding or a pulse episode, shown
by `ui2/observation_history.dart`. An episode replaces daily irregular-pulse flags
on its covered dates. Other finding kinds remain separate. Health shows the
newest entry; the Observations screen shows the entries for the selected day.

## Pulse episodes

A pulse episode is at least two consecutive closed UTC five-minute windows meeting the experimental irregular timing and recording quality rules. Its bounds describe qualifying windows, not proven rhythm onset or offset. Its seed is the first qualifying window; the source and seed identify it across extensions and algorithm revisions. Beat evidence preserves original intervals, cleaning hypotheses and valid adjacency. A delivery claim is a durable per-episode record consumed before OS handoff; ambiguous delivery remains unknown and is never retried. A partial trace explicitly lists omitted recording ranges. Motion and wear remain unknown when no reliable measurement exists.

The **pulse upgrade watermark** is the immutable set of `(source, ts_ms)` RR record keys present during the schema-89 migration, or at the first phase 2 initialization on a fresh install, plus its atomic completion marker. An episode whose beats all belong to those records is marked sent with reason "before this version". The keys survive raw eviction, restore and reanalysis. A previously absent key delivered later is new even when its recording timestamp is older.

- **Pulse breathing pattern**: matching respiratory-band spectral peaks in two adjacent, fully supported windows during confirmed low-heart-rate sleep. Analytics resamples cumulative RR timing and requires both peak concentration and prominence. Matching peaks trigger a narrow sinusoid fit. A window is excluded only when the supported fit leaves original-beat residuals below at least one fixed screening floor. `pulse_episode_worker.dart` supplies context; analytics owns the policy.
- **Pulse personal baseline**: quality-passing normal windows from earlier local dates within fourteen days, excluding stored episodes and their thirty-minute surroundings. Its thresholds cannot suppress uncorrelated windows that pass the fixed screening floors.

- **Pulse semantic exclusion**: positive breathing, motion, off-wrist or charging evidence that excludes an otherwise supported pulse window. Complete exclusions can retract current detector decisions and cancel unclaimed alerts.
- **Pulse recording refusal**: insufficient or invalid RR support. It retains an earlier pulse decision rather than retracting it.

- **Pulse respiratory residual**: corrected RR minus the single fitted respiratory sinusoid evaluated at original cumulative beat times. Original feature and adjacency masks stay intact; the same SD1/SD2 and pNN70 calculation checks the residual against 0.7 and 30%. Weak or failed fits preserve eligibility.
