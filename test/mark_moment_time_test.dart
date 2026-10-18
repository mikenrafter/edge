// Mark moment is stamped with EVENT time.
//
// AppState._markMomentFromGesture used to call DateTime.now(): a tap that sat on
// the strap for an hour (or crossed midnight on the way) was filed under the
// minute and the day it ARRIVED. The handler now calls the pure helper
// `momentStampFor(StrapEvent)` and `withMomentTag(...)`, which these tests drive
// directly — no AppState needed.
//
// Every assertion is independent of the machine's time zone. Local instants are
// built with `DateTime(y, m, d, h, min, ...)` and converted to epoch, and the
// expectations are derived from the SAME local fields. To exercise real DST
// transitions, run this file under a DST zone as well:
//   TZ=America/New_York  TZ=Europe/London  TZ=Australia/Lord_Howe  TZ=Asia/Kolkata

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/gestures/moment_stamp.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';

String _two(int x) => x.toString().padLeft(2, '0');
String _ymd(DateTime l) => '${l.year.toString().padLeft(4, '0')}-${_two(l.month)}-${_two(l.day)}';
String _hhmm(DateTime l) => '${_two(l.hour)}:${_two(l.minute)}';

/// A tap whose strap clock reads [at] (a LOCAL wall-clock instant), delivered
/// [delay] later. The subsec is floored so a .999 never rounds up a minute.
StrapEvent _tapAtLocal(DateTime at, {Duration delay = const Duration(seconds: 2)}) {
  final ms = at.millisecondsSinceEpoch;
  return StrapEvent(
    eventId: 14,
    tsEpoch: ms ~/ 1000,
    tsSubsec: ((ms % 1000) * 32768) ~/ 1000,
    receivedAt: at.add(delay),
    hex: '',
    deviceId: 'dev-a',
  );
}

