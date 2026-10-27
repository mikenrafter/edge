# Evidence and limits for the wake port

The experimental offline HMM from #628 and the live legacy Smart Wake gates
from #630 use wrist measurements to estimate sleep or decide whether to buzz
early. Neither has been validated against polysomnography. They cannot identify
deep sleep reliably or promise less grogginess. Cardio remains the default
offline stager. Phase 3 connects the shared evidence only to legacy Smart Wake;
Natural wake integration belongs to phase 4.

## What the research supports

Autonomic activity varies with sleep stage and time within the night. This
supports examining HR and HRV, but does not establish a stage from a fixed HR
rise. See [Trinder et al., 2001](https://pubmed.ncbi.nlm.nih.gov/11903855/).
PPG and accelerometry have supported a separately trained and validated staging
model. That result does not validate this port's hand-set model parameters.
See [Fonseca et al., 2017](https://pubmed.ncbi.nlm.nih.gov/28838130/).

Stage-aware waking does not establish a benefit for alertness. Jewett's study
found no detectable stage-at-awakening effect under its conditions, while
McHill's experiment found greater performance impairment after awakening under
chronic sleep restriction. See [Jewett et al., 1999](https://pubmed.ncbi.nlm.nih.gov/10188130/)
and [McHill et al., 2019](https://pmc.ncbi.nlm.nih.gov/articles/PMC6519907/).
Agreement measured for commercial devices also cannot be transferred to this
algorithm. See [Schyvens et al., 2025](https://doi.org/10.1093/sleepadvances/zpaf021).

Journaled alcohol is a reasonable confounder because nocturnal autonomic
regulation changes with alcohol intake. The observational evidence does not
validate the +6 bpm preset or the alcohol-plus-stress disable rule.
See [Pietilä et al., 2018](https://mental.jmir.org/2018/1/e23/).
Bedtime-relative caffeine timing has experimental support, but the cited trial
used 400 mg, so it does not establish the port's 200 mg threshold.
See [Drake et al., 2013](https://pmc.ncbi.nlm.nih.gov/articles/PMC3805807/).

## Engineering choices in phase 3

Analytics owns the signal calculations in `sleep/wake_evidence.dart`. These
coverage floors and numeric thresholds are engineering choices, not clinical
cutoffs:

- HR baseline first uses the upstream 10th-percentile order statistic in
  `[now-3h, now-3min)`. It needs 30 unique valid samples spanning at least
  30 minutes, with no internal gap over five minutes. HR must be finite and
  strictly between 30 and 200 bpm.
- If that fails, Edge supplies `hr_min_night` from the preceding completed main
  sleep's payload. Selection uses sleep bounds, not a calendar label. Partial,
  skipped, provisional, imported, invalid and unsupported payloads cannot
  supply it. Completion must precede saved expected onset, or `now-3h` when
  no schedule exists, and be within 72 hours of that boundary.
- If both fail, a separate `[now-93min, now-3min)` median needs the same sample
  count and gap limit, with at least a 15-minute span. All layers failing
  means no early delivery. A payload baseline needs no current baseline rows.
- Recent HR and movement use `[now-3min, now)`, with at least 30 unique samples,
  a 90-second span, no internal gap over 60 seconds, and a last measurement
  within 60 seconds of now. Missing measurements remain absent.
- Wake-gate movement is `abs(norm(accel)-1)` in g, preserving #630's meaning
  below 1 g too. It is distinct from rectified ENMO and the stager's movement
  features. Invalid, future and duplicate signal samples cannot add support.
- Trend uses the actual trailing three or five elapsed minutes and compares
  the means of two equal time halves. Each half needs 30 unique samples
  spanning at least half its duration, with internal and boundary gaps no
  greater than 60 seconds. Insufficient evidence vetoes delivery. A rise must
  be strictly greater than `max(0.02g, 0.5 * historical movement median) * factor`.
  An absent movement baseline selects the explicit fixed 0.02 g floor.

Edge owns the journal threshold profile. Its identity and associative,
commutative combine use maximum HR/duration thresholds, minimum movement
ceilings and boolean OR for conditions. Stress or sickness halves the trend
factor once; late meal then multiplies it by 1.5.

| Preset | Effect |
| --- | --- |
| Default | HR +4 bpm, motion below 0.08 g, protection 5 min, trend 3 min, factor 1 |
| Timed alcohol, dose >0 | HR +6, trend 5 min |
| Timed caffeine, dose >=200 mg | HR +6 |
| Stress tag or rating >=4 | Motion below 0.06 g, factor x0.5 |
| Late meal | HR +5, factor x1.5 |
| Sick | HR +5, motion below 0.06 g, factor x0.5 |
| Workout without rest-day tag | Protection 10 min, trend 5 min |
| Active alcohol and stress | Disable early delivery |

Increasing the trend factor is more permissive. The presets do not all make
all gates stricter.

The owner chose the user's saved `expected_sleep_schedule_v1` as the timing
reference, through `ExpectedSleepSchedule.windowFor()`. Alcohol counts from
bedtime minus two hours through bedtime; caffeine from bedtime minus six hours
through bedtime, inclusive. Dated instants cover overnight and daytime sleep,
including midnight crossings. Missing dose or time cannot activate a timed
preset. Only a missing saved schedule uses the original 20:00/16:00 clock-time
fallback. The journal reader loads the relevant calendar dates and caches by
occurrence, schedule and content revision. Read failures yield default policy
and neutral diagnostics, and are retried.

Late protection holds delivery in the last five minutes, or ten after a workout,
when HR is within two bpm of the selected baseline. With the same baseline in
the +4-or-higher arousal gate, this condition is already rejected by arousal.
Keeping the protection explicit records the intended rule; it is not evidence
that the detector has recognized deep sleep. Existing haptic delivery and the
band's fallback alarm remain responsible for waking. No offline stage output,
readiness value or historical default substitutes for missing live evidence.

The HMM's emissions, transitions and 120-minute baseline interval, the live
percentile/windows, all confounder adjustments and any pre-sync duration are
engineering choices unless validated directly. Phase 3 changes no stored
analytics output, so `kAlgoVersion` stays 117. Its new analytics functions are
used for live legacy delivery only.

## Bibliography carried from upstream

These references preserve upstream provenance; they are not validation of the
numeric gates above:

- [Tassi and Muzet, 2000](https://doi.org/10.1053/smrv.2000.0098).
- [Cajochen et al., 1994](https://doi.org/10.1016/0031-9384(94)90058-2).
- [Berlad et al., 1993](https://doi.org/10.1111/j.1365-2869.1993.tb00067.x).
- [Tsai et al., 2022](https://doi.org/10.1097/PSY.0000000000001079).
- [Imtiaz, 2021](https://doi.org/10.3390/s21051562).

Upstream's referenced `shared/smart-alarm-light-sleep/fact_base_phase2.md` was
absent from the inspected PR tree. It is not a verified evidence source.
