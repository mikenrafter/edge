// The four alarm snooze haptic slots: each declared, each its own default
// pattern, none shared with a gesture cue. RED: builtInDefault has no case for
// them and they are in no slot section yet.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_schedule.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';

const _alarmKeys = [
  kAlarmSnoozeConfirmKey,
  kAlarmDismissConfirmKey,
  kAlarmSnoozeCancelledKey,
  kAlarmReAlarmKey,
];

void main() {
  test('the keys', () {
    expect(kAlarmSnoozeConfirmKey, 'alarm.snooze.confirm');
    expect(kAlarmDismissConfirmKey, 'alarm.dismiss.confirm');
    expect(kAlarmSnoozeCancelledKey, 'alarm.snooze.cancelled');
    expect(kAlarmReAlarmKey, 'alarm.snooze.realarm');
  });

  test('each has a built-in default of its own', () {
    for (final k in _alarmKeys) {
      final d = builtInDefault(k);
      expect(d, isNotNull, reason: k);
      expect(d!.key, k);
      expect(d.name, isNotEmpty);
      expect(d.sequence.length, greaterThan(0));
      expect(d.sequence.patternId, systemPatternId(k));
    }
  });

  test('they are seeded with the other built-ins', () {
    expect(builtInKeys(), containsAll(_alarmKeys));
  });

  test('they are listed on the Haptics screen', () {
    final listed = {
      for (final sec in kHapticSlotSections) for (final s in sec.slots) s.key
    };
    expect(listed, containsAll(_alarmKeys));
  });

  test('the three fixed cues differ from one another in notes and beat count',
      () {
    final fixed = [
      kAlarmSnoozeConfirmKey,
      kAlarmDismissConfirmKey,
      kAlarmSnoozeCancelledKey,
    ];
    final notes = [for (final k in fixed) builtInDefault(k)?.sequence.notes];
    expect(notes, everyElement(isNotNull), reason: 'each has a default');
    expect(notes.toSet(), hasLength(3), reason: '$notes');
    final beats = [for (final k in fixed) builtInDefault(k)?.sequence.length];
    expect(beats.toSet(), hasLength(3), reason: 'beat counts $beats');
  });

  test('snooze confirm is very distinct from the gesture cues and the full-'
      'wake confirm (different beat count, different notes)', () {
    final d = builtInDefault(kAlarmSnoozeConfirmKey);
    expect(d, isNotNull, reason: 'a default exists');
    final snooze = d!.sequence;
    for (final k in [
      kGestureStartKey,
      kGestureFollowUpKey,
      kGestureConfirmKey,
      kGestureFailedKey,
    ]) {
      final other = builtInDefault(k)!.sequence;
      expect(snooze.length, isNot(other.length), reason: 'beats vs $k');
      expect(snooze.notes, isNot(other.notes), reason: 'notes vs $k');
    }
  });

  test('the re-alarm slot\'s default is the first snooze\'s pattern', () {
    final d = builtInDefault(kAlarmReAlarmKey);
    expect(d, isNotNull, reason: 'a default exists');
    expect(d!.sequence.notes, const SnoozeSchedule().reAlarmCode(1));
  });
}
