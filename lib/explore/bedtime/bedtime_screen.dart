// bedtime_screen.dart — the developer-only screen for "Bedtime breathing cues".
//
// Bedtime breathing cues, with an optional stop when the band estimates sleep.
// Evidence: Tsai et al. 2015, doi:10.1111/psyp.12333.
//
// PHASE 1 STUBS: build bodies throw.

import 'package:flutter/material.dart';

import 'bedtime_session_controller.dart';

class BedtimeScreen extends StatelessWidget {
  const BedtimeScreen({super.key, required this.controller});
  final BedtimeSessionController controller;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// The door to the screen. Present only with Feature.developerMode AND
/// Prefs.exploreBedtime (default off); otherwise it builds nothing.
class BedtimeEntry extends StatelessWidget {
  const BedtimeEntry({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
