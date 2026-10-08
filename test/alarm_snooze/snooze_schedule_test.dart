// The escalating, erratic re-alarm pattern per snooze index. RED: SnoozeSchedule
// is a stub that throws.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_schedule.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart' show kMaxHapticRuntime;
import 'package:openstrap_edge/haptics/haptic_profile.dart';

int _weight(PatternDynamic? d) => switch (d) {
      PatternDynamic.mf => 1,
      PatternDynamic.f => 2,
      PatternDynamic.ff => 3,
      _ => throw StateError('dynamic $d is outside mf/f/ff'),
    };

/// Felt weight: note length (sixteenths) x dynamic weight.
int _intensity(List<PatternEntry> notes) => [
      for (final e in notes)
        if (e.note) e.length * _weight(e.dynamic),
    ].fold(0, (a, b) => a + b);

int _sixteenths(List<PatternEntry> notes) =>
    notes.fold(0, (a, e) => a + e.length);

void main() {
  const s = SnoozeSchedule();

  test('the default cap is 6', () {
    expect(s.cap, 6);
    expect(kSnoozeCapDefault, 6);
  });

  group('dynamics', () {
    test('only mf, f and ff, on every note, at every index', () {
      for (var i = 1; i <= 30; i++) {
        final notes = s.reAlarmNotes(i);
        expect(notes.where((e) => e.note), isNotEmpty, reason: 'index $i');
        for (final e in notes) {
          if (e.note) {
            expect(
                const {PatternDynamic.mf, PatternDynamic.f, PatternDynamic.ff},
                contains(e.dynamic),
                reason: 'index $i: $e');
          } else {
            expect(e.dynamic, isNull, reason: 'a rest has no dynamic');
          }
        }
      }
    });
  });

  group('escalation', () {
    test('snooze 1 is milder than 2, which is milder than 3', () {
      final a = _intensity(s.reAlarmNotes(1));
      final b = _intensity(s.reAlarmNotes(2));
      final c = _intensity(s.reAlarmNotes(3));
      expect(a, lessThan(b));
      expect(b, lessThan(c));
    });

    test('3 and later are the harshest tier: they use ff, snooze 1 never does',
        () {
      expect(s.reAlarmNotes(1).where((e) => e.dynamic == PatternDynamic.ff),
          isEmpty);
      for (var i = 3; i <= 6; i++) {
        expect(s.reAlarmNotes(i).where((e) => e.dynamic == PatternDynamic.ff),
            isNotEmpty,
            reason: 'index $i');
      }
    });

    test('from 3 to the cap it never gets milder', () {
      var last = _intensity(s.reAlarmNotes(3));
      for (var i = 4; i <= s.cap; i++) {
        final now = _intensity(s.reAlarmNotes(i));
        expect(now, greaterThanOrEqualTo(last), reason: 'index $i');
        last = now;
      }
    });

    test('the first three differ from one another', () {
      final codes = {for (var i = 1; i <= 3; i++) s.reAlarmCode(i)};
      expect(codes, hasLength(3));
    });
  });

  group('the cap', () {
    test('at and past the cap the pattern stops changing', () {
      final atCap = s.reAlarmCode(s.cap);
      for (var i = s.cap; i <= s.cap + 12; i++) {
        expect(s.reAlarmCode(i), atCap, reason: 'index $i');
      }
    });

    test('escalates is true up to the cap and false after', () {
      for (var i = 1; i <= s.cap; i++) {
        expect(s.escalates(i), isTrue, reason: 'index $i');
      }
      expect(s.escalates(s.cap + 1), isFalse);
      expect(s.escalates(s.cap + 50), isFalse);
    });

    test('a smaller cap stops sooner', () {
      const two = SnoozeSchedule(cap: 2);
      expect(two.reAlarmCode(3), two.reAlarmCode(2));
      expect(two.reAlarmCode(9), two.reAlarmCode(2));
      expect(two.reAlarmCode(2), isNot(two.reAlarmCode(1)));
    });

    test('cap 1 never escalates at all', () {
      const one = SnoozeSchedule(cap: 1);
      for (var i = 1; i <= 8; i++) {
        expect(one.reAlarmCode(i), one.reAlarmCode(1));
      }
    });

    test('past the cap it still plays a real, harsh pattern (the wearer is '
        'always eventually woken)', () {
      final past = s.reAlarmNotes(s.cap + 5);
      expect(past.where((e) => e.note), isNotEmpty);
      expect(_intensity(past),
          greaterThanOrEqualTo(_intensity(s.reAlarmNotes(3))));
    });
  });

  group('erratic and playable', () {
    test('beyond snooze 1 the rhythm is uneven: more than one note length or '
        'rest length', () {
      for (var i = 2; i <= s.cap; i++) {
        final notes = s.reAlarmNotes(i);
        final noteLens = {for (final e in notes) if (e.note) e.length};
        final restLens = {for (final e in notes) if (!e.note) e.length};
        expect(noteLens.length + restLens.length, greaterThan(2),
            reason: 'index $i is a metronome: $noteLens / $restLens');
      }
    });

    test('deterministic: the same index is the same pattern', () {
      for (var i = 1; i <= 8; i++) {
        expect(s.reAlarmNotes(i), s.reAlarmNotes(i));
        expect(s.reAlarmCode(i), s.reAlarmCode(i));
      }
    });

    test('an index below 1 reads as 1', () {
      expect(s.reAlarmCode(0), s.reAlarmCode(1));
      expect(s.reAlarmCode(-3), s.reAlarmCode(1));
    });

    test('the code is the notes written out, and parses back', () {
      for (var i = 1; i <= 8; i++) {
        final notes = s.reAlarmNotes(i);
        final code = s.reAlarmCode(i);
        expect(code.split(' ').map(PatternEntry.parse).toList(), notes);
        expect(PatternTranscript.parseCode(code).entries, notes);
      }
    });

    test('every pattern fits the default runtime cap on the MG', () {
      final unit = HapticDeviceProfile.whoopMg.unitMs;
      for (var i = 1; i <= 12; i++) {
        final ms = _sixteenths(s.reAlarmNotes(i)) * unit;
        expect(ms, lessThanOrEqualTo(kMaxHapticRuntime.inMilliseconds),
            reason: 'index $i is $ms ms');
      }
    });
  });
}
