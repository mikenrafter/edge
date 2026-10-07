// snooze_card.dart — Home's snooze card: "Snoozed until HH:MM" and an "I'm up"
// button that dismisses. Same pattern as natural_wake_card.dart: it listens to
// the controller's status and is gone the moment no snooze is live.
//
// STUB (red phase): build throws. Pinned by test/alarm_snooze/snooze_ui_test.dart.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../alarm/snooze/snooze_controller.dart';

class SnoozeCard extends StatelessWidget {
  const SnoozeCard({super.key, required this.status, required this.onImUp});

  /// [SnoozeController.status].
  final ValueListenable<SnoozeStatus> status;

  /// "I'm up" ([SnoozeController.imUp]).
  final Future<void> Function() onImUp;

  @override
  Widget build(BuildContext c) => throw UnimplementedError();
}

/// The card for Home, or null with no AppState above (a golden): the same
/// null-safe insertion as the Natural Wake card, used as `?snoozeCardFor(c)`
/// at both of Home's list sites.
Widget? snoozeCardFor(BuildContext c) => throw UnimplementedError();
