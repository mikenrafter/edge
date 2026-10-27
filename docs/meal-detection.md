# Meal candidates

Meal candidates are an unvalidated engineering heuristic for Review activities.
They are never automatic food entries, calorie estimates, or medical advice.
Candidates appear in the review list; the existing nap/workout alert preferences
do not opt into meal alerts. Only confirmation creates a timestamped meal moment. Existing food entries keep
their identity, time, quantities and nutrition; no nutrition is inferred.

The registered day-block worker aggregates measured HR and motion
`dynAmp` into minutes. Each minute needs at least 30 observed HR seconds and
30 present motion seconds. Missing measurements remain absent. Sleep, nap
suggestions, accepted naps, saved and detected workouts, off-wrist spans and
charging spans are excluded, including the upcoming night's sleep.

Candidates start between 06:00 and 22:00 local time. The baseline is the median
of at least 30 valid low-motion awake minutes from the preceding 60 minutes.
A rise must be at least 8 bpm and between 6% and 21% of that baseline, with
`dynAmp` at most 0.02 g. It must last 20 consecutive measured minutes. The
pre-rise baseline is frozen during the rise; missing minutes break continuity.
These choices favor abstention. They are not validated diagnostic cutoffs.

Typical large-meal times only rank already supported candidates, using circular
clock distance. They cannot manufacture a rise. The default cap is ten per
local date; zero or negative caps disable proposals. Repeated derivations match
existing proposals, and confirmed or discarded decisions remain authoritative.
Meal-time edits preserve the detected interval's duration while moving the
moment's timestamp. Saves validate a positive historical window atomically.

The local research synthesis reports daytime post-meal HR increases of about
6–21% (Chikwetu 2024, JMIR, DOI 10.2196/52167) and roughly 8 bpm with a gradual
return over about four hours (Täubel 2019, J Clin Pharmacol 59:799–810). Those
observations do not establish individual onset timing, meal size or composition,
or free-living episode precision. Stress, medication and other causes can raise
HR at rest. The baseline window, motion cutoff, minimum coverage, daytime gate,
duration, ranking and cap above are engineering choices requiring evaluation
against wearer-confirmed labels. No HRV, skin-temperature, nocturnal nadir, or
analytics #20 late-meal analyzer is used as evidence of eating.
