// The built-in (system) patterns. Four gesture cues (start, follow-up,
// confirm and failed), four breathing cues (Oct 4) and ten presets (pulses, long pulses, SOS, Hip hip
// hooray) are stored beside the user's patterns under a stable systemKey. They
// can never be renamed or deleted; the cues can be customised and put back, the
// presets are read-only. A non-alarm alert rule's default is one of the presets
// ([alertPresetKey]); its slot key 'alert.<ruleId>' only names where it is
// used. The defaults are built here, for the WHOOP MG profile with the taps
// rhythm kept for a 4.0 band. Pure Dart.

import '../gestures/pattern_transcript.dart';
import '../notify/buzz_sequence.dart';
import '../notify/notification_prefs.dart';
import 'haptic_compiler.dart';
import 'haptic_profile.dart';
import 'haptic_slots.dart' show kTaskerSlotCount, taskerSlotKey, taskerSlotNumber;
import 'tap_notes.dart';

const String kGestureStartKey = 'gesture.start';
const String kGestureFollowUpKey = 'gesture.followUp';
const String kGestureConfirmKey = 'gesture.confirm';

/// The failed-gesture cue; its default is the failure buzz the engine
/// used to play as a fixed call.
const String kGestureFailedKey = 'gesture.failed';

/// The four breathing cues (Oct 4): the start of an inhale, an exhale and a
/// hold, and the end of the session. Interval work plays the inhale cue, rest
/// the exhale cue, both holds the hold cue. Each default is ONE command of the
/// MG's vocabulary (a breath is cued every few seconds and the band takes 30
/// commands in two minutes) and short enough to finish well inside the
/// shortest built-in phase: a long strong buzz to breathe in, a shorter and
/// softer one to breathe out, two faint ticks for a hold, and a swell that
/// settles for the end.
const String kBreathInhaleKey = 'breath.inhale';
const String kBreathExhaleKey = 'breath.exhale';
const String kBreathHoldKey = 'breath.hold';
const String kBreathDoneKey = 'breath.done';

/// The ten presets, in the order they are listed: key, name and notes. A
/// pulse is a quarter note, a long pulse a half, the rest between pulses a
/// quarter. SOS is three short, three long, three short; Hip hip hooray is two
/// rounds of short, short, longer.
const List<(String, String, String)> kPresets = [
  ('preset.one_pulse', 'One pulse', 'N4*'),
  ('preset.two_pulses', 'Two pulses', 'N4* R4 N4*'),
  ('preset.three_pulses', 'Three pulses', 'N4* R4 N4* R4 N4*'),
  ('preset.four_pulses', 'Four pulses', 'N4* R4 N4* R4 N4* R4 N4*'),
  ('preset.five_pulses', 'Five pulses', 'N4* R4 N4* R4 N4* R4 N4* R4 N4*'),
  ('preset.one_long_pulse', 'One long pulse', 'N8*'),
  ('preset.two_long_pulses', 'Two long pulses', 'N8* R4 N8*'),
  ('preset.three_long_pulses', 'Three long pulses', 'N8* R4 N8* R4 N8*'),
  (
    'preset.sos',
    'SOS',
    'N2* R2 N2* R2 N2* R4 N6* R3 N6* R3 N6* R4 N2* R2 N2* R2 N2*',
  ),
  (
    'preset.hip_hip_hooray_x2',
    'Hip hip hooray ×2',
    'N2* R2 N2* R2 N4* R6 N2* R2 N2* R2 N4*',
  ),
];

/// Which preset each alert slot plays until the wearer picks another. Spread so
/// that no preset serves more than two slots and alerts that can fire close
/// together differ in count and length. SOS is not a default anywhere: a 4.0
/// holds eight taps at most (BuzzSequence.maxBuzzes), so its taps rhythm is
/// the SOS minus its last short pulse, and nobody gets that unasked.
const Map<String, String> _alertPresets = {
  'health': 'preset.three_long_pulses',
  'recovery': 'preset.two_pulses',
  'reminders': 'preset.five_pulses',
  'device': 'preset.two_long_pulses',
  'water': 'preset.three_pulses',
  'autoDetect': 'preset.one_long_pulse',
  'movement': 'preset.four_pulses',
  'meds': 'preset.five_pulses',
  'checkIn': 'preset.one_pulse',
  'stepGoal': 'preset.hip_hip_hooray_x2',
  'windDown': 'preset.one_long_pulse',
  'zone': 'preset.two_long_pulses',
  'breath': 'preset.one_pulse',
  'tasker': 'preset.two_pulses',
  'relay': 'preset.three_pulses',
};

