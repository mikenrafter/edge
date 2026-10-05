// The Trends catalogue: every measure the app charts a history of, grouped the
// way a person would look for it. The ONE list: Trends (health_screen.dart)
// reads it to draw its rows and the Data Explorer (explorer.dart) reads it to
// offer its picks, so a measure added here appears in both.
//
// It is an index, not a dashboard: nothing here computes and nothing here is a
// number about you.

import '../../l10n/app_localizations.dart';

/// One catalogue entry: the [MetricSpec] key (which is what [MetricDetail]
/// takes), the `metric_series` key its history is stored under, and the single
/// line that says what it answers.
///
/// Icon, colour and title are NOT here — they come off the spec. A second copy
/// is how two screens end up disagreeing about what a metric is called.
class MetricCatalogueRow {
  final String key, series, blurb;
  const MetricCatalogueRow(this.key, this.series, this.blurb);
}

class MetricCategory {
  final String title;
  final List<MetricCatalogueRow> rows;
  const MetricCategory(this.title, this.rows);
}

/// The families, in the order a person looks for them.
///
/// What is deliberately NOT here:
/// - SpO2, ODI and anything apnea-shaped. Refused outright — a capability this
///   app does not produce has no entry, no card and no key. The one exception
///   is a single line under Breathing (see `_family`) saying why there is no
///   SpO2, because people look for it there; it is a sentence, not a row.
/// - Cycle. It is a Wellness tab with its own door and its own on/off switch;
///   a second entrance from Health would be a duplicate route, not a feature.
/// - `rmssd_whole`, `stress_si`, `brv_slope`. Real numbers, but single-night
///   with no series ever. They had written specs for a while and nothing could
///   open them; the specs are gone now, so there is nothing to route to either.
///   `stress` and `brv` below are the charted forms of two of the three.
/// - Body clock, zones, Nerd stats. Each already has a door at the same depth
///   as this one; adding a second is navigation debt.
const kMetricCatalogue = <MetricCategory>[
  // Readiness and stress both have stored histories and were missing from this
  // list, so the one place that lists every measure with a history left out the
  // two most looked-at ones. Each is a composite, not a sensor reading, so they
  // sit in a family of their own.
  MetricCategory('Recovery', [
    MetricCatalogueRow('readiness', 'readiness', 'How ready your body looks for strain, against your own usual'),
    MetricCatalogueRow('stress', 'stress', 'Beat-interval clustering over your most restful stretch'),
  ]),
  MetricCategory('Heart & rhythm', [
    MetricCatalogueRow('resting_hr', 'rhr', 'The lowest sustained rate of the night'),
    MetricCatalogueRow('hrv', 'rmssd', 'RMSSD (beat-to-beat variation) over the cleanest stretch of sleep'),
    MetricCatalogueRow('hrv_cv', 'hrv_cv', 'How much HRV varies from night to night'),
    MetricCatalogueRow('lf_hf', 'lf_hf', 'Beat-to-beat variation split by frequency band'),
    MetricCatalogueRow('dip', 'dip_pct', 'How far your heart rate falls while you sleep'),
    MetricCatalogueRow('hrr', 'hrr_bpm', 'How fast your heart rate drops in the minute after exercise'),
  ]),
  MetricCategory('Sleep', [
    MetricCatalogueRow('sleep', 'tst_min', 'Time asleep, from motion and beat timing'),
    MetricCatalogueRow('efficiency', 'efficiency', 'Asleep as a share of time in bed'),
    MetricCatalogueRow('deep', 'deep_min', 'Heart-rate steadiness during non-REM sleep'),
    MetricCatalogueRow('rem', 'rem_min', 'Sleep stages from beat variability and movement'),
    MetricCatalogueRow('nap_min', 'nap_min', 'Sleep detected outside the main night'),
  ]),
  MetricCategory('Breathing', [
    MetricCatalogueRow('resp_rate', 'resp_rate', 'Breaths per minute, estimated from beat timing'),
    MetricCatalogueRow('brv', 'brv_cv', 'How much that rate varies across the night'),
  ]),
  MetricCategory('Movement & load', [
    MetricCatalogueRow('steps', 'steps', 'Counted by a pedometer'),
    MetricCatalogueRow('active_min', 'active_min', 'Minutes of body movement, walking or not'),
    MetricCatalogueRow('calories', 'calories', 'Active energy from heart rate and your profile'),
    MetricCatalogueRow('strain', 'strain', 'Cardiovascular load over the day, on 0–21'),
    MetricCatalogueRow('trimp', 'trimp', 'Minutes weighted by heart-rate reserve, harder minutes count more'),
  ]),
  MetricCategory('Body & wear', [
    MetricCatalogueRow('skin_temp', 'skin_temp_z', 'Skin temperature vs your recent nights, in standard deviations'),
    MetricCatalogueRow('wear', 'worn_min', 'Minutes the band recorded data'),
  ]),
];

/// Catalogue category titles and row blurbs are read off a top-level `const`
/// list, which cannot call `AppLocalizations.of(context)` itself — so the
/// lookup happens here, at render time, keyed off the same literal English
/// text/row key the const list already carries as its fallback.
String metricCategoryTitle(AppLocalizations? l, String title) => switch (title) {
      'Recovery' => l?.healthCatRecovery ?? title,
      'Heart & rhythm' => l?.healthCatHeartRhythm ?? title,
      'Sleep' => l?.healthRowSleep ?? title,
      'Breathing' => l?.healthCatBreathing ?? title,
      'Movement & load' => l?.healthCatMovementLoad ?? title,
      'Body & wear' => l?.healthCatBodyWear ?? title,
      _ => title,
    };

