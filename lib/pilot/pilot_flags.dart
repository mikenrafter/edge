// Owner: PilotFlags owns the three independent Labs opt-ins.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../state/prefs.dart';

enum PilotFlag {
  sleepSummary('pilot.day_timeline.sleep'),
  observations('pilot.observations'),
  alarmScreen('pilot.alarm_screen'),
  wakeMethods('pilot.wake_methods'),
  timelines('pilot.timelines'),
  /// Owner m249: SubTabs share the row's width equally. Default ON; off is
  /// the original scrolling pills.
  fullWidthTabs('ui.full_width_tabs', byDefault: true);
  const PilotFlag(this.key, {this.byDefault = false});
  final String key;
  final bool byDefault;
  bool get enabled => Prefs.getBool(key, byDefault);
}

class PilotFlags {
  static final revision = ValueNotifier(0);
  static Future<void> set(PilotFlag flag, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(flag.key, enabled)) {
      throw StateError('Pilot preference was not saved');
    }
    await Prefs.reload();
    revision.value++;
  }
}