/// The preset key behind alert slot [slotKey] (`alert.<ruleId>`), or null for a
/// key that is not an alert slot with a default.
String? alertPresetKey(String slotKey) => slotKey.startsWith('alert.')
    ? _alertPresets[slotKey.substring('alert.'.length)]
    : null;

/// Whether [systemKey] is one of the read-only presets.
bool isPresetKey(String systemKey) => systemKey.startsWith('preset.');

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

/// Every built-in key, in the order they are listed: the gesture cues, the
/// breathing cues, then the presets. (Alert slots are not built-ins of their own: see
/// [alertPresetKey].)
List<String> builtInKeys() => [
      kGestureStartKey,
      kGestureFollowUpKey,
      kGestureConfirmKey,
      kGestureFailedKey,
      kBreathInhaleKey,
      kBreathExhaleKey,
      kBreathHoldKey,
      kBreathDoneKey,
      for (var n = 1; n <= kTaskerSlotCount; n++) taskerSlotKey(n),
      for (final p in kPresets) p.$1,
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

// [code] as a pattern: its notes, the taps those notes make, and the plan
// compiled for the MG under the default cap. A 4.0 holds at most eight taps, so
// the taps rhythm stops after the eighth pulse.
BuzzSequence _fromNotes(String code, String id) {
  final notes = PatternTranscript.parseCode(code).entries;
  var pulses = 0;
  var inNote = false;
  var keep = notes.length;
  for (var i = 0; i < notes.length; i++) {
    if (notes[i].note) {
      if (!inNote && ++pulses > BuzzSequence.maxBuzzes) {
        keep = i;
        break;
      }
      inNote = true;
    } else {
      inNote = false;
    }
  }
  final taps = tapsFromNotes(notes.sublist(0, keep), unitMs: _mg.unitMs);
  final plan = compile(
    notes,
    _mg,
    dynamicWeight: 0,
    maxRuntimeMs: kMaxHapticRuntime.inMilliseconds,
  );
  final s = taps.copyWith(
    notes: code,
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

/// Whether [s] is the rhythm alert [ruleId] was seeded with before the presets
/// (the nine count-and-gap rhythms of BuzzSequence.defaultFor, as `*` notes): a
/// stored copy of it was never the wearer's choice and gives way to the preset.
bool isLegacyAlertDefault(String ruleId, BuzzSequence s) {
  final i = NotificationPrefs.alertRuleOrder.indexOf(ruleId);
  if (i < 0) return false;
  final taps = BuzzSequence.defaultFor(i);
  final notes =
      notesFromTaps(taps, unitMs: _mg.unitMs, dynamic: PatternDynamic.any)
          .join(' ');
  return s.notes == notes &&
      s.offsetsMs.join(',') == taps.offsetsMs.join(',') &&
      s.durationsMs.join(',') == taps.durationsMs.join(',');
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
    case kGestureFailedKey:
      return BuiltInSpec(
          systemKey, 'Gesture failed', _fromPhrase(_phrase('pairx2'), id));
    case kBreathInhaleKey:
      return BuiltInSpec(
          systemKey, 'Breathing inhale', _fromPhrase(_phrase('buzz47x2'), id));
    case kBreathExhaleKey:
      return BuiltInSpec(
          systemKey, 'Breathing exhale', _fromPhrase(_phrase('buzz14'), id));
    case kBreathHoldKey:
      return BuiltInSpec(
          systemKey, 'Breathing hold', _fromPhrase(_phrase('click1'), id));
    case kBreathDoneKey:
      return BuiltInSpec(
          systemKey, 'Breathing done', _fromPhrase(_phrase('arc47'), id));
  }
  for (final (key, name, notes) in kPresets) {
    if (key == systemKey) return BuiltInSpec(key, name, _fromNotes(notes, id));
  }
  // Tasker slot n: n short pulses, the pulse and rest of the "One pulse" preset.
  final tasker = taskerSlotNumber(systemKey);
  if (tasker != null) {
    return BuiltInSpec(
      systemKey,
      'Tasker slot $tasker',
      _fromNotes(List.filled(tasker, 'N4*').join(' R4 '), id),
    );
  }
  // An alert slot's default is its preset.
  final preset = alertPresetKey(systemKey);
  return preset == null ? null : builtInDefault(preset);
}
