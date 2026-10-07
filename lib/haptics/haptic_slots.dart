// The haptic SLOTS, every alert or feature that plays a stored pattern,
// grouped the way the Haptics screen lists them, and what each one plays now.
//
// A slot key is the systemKey scheme: 'alert.<ruleId>' for an alert
// rule, 'gesture.start|followUp|confirm|failed' for a gesture cue,
// 'breath.inhale|exhale|hold|done' for a breathing cue, 'tasker.1' .. 'tasker.6'
// for a Tasker slot. An alert slot's
// pattern lives in its rule (a snapshot carrying the pattern's id); a cue's
// (gesture or breathing) is a pattern id kept in [decodeCueAssignments]'s map.
// With neither, the slot plays its default (a preset for an alert, the cue's
// own built-in for a cue). The relay's slot is the apps channel's own pattern:
// the relay reads its channel, not the rule, and with none chosen plays the
// registry rhythm, which no preset stands for. Pure Dart.

import 'dart:convert';

import '../notify/buzz_sequence.dart';
import '../notify/notification_prefs.dart';
import '../notify/notification_relay.dart';
import 'builtin_patterns.dart';
import 'pattern_store.dart';

/// One slot: its key and the name it is listed under.
class HapticSlot {
  const HapticSlot(this.key, this.label);
  final String key;
  final String label;
}

/// A group of slots and the screen where they are used.
class HapticSlotSection {
  const HapticSlotSection(this.id, this.title, this.slots);
  final String id;
  final String title;
  final List<HapticSlot> slots;
}

/// The slots, by section, in the order the screen lists them. Alarms and wake
/// play fixed plans in code and have no slot.
const List<HapticSlotSection> kHapticSlotSections = [
  HapticSlotSection('alerts', 'Alerts', [
    HapticSlot('alert.health', 'Health exceptions'),
    HapticSlot('alert.recovery', 'Recovery ready'),
    HapticSlot('alert.reminders', 'Weekly lookback'),
    HapticSlot('alert.meds', 'Medication reminders'),
    HapticSlot('alert.checkIn', 'Daily check-in'),
    HapticSlot('alert.water', 'Water reminder'),
    HapticSlot('alert.windDown', 'Wind-down'),
    HapticSlot('alert.device', 'Band battery'),
  ]),
  HapticSlotSection('activity', 'Activity', [
    HapticSlot('alert.autoDetect', 'Detected workouts'),
    HapticSlot('alert.movement', 'Movement nudge'),
    HapticSlot('alert.stepGoal', 'Step goal alerts'),
    HapticSlot('alert.zone', 'HR zone alert'),
  ]),
  HapticSlotSection('apps', 'Apps and automation', [
    HapticSlot('alert.relay', 'App notifications'),
    HapticSlot('alert.tasker', 'Automation alerts'),
  ]),
  HapticSlotSection('tasker', 'Tasker', [
    HapticSlot('tasker.1', 'Tasker slot 1'),
    HapticSlot('tasker.2', 'Tasker slot 2'),
    HapticSlot('tasker.3', 'Tasker slot 3'),
    HapticSlot('tasker.4', 'Tasker slot 4'),
    HapticSlot('tasker.5', 'Tasker slot 5'),
    HapticSlot('tasker.6', 'Tasker slot 6'),
  ]),
  HapticSlotSection('gestures', 'Gestures', [
    HapticSlot(kGestureStartKey, 'Gesture start'),
    HapticSlot(kGestureFollowUpKey, 'Gesture follow-up'),
    HapticSlot(kGestureConfirmKey, 'Gesture confirmed'),
    HapticSlot(kGestureFailedKey, 'Gesture failed'),
  ]),
  HapticSlotSection('breathing', 'Breathing', [
    HapticSlot(kBreathInhaleKey, 'Inhale'),
    HapticSlot(kBreathExhaleKey, 'Exhale'),
    HapticSlot(kBreathHoldKey, 'Hold'),
    HapticSlot(kBreathDoneKey, 'Session complete'),
  ]),
];

/// The six Tasker slots: `tasker.1` .. `tasker.6`. Slot n's built-in default
/// is n short pulses; Tasker plays a slot by its number or its key and the
/// wearer can put any pattern on it, like a cue slot.
const int kTaskerSlotCount = 6;

/// The key of Tasker slot [n] (1..6); ArgumentError otherwise.
String taskerSlotKey(int n) {
  if (n < 1 || n > kTaskerSlotCount) {
    throw ArgumentError.value(n, 'n', 'must be 1..$kTaskerSlotCount');
  }
  return 'tasker.$n';
}

/// The number (1..6) of Tasker slot [slotKey], or null for any other key.
int? taskerSlotNumber(String slotKey) {
  if (!slotKey.startsWith('tasker.')) return null;
  final n = int.tryParse(slotKey.substring('tasker.'.length));
  if (n == null || n < 1 || n > kTaskerSlotCount) return null;
  return slotKey == 'tasker.$n' ? n : null;
}

/// Whether [slotKey] is one of the six Tasker slots.
bool isTaskerSlot(String slotKey) => taskerSlotNumber(slotKey) != null;

/// The relay's alert slot, which is a relay channel's pattern, not a rule's.
const String kRelaySlotKey = 'alert.relay';

/// The relay channel whose own pattern the relay slot is.
const String kRelaySlotChannel = 'apps';

