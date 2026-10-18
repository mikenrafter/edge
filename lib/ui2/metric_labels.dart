// One English name per metric, for Home and Health.
//
// The same number used to be "Heart rate" over "Resting" on Home, "Resting
// heart rate" on Last night and Trends, and sleep was "Time asleep" in one
// place and "Sleep" in another (AGENTS.md 4.10). Screens read their name here
// and only fall to a localized string for the same concept; this table is the
// English fallback and the spelling a test can pin.
//
// "Time asleep" is a sub-label under Sleep, never the name of the metric.

abstract final class MetricLabels {
  static const restingHr = 'Resting heart rate';
  static const hrv = 'HRV';
  static const sleep = 'Sleep';
  static const timeAsleep = 'Time asleep';
  static const daytimeSleep = 'Daytime sleep';
  static const respRate = 'Respiratory rate';
  static const stress = 'Stress';
  static const overnightStress = 'Overnight stress';
  static const skinTemp = 'Skin temperature';
  static const strain = 'Strain';
  static const steps = 'Steps';
}
