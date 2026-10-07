// The developer-only "Pacing rates compared" screen and its Device lab entry.
//
// Wording rule: this compares rates and may name a tentative practice rate.
// It never says "resonance frequency" and makes no health claim.
//
// Evidence:
//   Lehrer, Vaschillo & Vaschillo 2000, doi 10.1023/A:1009554825745
//   Shaffer & Meehan 2020, doi 10.3389/fnins.2020.570400
//
// RED-phase stub: every body throws until the implementation lands.
import 'package:flutter/widgets.dart';

import 'resonance_history.dart';
import 'resonance_sweep_controller.dart';

class ResonanceSweepScreen extends StatefulWidget {
  const ResonanceSweepScreen({
    super.key,
    required this.controller,
    required this.history,
  });

  final ResonanceSweepController controller;
  final ResonanceHistoryStore history;

  @override
  State<ResonanceSweepScreen> createState() => _ResonanceSweepScreenState();
}

class _ResonanceSweepScreenState extends State<ResonanceSweepScreen> {
  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// The Device lab row that opens the screen. Present only when developer mode
/// is on AND [Prefs.exploreResonance] is true. Reads nothing from AppState at
/// build time.
class ResonanceSweepEntry extends StatelessWidget {
  const ResonanceSweepEntry({super.key});

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
