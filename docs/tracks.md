# Tracks

T1 adds editable definitions, explicit setup history and a log. It does not infer
exposures or change sleep, readiness or Natural wake output.

`TracksStore` owns track definitions, setup history and manual track events.
`LocalDb` owns the database connection. Source sections retain ownership of their
records. The `track_event_feed` SQL view projects workouts, medication doses,
nutrition entries and confirmed moments without copying records. Track logging
for a linked source delegates to its owner. Stable source identities make retries
idempotent and edits/deletions immediately visible from both directions.

Preset kinetics are editable starting values. Each field stores a nullable value
and a lock separately. Missing values stay unknown. Source notes distinguish a
measured peak from onset, retain reported ranges, and identify research gaps.
Menstrual cycle starts disabled and is stored locally with other wearer records.

Daily journal totals describe an aggregate, not individual doses. Explicit timed
caffeine doses take priority; only the remaining daily amount is exposed as an
untimed event. No timestamp is inferred from a daily field's last-entry time.

Setup history is a list of inclusive local date intervals labelled done or not
done. The no-unadjusted-data setting records that the track state itself is the
wearer's baseline. It makes no claim about an observed effect.

T2 will own learning. Its neutral adjustment has no fields. Thresholds and
durations combine by maximum, ceilings by minimum, and multipliers apply once per
class. Count/mean/M2 statistics merge using the Welford merge rule. Definitions
already preserve independent locks and selected systems for that phase; T1 never
adjusts a value. T3 will own new detections and experiments. Bounds constrain
future proposals; a minimum is a prompt threshold, never permission to invent an
occurrence.
