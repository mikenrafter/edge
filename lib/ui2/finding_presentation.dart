// One visual identity for each existing detector. No new detection or copy.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../compute/findings.dart';
import 'theme.dart';

Color findingColor(FindingKind kind) => switch (kind) {
  FindingKind.illness => C.orange,
  FindingKind.anomaly => C.teal,
  FindingKind.tempElevated => C.pink,
  FindingKind.irregularRhythm => C.red,
  FindingKind.lowReadiness => C.purple,
  FindingKind.rhrShift => C.blue,
};
IconData findingIcon(Finding f) => switch (f.kind) {
  FindingKind.illness => LucideIcons.stethoscope,
  FindingKind.anomaly => LucideIcons.waves,
  FindingKind.tempElevated => LucideIcons.thermometer,
  FindingKind.irregularRhythm => LucideIcons.heartPulse,
  FindingKind.lowReadiness => LucideIcons.batteryLow,
  FindingKind.rhrShift =>
    f.risen == null
        ? LucideIcons.chartLine
        : f.risen!
        ? LucideIcons.trendingUp
        : LucideIcons.trendingDown,
};