/// Whether [slotKey] is one of the four gesture cues.
bool isGestureCueSlot(String slotKey) =>
    slotKey == kGestureStartKey ||
    slotKey == kGestureFollowUpKey ||
    slotKey == kGestureConfirmKey ||
    slotKey == kGestureFailedKey;

/// Whether [slotKey] is one of the four breathing cues.
bool isBreathCueSlot(String slotKey) =>
    slotKey == kBreathInhaleKey ||
    slotKey == kBreathExhaleKey ||
    slotKey == kBreathHoldKey ||
    slotKey == kBreathDoneKey;

/// Whether [slotKey] is one of the six ECG cues (`ecg.*`, see [kEcgCueKeys]).
// RED stub (ecg-features): to be implemented in the green phase.
bool isEcgCueSlot(String slotKey) =>
    throw UnimplementedError('isEcgCueSlot: ECG haptic slots not built yet');

/// Whether [slotKey] is a cue slot: a gesture cue, a breathing cue or a Tasker
/// slot. Its assigned pattern is a pattern id in [decodeCueAssignments]'s map,
/// and it plays the cue's own built-in with none.
bool isCueSlot(String slotKey) =>
    isGestureCueSlot(slotKey) ||
    isBreathCueSlot(slotKey) ||
    isTaskerSlot(slotKey);

/// Whether [slotKey] is a slot on the Haptics screen (any section).
bool isKnownSlot(String slotKey) => [
      for (final sec in kHapticSlotSections) ...sec.slots,
    ].any((s) => s.key == slotKey);

/// The pattern id each cue was given, from its stored JSON (never
/// throws; anything unreadable is none).
Map<String, String> decodeCueAssignments(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final d = jsonDecode(raw);
    if (d is! Map) return const {};
    return {
      for (final e in d.entries)
        if (e.key is String && e.value is String && isCueSlot(e.key as String))
          e.key as String: e.value as String,
    };
  } on FormatException {
    return const {};
  }
}

String encodeCueAssignments(Map<String, String> m) => jsonEncode(m);

/// The sequence each cue (gesture or breathing) plays: the pattern
/// [assignments] put on it if the store still has it, else the cue's own built-in as stored (and
/// as the wearer may have changed it). A cue with neither is absent, and
/// GestureCues plays its seeded default. The one place this is decided, so
/// what plays is what the Haptics screen shows on the slot.
Map<String, BuzzSequence> resolveCuePatterns(
  HapticPatternStore store,
  Map<String, String> assignments,
) {
  final out = <String, BuzzSequence>{};
  for (final key in const [
    kGestureStartKey,
    kGestureFollowUpKey,
    kGestureConfirmKey,
    kGestureFailedKey,
    kBreathInhaleKey,
    kBreathExhaleKey,
    kBreathHoldKey,
    kBreathDoneKey,
    'tasker.1',
    'tasker.2',
    'tasker.3',
    'tasker.4',
    'tasker.5',
    'tasker.6',
  ]) {
    final given = assignments[key];
    final p = (given == null ? null : store.byId(given)) ??
        store.bySystemKey(key);
    if (p != null) out[key] = p.sequence;
  }
  return out;
}

/// How a pattern is named where a slot says what it plays: a preset or other
/// built-in by its name, the wearer's own as "Your: name".
String patternLabel(SavedHapticPattern p) =>
    p.system ? p.name : 'Your: ${p.name}';

SavedHapticPattern? _byId(List<SavedHapticPattern> all, String? id) {
  if (id == null) return null;
  for (final p in all) {
    if (p.id == id) return p;
  }
  return null;
}

/// The name of the pattern that [seq] (a snapshot held by a rule or channel) is: the
/// stored pattern it was taken from, "Custom" for a rhythm with no stored
/// pattern behind it (recorded by hand, or its pattern was deleted), or
/// [ifNone] when there is no sequence.
String sequenceLabel(
  BuzzSequence? seq,
  List<SavedHapticPattern> patterns, {
  required String ifNone,
}) {
  if (seq == null) return ifNone;
  final p = _byId(patterns, seq.patternId);
  return p == null ? 'Custom' : patternLabel(p);
}

/// What [slotKey] plays now, by name: never a count of buzzes.
String slotPatternLabel(
  String slotKey, {
  required List<SavedHapticPattern> patterns,
  required NotificationPrefs alerts,
  required Map<String, ChannelConfig> channels,
  required Map<String, String> cueAssignments,
}) {
  SavedHapticPattern? own(String key) {
    for (final p in patterns) {
      if (p.systemKey == key) return p;
    }
    return null;
  }

  if (isCueSlot(slotKey)) {
    final given = _byId(patterns, cueAssignments[slotKey]);
    if (given != null) return patternLabel(given);
    return own(slotKey)?.name ?? builtInDefault(slotKey)?.name ?? '—';
  }
  if (slotKey == kRelaySlotKey) {
    return sequenceLabel(
      channels[kRelaySlotChannel]?.buzzSequence,
      patterns,
      ifNone: 'Default rhythm',
    );
  }
  if (!slotKey.startsWith('alert.')) return '—';
  final ruleId = slotKey.substring('alert.'.length);
  return sequenceLabel(
    alerts.alertRule(ruleId).buzzSequence,
    patterns,
    ifNone: own(slotKey)?.name ??
        own(alertPresetKey(slotKey) ?? '')?.name ??
        builtInDefault(slotKey)?.name ??
        '—',
  );
}
