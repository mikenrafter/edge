// termination_probe_card.dart — the Device lab's termination probe card
// (developer mode): one button per scenario, the running view with Stop, each
// scenario's timeline and verdict, and "Save report file" (the log-file path,
// never the clipboard). Leaving the screen stops the probe, which clears its
// alarm slot and restores the real alarm.
//
// RED PHASE: the build throws until the green phase.

import 'package:flutter/material.dart';

import '../../gestures/termination_probe.dart';
import '../../util/log_file.dart';

class TerminationProbeCard extends StatefulWidget {
  const TerminationProbeCard({super.key, required this.runner, this.saveLog});
  final TerminationProbeRunner runner;

  /// How the report is saved; null is [saveLogFile] (the platform share sheet).
  final LogFileSaver? saveLog;

  @override
  State<TerminationProbeCard> createState() => _TerminationProbeCardState();
}

class _TerminationProbeCardState extends State<TerminationProbeCard> {
  @override
  Widget build(BuildContext context) => throw UnimplementedError('red');
}
