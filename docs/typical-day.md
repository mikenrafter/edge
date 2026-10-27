# Typical day

The review timeline opens Typical day. Its horizontal axis is a local 24-hour
clock. The alertness curve uses the existing circadian artifact and analytics
forecast, including the artifact's observed chronotype and clock phase when
available. The forecast supports 18 hours after waking; the rest remains blank.
The chart describes a prediction from sleep and clock inputs. It does not measure
energy or use caffeine as an input. When the individual's clock phase is absent,
the screen identifies the forecast's assumed phase.

Quiet hours come from NotificationPrefs, and expected sleep comes from the saved
expected_sleep_schedule_v1 setting. Each window splits at midnight when needed.
An 08:00–16:00 sleep window stays on those clock hours. TypicalMealTimes owns
an optional sorted, deduplicated list of clock minutes in typical_large_meals_v1.
There are no default meal times. SettingsRepository serializes its writes, and
the existing backup preference carrier restores it. The Alarm link opens the
existing Alarm section.

## Personal caffeine comparisons

The source reads at most 43 derived dates and a bounded 49-day journal window.
The registered typicalCaffeineHeavy worker matches each observed main-sleep wake
to the next observed main-sleep onset within 36 hours. This also supports daytime
sleep. The following sleep supplies latency, total sleep and resting HR; recorded
nap periods must fall inside that waking interval. Missing outcomes stay absent.

Schema 81 adds nullable moment_label.caffeine_mg. Answering a caffeine moment
stores its explicit amount atomically with its daily journal total. A historical
daily total and its latest clock time cannot establish a dose schedule or the
first intake, so those totals alone do not enter comparisons. Timed caffeine
moments with an unknown amount can support first-recorded-time comparisons but
cannot support a residual estimate. No amount is inferred from the total.

Residual caffeine sums dose × 0.5^(elapsed minutes / 300) at the next observed
sleep onset, using explicit amounts from the preceding seven days. Unknown doses
or daily totals that are not accounted for by dose moments make the residual
absent. Five hours is a fixed engineering model requested for this screen;
individual elimination varies, and the estimate is not a measurement. An
incomplete newest day shows no residual instead of reusing an older estimate.

Each Spearman rank correlation uses the existing analytics statistic and requires
14 distinct paired days with variation in both inputs. This is an engineering evidence floor, not statistical significance.
The count beside each outcome is its own paired sample count. The afternoon dip
is the supported afternoon forecast's peak-to-trough shape span and is labelled
predicted. It is not observed afternoon alertness. Associations are exploratory
and cannot establish an effect of caffeine timing. No population claim or
90-minute-delay recommendation is made.

The research reviewed for this batch is recorded in
edge.research/substance-research/caffeine.md. Its primary-source references
include Grzegorzewski et al., doi:10.3389/fphar.2021.752826, and Drake et al.,
doi:10.5664/jcsm.3170. The review found no trial directly testing first caffeine
after waking against afternoon alertness. The UI therefore reports only the
wearer's paired observations and states its limitations.

## Visual checks

New golden cases are typical_day_daytime_sleep.png and
typical_day_overnight_sleep.png. PNG generation is intentionally left for visual
review under the batch instruction. Existing golden PNGs are unchanged. A
separate widget test reads the rendered chart pixels to verify daytime sleep and
quiet hours crossing midnight without relying on a generated baseline.