void main() {
  group('event time, not receipt time', () {
    test('a tap delivered three hours late is filed at the minute it happened',
        () {
      final s = momentStampFor(_tapAtLocal(DateTime(2026, 3, 14, 9, 5, 30),
          delay: const Duration(hours: 3)));
      expect(s.date, '2026-03-14');
      expect(s.hhmm, '09:05');
      expect(s.tag, 'moment 09:05');
      expect(s.timeSource, EventTimeSource.strap);
    });

    test('delivery time has no say: +1 s and +3 days give the same stamp', () {
      final at = DateTime(2026, 6, 2, 17, 41, 20);
      final quick = momentStampFor(_tapAtLocal(at));
      final slow = momentStampFor(
          _tapAtLocal(at, delay: const Duration(days: 3)));
      expect((slow.date, slow.hhmm, slow.timeSource),
          (quick.date, quick.hhmm, quick.timeSource));
    });

    test('sub-second precision never rounds a tap into the next minute', () {
      final s = momentStampFor(_tapAtLocal(DateTime(2026, 3, 14, 10, 14, 59, 999)));
      expect(s.hhmm, '10:14');
    });

    test('hours, minutes and months are zero-padded', () {
      final s = momentStampFor(_tapAtLocal(DateTime(2026, 3, 4, 0, 5, 1)));
      expect(s.date, '2026-03-04');
      expect(s.hhmm, '00:05');
    });
  });

  group('midnight', () {
    test('a tap at 23:59:59.9 delivered at 00:00:03 lands on the PREVIOUS day '
        'at 23:59', () {
      final tap = DateTime(2026, 3, 14, 23, 59, 59, 900);
      final e = _tapAtLocal(tap,
          delay: DateTime(2026, 3, 15, 0, 0, 3).difference(tap));
      // The delivery really is on the next local calendar day.
      expect(_ymd(e.receivedAt.toLocal()), '2026-03-15');
      final s = momentStampFor(e);
      expect(s.date, '2026-03-14');
      expect(s.hhmm, '23:59');
    });

    test('a tap just after midnight, delivered a day later, is the NEW day', () {
      final s = momentStampFor(_tapAtLocal(DateTime(2026, 3, 15, 0, 0, 0, 200),
          delay: const Duration(days: 1)));
      expect(s.date, '2026-03-15');
      expect(s.hhmm, '00:00');
    });

    test('every local midnight of 2026 opens its own day, and one second '
        'earlier is still the day before', () {
      for (var i = 0; i < 365; i++) {
        final midnight = DateTime(2026, 1, 1 + i);
        final at = momentStampFor(_tapAtLocal(midnight));
        expect(at.date, _ymd(midnight), reason: 'midnight #$i');
        final before = midnight.subtract(const Duration(seconds: 1));
        final eve = momentStampFor(_tapAtLocal(before));
        expect(eve.date, _ymd(before), reason: '1 s before midnight #$i');
        expect(eve.date, isNot(at.date));
      }
    });
  });

  group('DST: the stamp always names the local day that contains the instant',
      () {
    // Windows around the spring-forward / fall-back dates of the northern and
    // southern hemisphere zones. In a zone without DST these are ordinary days;
    // the assertions hold either way.
    final windows = <DateTime>[
      DateTime(2026, 3, 7), // US spring forward is Mar 8
      DateTime(2026, 3, 28), // EU spring forward is Mar 29
      DateTime(2026, 4, 4), // AU/NZ fall back is Apr 5
      DateTime(2026, 10, 3), // AU/NZ spring forward is Oct 4
      DateTime(2026, 10, 24), // EU fall back is Oct 25
      DateTime(2026, 10, 31), // US fall back is Nov 1
    ];

    test('date and hh:mm equal the local fields of the event instant, and the '
        'instant sits inside that day\'s true local window (not +86400 s)', () {
      for (final w in windows) {
        // 96 hours in 15-minute steps, walked in ELAPSED time so repeated and
        // skipped local hours are both crossed.
        for (var step = 0; step < 96 * 4; step++) {
          final instant = w.add(Duration(minutes: 15 * step));
          final e = _tapAtLocal(instant);
          final s = momentStampFor(e);
          final local = e.strapTime.toLocal();
          expect(s.date, _ymd(local), reason: '$instant');
          expect(s.hhmm, _hhmm(local), reason: '$instant');

          final sec = e.tsEpoch;
          final start = localDayStartSec(s.date)!;
          final end = localDayEndSec(s.date)!;
          expect(sec, greaterThanOrEqualTo(start), reason: '$instant < ${s.date}');
          expect(sec, lessThan(end), reason: '$instant >= end of ${s.date}');
        }
      }
    });

    test('consecutive elapsed hours across a transition never skip a calendar '
        'day or go back one', () {
      for (final w in windows) {
        String? prev;
        for (var h = 0; h < 96; h++) {
          final s = momentStampFor(_tapAtLocal(w.add(Duration(hours: h))));
          if (prev != null) {
            // Consecutive hours: same day, or the very next calendar day.
            final a = DateTime.parse(prev);
            final b = DateTime.parse(s.date);
            expect(calendarDaysBetween(a, b), anyOf(0, 1), reason: '$w +${h}h');
          }
          prev = s.date;
        }
      }
    });
  });

  group('an implausible strap clock falls back to RECEIPT time, and says so', () {
    final received = DateTime(2026, 5, 2, 17, 41, 20);

    StrapEvent bad({required int tsEpoch, int subsec = 0}) => StrapEvent(
          eventId: 14,
          tsEpoch: tsEpoch,
          tsSubsec: subsec,
          receivedAt: received,
          hex: '',
          deviceId: 'dev-a',
        );

    test('unset RTC (epoch 0)', () {
      final s = momentStampFor(bad(tsEpoch: 0));
      expect(s.date, '2026-05-02');
      expect(s.hhmm, '17:41');
      expect(s.timeSource, EventTimeSource.receipt);
    });

    test('a pre-2020 epoch', () {
      final s = momentStampFor(bad(tsEpoch: 1000));
      expect(s.hhmm, '17:41');
      expect(s.timeSource, EventTimeSource.receipt);
    });

    test('a strap clock two hours in the future', () {
      final s = momentStampFor(
          bad(tsEpoch: received.millisecondsSinceEpoch ~/ 1000 + 7200));
      expect(s.hhmm, '17:41');
      expect(s.timeSource, EventTimeSource.receipt);
    });

    test('a corrupt subsec', () {
      final s = momentStampFor(bad(
          tsEpoch: received.millisecondsSinceEpoch ~/ 1000, subsec: 40000));
      expect(s.timeSource, EventTimeSource.receipt);
      expect(s.hhmm, '17:41');
    });

    test('a UTC receipt time is converted to LOCAL before it is labelled', () {
      final utc = DateTime.utc(2026, 5, 2, 23, 30, 0);
      final s = momentStampFor(StrapEvent(
        eventId: 14,
        tsEpoch: 0,
        tsSubsec: 0,
        receivedAt: utc,
        hex: '',
        deviceId: 'dev-a',
      ));
      final local = utc.toLocal();
      expect(s.date, _ymd(local));
      expect(s.hhmm, _hhmm(local));
    });
  });

  group('the journal tag is added once', () {
    final stamp = momentStampFor(_tapAtLocal(DateTime(2026, 3, 14, 9, 5, 30)));

    test('appended to an empty list', () {
      expect(withMomentTag(const [], stamp), ['moment 09:05']);
    });

    test('existing tags survive, in order', () {
      expect(withMomentTag(const ['caffeine', 'late meal'], stamp),
          ['caffeine', 'late meal', 'moment 09:05']);
    });

    test('re-delivery of the same tap adds nothing', () {
      final once = withMomentTag(const ['caffeine'], stamp);
      final twice = withMomentTag(once, stamp);
      expect(twice, once);
      expect(twice.where((t) => t == 'moment 09:05'), hasLength(1));
    });

    test('a tag that is already there is not moved or duplicated', () {
      final tags = ['moment 09:05', 'caffeine'];
      expect(withMomentTag(tags, stamp), ['moment 09:05', 'caffeine']);
    });

    test('a different minute is a different tag', () {
      final later =
          momentStampFor(_tapAtLocal(DateTime(2026, 3, 14, 9, 6, 1)));
      expect(withMomentTag(['moment 09:05'], later),
          ['moment 09:05', 'moment 09:06']);
    });

    test('the input list is never mutated', () {
      final input = <String>['caffeine'];
      withMomentTag(input, stamp);
      expect(input, ['caffeine']);
    });
  });
}
