// Shared bits for the round 4 snooze tests (Sol's third review,
// alarm-snooze-sol-review3-2026-10-07.md). The rig is snooze_band_rig.dart, the
// round 3 set-up is snooze_r3_support.dart.

import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';

/// A strap clock that was never set (epoch zero).
final DateTime kUnsetStrap = DateTime.fromMillisecondsSinceEpoch(0);

/// How many haptic commands reached the radio so far.
int hapticWrites(SnoozeBandRig rig) => rig.writes
    .where((w) =>
        w.opcode == Cmd.runHapticPatternMaverick ||
        w.opcode == Cmd.runHapticsPattern)
    .length;

/// The wearer switches the snooze switch off (the settings screen's path).
Future<void> switchSnoozeOff(SnoozeBandRig rig) => rig.app.setSnoozeSettings(
    SnoozeSettings.fromJson(
        {...rig.app.snoozeSettings.toJson(), 'enabled': false}));

/// Polls (event-loop turns, no clock reads) until [cond] holds; false after
/// [turns] polls.
Future<bool> until(bool Function() cond, {int turns = 500}) async {
  for (var i = 0; i < turns; i++) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return cond();
}
