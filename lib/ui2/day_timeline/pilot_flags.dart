// Per-screen opt-in for the day-timeline pilot. Off by default: a screen
// that is not opted in is exactly what it was. Switched under Advanced
// charts ("Pilots"); a setting like any other, so it travels in exports.

import 'package:flutter/foundation.dart';

import '../../state/prefs.dart';

enum DayTimelinePilot {
  /// The Sleep night card and its timeline editor.
  sleep('pilot.day_timeline.sleep'),

  /// Activities (the day breakdown and review) on the timeline.
  activities('pilot.day_timeline.activities');

  const DayTimelinePilot(this.key);
  final String key;

  /// Tests set this instead of the stored setting.
  @visibleForTesting
  static final Map<DayTimelinePilot, bool> debugOverride = {};

  static final ValueNotifier<int> revision = ValueNotifier(0);

  bool get on => debugOverride[this] ?? Prefs.getBool(key, false);

  set on(bool v) {
    Prefs.setBool(key, v);
    revision.value++;
  }
}
