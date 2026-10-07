// Developer-only research view of repeating nighttime pulse patterns.
// Prototype: lib/explore/pulse/. See pulse_pattern_night.dart for what the
// numbers are and are not.

import 'package:flutter/widgets.dart';

import 'pulse_pattern_night.dart';

const String kPulseResearchTitle =
    'Repeating nighttime pulse patterns (research)';

const String kPulseResearchDisclaimer =
    'Research view. Not a breathing measurement, not a screening and not a '
    'diagnosis. The band has no airflow or oxygen sensor.';

const String kPulseResearchZeroLine =
    'Zero patterns means zero under this detector on the analysed data. It '
    'does not mean breathing was normal.';

/// The research screen: the two permanent lines, one row per night
/// (analysed hours, coverage, count; "not analysed" or the exclusions in
/// words instead of a count), and the evidence links.
class PulsePatternResearchScreen extends StatelessWidget {
  const PulsePatternResearchScreen({super.key, required this.nights});

  final List<PulsePatternNight> nights;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// The way in: built only when `Feature.developerMode` is available AND
/// `Prefs.explorePulsePatterns` is on; otherwise an empty box. Tapping it
/// opens [PulsePatternResearchScreen] over [nights].
class PulsePatternResearchEntry extends StatelessWidget {
  const PulsePatternResearchEntry({super.key, required this.nights});

  final List<PulsePatternNight> nights;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
