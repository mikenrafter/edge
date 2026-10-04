// 8AF.6: the built-in (system) patterns. Three gesture cues (start, follow-up,
// confirm) and one default per non-alarm alert rule are stored beside the
// user's patterns under a stable systemKey. They can be customised and put
// back, never renamed or deleted. The defaults are built here, for the WHOOP
// MG profile with the taps rhythm kept for a 4.0 band. Pure Dart.

import '../gestures/pattern_transcript.dart';
import '../notify/buzz_sequence.dart';
import '../notify/notification_prefs.dart';
import 'haptic_compiler.dart';
import 'haptic_profile.dart';
import 'tap_notes.dart';

const String kGestureStartKey = 'gesture.start';
const String kGestureFollowUpKey = 'gesture.followUp';
const String kGestureConfirmKey = 'gesture.confirm';

/// The alert rules with no built-in pattern: the alarms and the wake buzz.
const Set<String> _noBuiltIn = {
  'alarm',
  'nativeAlarm',
  'wake',
  'alarmLatchFailed',
  'alarmNightCheck',
};

const Map<String, String> _alertNames = {
  'health': 'Health alert',
  'recovery': 'Recovery alert',
  'reminders': 'Reminder alert',
  'device': 'Device alert',
  'water': 'Water alert',
  'autoDetect': 'Workout detected alert',
  'movement': 'Movement alert',
  'meds': 'Medication alert',
  'checkIn': 'Check-in alert',
  'stepGoal': 'Step goal alert',
  'windDown': 'Wind-down alert',
  'zone': 'Heart-rate zone alert',
  'breath': 'Breathing cue',
  'tasker': 'Automation alert',
  'relay': 'Relayed notification',
  'gesture': 'Gesture alert',
};

/// The systemKey of the built-in for alert rule [ruleId].
String alertSystemKey(String ruleId) => 'alert.$ruleId';

/// The id a built-in is stored under: stable, so a rule's snapshot of it keeps
/// pointing at it across reads.
String systemPatternId(String systemKey) => 'sys.$systemKey';

/// A built-in as it is seeded.
class BuiltInSpec {
  const BuiltInSpec(this.key, this.name, this.sequence);
  final String key;
  final String name;

  /// Carries [systemPatternId] of [key] as its patternId.
  final BuzzSequence sequence;
}

/// Every built-in key, in the order they are listed: the gesture cues, then
/// one per non-alarm alert rule.
List<String> builtInKeys() => [
      kGestureStartKey,
      kGestureFollowUpKey,
      kGestureConfirmKey,
      for (final id in NotificationPrefs.alertRuleOrder)
        if (!_noBuiltIn.contains(id)) alertSystemKey(id),
    ];

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

/// One command as a pattern: the phrase's shortest rendition as notes, the
/// taps those notes make, and the one-step plan for the MG.
BuzzSequence _fromPhrase(HapticPhrase ph, String id) {
  final notes = ph.min;
  return tapsFromNotes(notes, unitMs: _mg.unitMs).copyWith(
    notes: notes.join(' '),
    profileId: _mg.id,
    profileVersion: _mg.version,
    bakedSteps: [BakedStep(effects: ph.effects, loop: ph.loop, delayMs: 0)],
    bakedRuntimeMs: ph.unitsMax * _mg.unitMs,
    patternId: id,
  );
}

HapticPhrase _phrase(String id) => _mg.phrases.firstWhere((p) => p.id == id);

/// Today's default rhythm for alert [ruleId] as `*` notes, compiled for the
/// MG with the taps rhythm kept so a 4.0 band plays what it always did.
BuzzSequence _alertDefault(String ruleId, String id) {
  final taps =
      BuzzSequence.defaultFor(NotificationPrefs.alertRuleOrder.indexOf(ruleId));
  final notes = notesFromTaps(taps, unitMs: _mg.unitMs, dynamic: PatternDynamic.any);
  final plan = compile(notes, _mg, dynamicWeight: 0);
  final s = taps.copyWith(
    notes: notes.join(' '),
    profileId: _mg.id,
    profileVersion: _mg.version,
    patternId: id,
  );
  if (plan == null) return s;
  return s.copyWith(
    bakedSteps: [
      for (final st in plan.steps)
        BakedStep(
          effects: st.phrase.effects,
          loop: st.phrase.loop,
          delayMs: st.delayMs,
        ),
    ],
    bakedRuntimeMs: plan.runtimeMs,
  );
}

/// The seeded default for [systemKey], or null for a key that is not built in.
BuiltInSpec? builtInDefault(String systemKey) {
  final id = systemPatternId(systemKey);
  switch (systemKey) {
    case kGestureStartKey:
      return BuiltInSpec(
          systemKey, 'Gesture start', _fromPhrase(_phrase('pair'), id));
    case kGestureFollowUpKey:
      final single = _mg.fastestSingle();
      if (single == null) return null;
      return BuiltInSpec(systemKey, 'Gesture follow-up', _fromPhrase(single, id));
    case kGestureConfirmKey:
      return BuiltInSpec(
          systemKey, 'Gesture confirm', _fromPhrase(_phrase('buzz47'), id));
  }
  if (!systemKey.startsWith('alert.')) return null;
  final ruleId = systemKey.substring('alert.'.length);
  final name = _alertNames[ruleId];
  if (name == null || !NotificationPrefs.alertRuleOrder.contains(ruleId)) {
    return null;
  }
  if (_noBuiltIn.contains(ruleId)) return null;
  return BuiltInSpec(systemKey, name, _alertDefault(ruleId, id));
}
