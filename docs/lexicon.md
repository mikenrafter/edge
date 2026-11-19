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
- **Certified target** — the one official release (tag plus peeled commit) whose own code the export was proven against; not "latest".
- **Compatibility profile** — the frozen table/column/merge-key policy for turning this app's data into a certified target's database (`data/official_export/profile*.dart`).
- **Carried prune cursor** — the recomputed `decoded_pruned_before` row the official file carries: the first local midnight at or after the oldest exact second it holds, never above the fork's own cursor.
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
- **Hover highlight** — a translucent tint and glow painted by a guide target's own component layer. Its opacity follows the moving fingertip's distance; scrolling and stretch carry it with the target.
- **Moving hand** — the guide's pointing cursor, which taps a single target repeatedly or travels through a multi-target step's choices. Reduced motion uses the static label hand.

- **Unscoped guide content**: a page-wide selector, such as every pressable row. It does not identify a particular control on a neighbouring step.

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

## Pulse episodes (`pulse_ep_*`)

- **Pulse episode**: a reviewable stretch of unusual beat timing from one source,
  made of two or more consecutive closed, qualifying five-minute windows. Its id
  comes from the source and its seed window, never from the detector version, so
  an extension keeps it.
- **Qualifying window**: a closed UTC five-minute window whose recording support is
  complete and whose beats pass the fixed floors (SD1/SD2 and pNN70 over enough
  adjacent pairs, coverage, gap and cleaning limits). A pending or refused window
  never votes.
- **Window support summary**: a compact comparison of a closed window with the
  same detector run on captured pre-upgrade record identities. It records whether
  each qualifies and how many novel record keys support the full window. Two
  consecutive newly qualifying windows authorize new debt; an interior fill can
  qualify even when the closing record key was already captured.
- **Evidence revision**: one stored version of an episode's recording (the
  compressed, checksummed beat evidence plus its header). Only the current and
  the actually delivered revisions keep their blob.
- **Delivery root**: the one `pulse_ep_outbox` row per episode that owns its alert
  debt and outcome. A consumed state (sent, in a summary, unknown, before this
  version, deleted) is never replayed.
- **Delivery recording checksum**: the content identity attached to an outbox
  revision. A divergent imported consumed outcome retains its own checksum and a
  conflict reason, so local evidence cannot be presented as its handed-off bytes.
- **Retained range**: the part of an episode's recording that the evidence blob
  really holds; what it does not hold is declared as omitted ranges.
- **Upgrade record membership**: the exact `(source, record second)` keys present
  when the Pulse tables were created, in `pulse_ep_upgrade_record`. It classifies
  an episode as "before this version"; it is identity, not a time cutoff, so an
  older record that arrives later is still new.
- **Admission batch**: the bounded provenance of ONE committed source range
  (`pulse_ep_admission`): how many pulse-bearing records it held, how many were
  new by `(device, record)` identity, and its origin. It is consumed by
  evaluation and pruned with decoded retention; it is not a per-record ledger.
- **Consumed tombstone**: what is left of an episode after its recording is
  deleted: its id, status `deleted` and a consumed delivery state, with no RR or
  heart-rate value, so a re-imported recording cannot alert again.

## Guides
- **Accordion hop**: a user tap that expands the outermost closed section containing the pending guide target. Nested closed sections each add one hop.


## Interactive calculation

- **Sleep edit receipt**: the committed sleep assertion, its revision and its dirty job, stored atomically by `SleepEditStore`. It acknowledges saved times, not finished measurements.
- **Sleep edit job**: durable remaining work for one edited night. The latest revision replaces queued intent; the edited night publishes before dependent days. A run refused because an earlier night changed is requeued; failed work retains the assertion and is retried with a backoff or by the user's Retry.
- **Sleep edit fence**: the sum of the revisions of one night and every earlier night. A write prepared at an older fence is refused; an edit to a later night does not move it.
- **Selected pass result**: the outcome of one `runDays` invocation, owned by the engine. It stays incomplete when that invocation was refused, regardless of another pass’s diagnostics.
- **Sleep edit status**: the typed `SleepEditView` attached to affected reads. It separates unapplied own measurements from outstanding dependent work; queued and failed edits remain visible between worker runs.
- **Sleep receipt failure**: a night and operation-specific failed save retained by `SleepCoordinator` until acknowledged or superseded by a later successful save. App-level presentation survives route disposal.
- **Withheld night**: while a night's own edit is unapplied, only its sleep-derived numbers are withheld. Its other measurements, and every later day, keep their values; later days carry a `sleep_edit` mark.
- **Load timing**: an opt-in (Developer, off by default), bounded local diagnostic sample identifying a stored read, reader acquisition, writer queue, transaction or decode span. Elapsed parallel reads overlap and are never summed into load time.

- **Alert release class**: what happens when interruption is blocked. Durable
  debt remains eligible for retry; a recurring slot is skipped; wake alerts and
  explicitly user-scheduled reminders always pass quiet and sleep checks.
- **Fallback destination**: the user's global alternate alert destination when
  the selected destination cannot execute. Defaults to phone. Hardware and
  interruption restrictions still apply.

- **Session cue**: a buzz the wearer requested directly or within an active
  session, including test/preview/find-band buzzes, Device lab probes, ECG,
  gesture acknowledgements and breathing cues. Quiet hours and sleep do not
  hold these cues, and rejected cues take no alert fallback.

## Sleep ownership

- **Sleep block**: an interval of main sleep or a nap the wearer can act on, stored with a stable id in `sleep_block`.
- **Owner rule**: the integer version of the rule that assigned a block’s owner day. `0` preserves a legacy stored label; `1` uses the caller’s main day or a nap’s local start date. Stored blocks retain their rule when read or encoded.
- **Owner day**: the local day label that owns a block. Main sleep keeps the caller's day; a new nap uses `SleepOwnership.dayOf`.
- **Projection**: legacy `sleep_nap` and `sleep_override` rows written from sleep blocks for existing readers and exports.
- **Absorb**: turn legacy sleep rows into blocks while retaining their stored owner days.
- **Range read**: `SleepBlockStore.live`, the sleep blocks that count as sleep and intersect an interval.
- **Nap work**: the `nap_revision` / `nap_applied_revision` counter pair on the day's single sleep job. It requests nap recomposition without moving the night revision fence or withholding the night.
- **Nap recomposition**: `LocalDb.recomposeNaps` applies block assertions to retained day output, preserving measured night values and refreshing nap totals and the cross-day input revision.

- **Certified target**: the exact official release tag and peeled source commit whose receiver was exercised by the export proof. Defined by `data/official_export/profile.dart`.
- **Compatibility profile**: reviewed source-table, column and value dispositions for that certified target. Owned by `data/official_export/profile_tables.dart`.
- **Snapshot receipt**: capture start/end instants, schema, immutable SQL content hash and independently omitted extras. Owned by `data/official_export/session.dart`.
- **Recovery file**: an optional OSBK-encrypted copy of the same frozen fork SQL and supported extras, including data the certified target cannot use. Owned by `OfficialExportCoordinator`.
