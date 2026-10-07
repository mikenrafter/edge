// snooze_settings_rows.dart — the alarm settings rows for the main alarm's
// dismiss/snooze: double taps to dismiss, the dismiss window, the snooze
// length, and where escalation stops.
//
// STUB (red phase): build throws. Pinned by test/alarm_snooze/snooze_ui_test.dart.

import 'package:flutter/material.dart';

import '../../alarm/snooze/snooze_settings.dart';

/// The copy that says what [taps] double taps do, with the live value: "2 double
/// taps to dismiss — fewer is a snooze" ("1 double tap" when it is 1).
String snoozeDismissCopy(int taps) => throw UnimplementedError();

class SnoozeSettingsRows extends StatelessWidget {
  const SnoozeSettingsRows({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final SnoozeSettings settings;

  /// A choice, already clamped; applied at once (these are not part of the
  /// alarm schedule's Save draft).
  final ValueChanged<SnoozeSettings>? onChanged;

  @override
  Widget build(BuildContext c) => throw UnimplementedError();
}
