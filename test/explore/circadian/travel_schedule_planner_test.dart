// The schedule-based travel plan (circadian explore, output 3 of 3).
//
// API under test (lib/explore/circadian/travel_schedule_planner.dart):
//   plan(TravelInput) -> TravelPlan
//   shiftHours: whole hours between the zones ON THE DEPARTURE DATE, signed,
//     + = advance (eastward), - = delay (westward)
//   a night belongs to TravelDay.date: it starts at the first moment at/after
//     12:00 local on that date whose wall clock is targetOnset, in TravelDay.tz
//     (so a 00:30 onset is early next morning); wake is the first moment after
//     that with wall clock targetWake
//   days before the departure date are in originTz, from it on in destTz
//   shift(day) = habitual wall-clock night on that date in originTz, minus the
//     planned night, in real elapsed hours (+ = planned earlier). Steps of
//     shift between consecutive days: advance in [0, 1 h], delay in [-1.5, 0].
//     Measuring against the habitual chain keeps DST (either zone) out of the
//     step, and tests catch any 24-hour-day shortcut.
//   the plan starts min(3, steps needed) days before departure (the full 3
//     days whenever more than 3 steps are needed) and ends the first day the
//     target schedule is reached
//   light: only coarse text, only the three phrases, no clock times; none when
//     |shiftHours| >= kAmbiguousShiftHours, with lightSuppressedReason set
//   same offset on the departure date AND no change in the wanted schedule:
//     empty days, shiftHours 0, reason exactly 'no time-zone change'
//     (RED EDIT, Sol P2: was "same offset on the departure date" alone; a
//     desired schedule that differs from the usual one is still planned)
//   unknown IANA name (origin or destination): ArgumentError

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/circadian/travel_schedule_planner.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const _ny = 'America/New_York';
const _london = 'Europe/London';

const _onset = Duration(hours: 23);
const _wake = Duration(hours: 7);

TravelInput _in(
  String origin,
  String dest,
  DateTime dep, {
  Duration? desiredOnset,
  Duration? desiredWake,
}) =>
    TravelInput(
      habitualOnset: _onset,
      habitualWake: _wake,
      originTz: origin,
      destTz: dest,
      departureLocalDate: dep,
      desiredOnset: desiredOnset,
      desiredWake: desiredWake,
    );

int _dayNum(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 86400000;

tz.TZDateTime _nightStart(String zone, DateTime date, Duration clock) {
  final loc = tz.getLocation(zone);
  final next = clock < const Duration(hours: 12) ? 1 : 0;
  return tz.TZDateTime(
      loc, date.year, date.month, date.day + next, clock.inHours, clock.inMinutes % 60);
}

tz.TZDateTime _wakeAfter(tz.TZDateTime onset, Duration clock) {
  var w = tz.TZDateTime(onset.location, onset.year, onset.month, onset.day,
      clock.inHours, clock.inMinutes % 60);
  if (!w.isAfter(onset)) {
    w = tz.TZDateTime(onset.location, onset.year, onset.month, onset.day + 1,
        clock.inHours, clock.inMinutes % 60);
  }
  return w;
}

/// Hours the planned night sits earlier (+) / later (-) than the habitual
/// wall-clock night in the origin zone on the same date.
double _shift(TravelInput i, TravelDay d) {
  final chain = _nightStart(i.originTz, d.date, i.habitualOnset);
  final planned = _nightStart(d.tz, d.date, d.targetOnset);
  return chain.difference(planned).inSeconds / 3600.0;
}

List<double> _shifts(TravelInput i, TravelPlan p) =>
    [for (final d in p.days) _shift(i, d)];

List<double> _steps(List<double> shifts) =>
    [for (var k = 1; k < shifts.length; k++) shifts[k] - shifts[k - 1]];

List<String> _allText(TravelPlan p) => [
      ...p.assumptions,
      if (p.lightSuppressedReason != null) p.lightSuppressedReason!,
      for (final d in p.days)
        if (d.lightHint != null) d.lightHint!,
    ];

const _phrases = ['seek morning light', 'seek evening light', 'avoid bright light'];

final _banned = RegExp(
  r'melatonin|\bmg\b|dose|dosing|medication|internal clock|jet lag cure',
  caseSensitive: false,
);
final _clockText = RegExp(r'\d{1,2}:\d{2}|\d\s?(am|pm)\b', caseSensitive: false);

void _expectStructure(TravelInput i, TravelPlan p, {required int maxPre}) {
  final dep = _dayNum(i.departureLocalDate);
  expect(p.days, isNotEmpty);
  final first = _dayNum(p.days.first.date);
  expect(first, greaterThanOrEqualTo(dep - maxPre));
  expect(first, lessThan(dep), reason: 'starts before departure');
  for (var k = 0; k < p.days.length; k++) {
    if (k > 0) {
      expect(_dayNum(p.days[k].date), _dayNum(p.days[k - 1].date) + 1,
          reason: 'consecutive calendar days');
    }
    final before = _dayNum(p.days[k].date) < dep;
    expect(p.days[k].tz, before ? i.originTz : i.destTz);
    expect(p.days[k].targetOnset, greaterThanOrEqualTo(Duration.zero));
    expect(p.days[k].targetOnset, lessThan(const Duration(hours: 24)));
    expect(p.days[k].targetWake, greaterThanOrEqualTo(Duration.zero));
    expect(p.days[k].targetWake, lessThan(const Duration(hours: 24)));
  }
  expect(_dayNum(p.days.last.date), greaterThanOrEqualTo(dep));
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('the rates and the start window are named consts', () {
    expect(kMaxAdvanceStepPerDay, const Duration(hours: 1));
    expect(kMaxDelayStepPerDay, const Duration(minutes: 90));
    expect(kMaxPreDepartureDays, 3);
    expect(kAmbiguousShiftHours, 10);
  });

  group('New York -> London, 5 h east: advance', () {
    final input = _in(_ny, _london, DateTime(2026, 6, 15));
    late TravelPlan p;
    setUp(() => p = plan(input));

    test('shift is +5, light is not suppressed', () {
      expect(p.shiftHours, 5);
      expect(p.lightSuppressedReason, isNull);
    });

    test('starts 1 to 3 days before departure, one zone per day', () {
      _expectStructure(input, p, maxPre: 3);
    });

    test('5 steps are needed, so it starts the full 3 days ahead', () {
      expect(_dayNum(p.days.first.date),
          _dayNum(input.departureLocalDate) - kMaxPreDepartureDays);
    });

    test('moves earlier by at most 1 h a day, never backwards', () {
      final s = _shifts(input, p);
      expect(s.first, greaterThan(0));
      expect(s.first, lessThanOrEqualTo(1.0 + 1 / 30));
      for (final step in _steps(s)) {
        expect(step, greaterThanOrEqualTo(-1 / 30));
        expect(step, lessThanOrEqualTo(1.0 + 1 / 30));
      }
    });

    test('ends on the destination clock at the habitual times', () {
      final s = _shifts(input, p);
      expect(s.last, closeTo(5.0, 1 / 30));
      expect(s[s.length - 2], lessThan(s.last - 0.1),
          reason: 'no padding after the target is reached');
      expect(p.days.last.tz, _london);
      expect(p.days.last.targetOnset, _onset);
      expect(p.days.last.targetWake, _wake);
    });

    test('sleep length is held at the habitual 8 h on every day', () {
      for (final d in p.days) {
        final on = _nightStart(d.tz, d.date, d.targetOnset);
        final wk = _wakeAfter(on, d.targetWake);
        expect(wk.difference(on), const Duration(hours: 8), reason: '${d.date}');
      }
    });

    test('light hints are morning light only', () {
      final hints = [for (final d in p.days) d.lightHint].whereType<String>();
      expect(hints, isNotEmpty);
      for (final h in hints) {
        final l = h.toLowerCase();
        expect(l, anyOf(_phrases.map(contains).toList()));
        expect(l, isNot(contains('seek evening light')));
      }
      expect(hints.any((h) => h.toLowerCase().contains('seek morning light')),
          isTrue);
    });

    test('the assumptions name the source and say they are assumptions', () {
      expect(p.assumptions, isNotEmpty);
      expect(p.assumptions.any((a) => a.contains('Eastman')), isTrue);
      expect(p.assumptions.any((a) => a.contains('1.5')), isTrue);
      expect(p.assumptions.any((a) => a.toLowerCase().contains('assum')),
          isTrue);
    });
  });

  group('London -> New York, 5 h west: delay', () {
    final input = _in(_london, _ny, DateTime(2026, 6, 15));
    late TravelPlan p;
    setUp(() => p = plan(input));

    test('shift is -5, light is not suppressed', () {
      expect(p.shiftHours, -5);
      expect(p.lightSuppressedReason, isNull);
    });

    test('starts 1 to 3 days before departure, one zone per day', () {
      _expectStructure(input, p, maxPre: 3);
    });

    test('moves later by at most 1.5 h a day, never backwards', () {
      final s = _shifts(input, p);
      expect(s.first, lessThan(0));
      expect(s.first, greaterThanOrEqualTo(-1.5 - 1 / 30));
      for (final step in _steps(s)) {
        expect(step, lessThanOrEqualTo(1 / 30));
        expect(step, greaterThanOrEqualTo(-1.5 - 1 / 30));
      }
      expect(s.last, closeTo(-5.0, 1 / 30));
      expect(s[s.length - 2], greaterThan(s.last + 0.1));
    });

    test('ends on the destination clock at the habitual times', () {
      expect(p.days.last.tz, _ny);
      expect(p.days.last.targetOnset, _onset);
      expect(p.days.last.targetWake, _wake);
    });

    test('light hints are evening light only', () {
      final hints = [for (final d in p.days) d.lightHint].whereType<String>();
      expect(hints, isNotEmpty);
      for (final h in hints) {
        final l = h.toLowerCase();
        expect(l, anyOf(_phrases.map(contains).toList()));
        expect(l, isNot(contains('seek morning light')));
      }
      expect(hints.any((h) => h.toLowerCase().contains('seek evening light')),
          isTrue);
    });
  });

  group('desired destination schedule', () {
    test('the last day lands on it, and the pace limits still hold', () {
      final input = _in(_ny, _london, DateTime(2026, 6, 15),
          desiredOnset: const Duration(hours: 23, minutes: 30),
          desiredWake: const Duration(hours: 7, minutes: 30));
      final p = plan(input);
      expect(p.days.last.tz, _london);
      expect(p.days.last.targetOnset, const Duration(hours: 23, minutes: 30));
      expect(p.days.last.targetWake, const Duration(hours: 7, minutes: 30));
      final s = _shifts(input, p);
      // 23:00 New York is 04:00 London; 04:00 -> 23:30 is 4.5 h earlier.
      expect(s.last, closeTo(4.5, 1 / 30));
      for (final step in _steps(s)) {
        expect(step, lessThanOrEqualTo(1.0 + 1 / 30));
        expect(step, greaterThanOrEqualTo(-1 / 30));
      }
    });
  });

  group('ambiguous direction: no light suggestions', () {
    for (final c in [
      ('12 h (UTC -> Auckland)', 'Etc/UTC', 'Pacific/Auckland'),
      ('10 h (UTC -> Brisbane)', 'Etc/UTC', 'Australia/Brisbane'),
    ]) {
      test('${c.$1}: hints suppressed with a reason, schedule still given', () {
        final input = _in(c.$2, c.$3, DateTime(2026, 6, 15));
        final p = plan(input);
        expect(p.shiftHours.abs(), greaterThanOrEqualTo(kAmbiguousShiftHours));
        expect(p.lightSuppressedReason, isNotNull);
        expect(p.lightSuppressedReason!.trim(), isNotEmpty);
        expect(p.days, isNotEmpty);
        for (final d in p.days) {
          expect(d.lightHint, isNull);
        }
        for (final step in _steps(_shifts(input, p))) {
          expect(step.abs(), lessThanOrEqualTo(1.5 + 1 / 30));
        }
      });
    }

    test('9 h (UTC -> Tokyo) is not ambiguous: hints are given', () {
      final p = plan(_in('Etc/UTC', 'Asia/Tokyo', DateTime(2026, 6, 15)));
      expect(p.shiftHours, 9);
      expect(p.lightSuppressedReason, isNull);
      expect(p.days.any((d) => d.lightHint != null), isTrue);
    });
  });

  group('no time-zone change', () {
    for (final c in [
      ('same zone', _london, _london),
      ('same offset (London / Dublin, June)', _london, 'Europe/Dublin'),
    ]) {
      test(c.$1, () {
        final p = plan(_in(c.$2, c.$3, DateTime(2026, 6, 15)));
        expect(p.days, isEmpty);
        expect(p.shiftHours, 0);
        expect(p.lightSuppressedReason, 'no time-zone change');
      });
    }
  });

  // Sol P2 (planner ~122): equal offsets returned the empty plan before the
  // desired schedule was read, discarding a requested two-hour advance.
  group('same offset, desired schedule changed', () {
    for (final c in [
      ('same zone', _london, _london),
      ('same offset (London / Dublin, June)', _london, 'Europe/Dublin'),
    ]) {
      test('${c.$1}: usual 23:00-07:00, desired 21:00-05:00 is a 2 h advance',
          () {
        final i = _in(c.$2, c.$3, DateTime(2026, 6, 15),
            desiredOnset: const Duration(hours: 21),
            desiredWake: const Duration(hours: 5));
        final p = plan(i);
        expect(p.days, isNotEmpty, reason: 'not "no time-zone change"');
        expect(p.lightSuppressedReason, isNot('no time-zone change'));
        expect(p.shiftHours, 0, reason: 'the zones themselves do not differ');
        _expectStructure(i, p, maxPre: 3);
        expect(p.days.last.targetOnset, const Duration(hours: 21));
        expect(p.days.last.targetWake, const Duration(hours: 5));
        final shifts = _shifts(i, p);
        expect(shifts.last, closeTo(2.0, 1e-9));
        for (final s in _steps(shifts)) {
          expect(s, inInclusiveRange(0.0, 1.0 + 1e-9),
              reason: 'advance at most 1 h a day');
        }
      });
    }
  });

  // Sol P2 (planner ~148, ~159): the clock-of-day conversion drops the calendar
  // displacement across the date line. Honolulu -> Auckland, departing
  // 2026-06-15, 23:00-07:00: the June 14 Honolulu night targets 01:00 (June 15
  // 11:00 UTC) and the June 15 Auckland night targets 23:00 (also June 15 11:00
  // UTC), the same instant twice.
  group('date-line travel: each plan night is a distinct absolute instant', () {
    final minGap = const Duration(hours: 24) - kMaxDelayStepPerDay;

    void expectNightsAdvance(TravelInput i) {
      final p = plan(i);
      expect(p.days.length, greaterThanOrEqualTo(2));
      final onsets = [
        for (final d in p.days) _nightStart(d.tz, d.date, d.targetOnset),
      ];
      for (var k = 1; k < onsets.length; k++) {
        final gap = onsets[k].difference(onsets[k - 1]);
        expect(gap, greaterThan(Duration.zero),
            reason: 'night $k onset ${onsets[k].toUtc()} must come after '
                'night ${k - 1} onset ${onsets[k - 1].toUtc()}');
        expect(gap, greaterThanOrEqualTo(minGap),
            reason: 'nights ${k - 1} -> $k are $gap apart; at least '
                '24 h minus the largest daily shift is expected');
      }
    }

    test('Honolulu -> Auckland (west over the line), departing 2026-06-15', () {
      expectNightsAdvance(
          _in('Pacific/Honolulu', 'Pacific/Auckland', DateTime(2026, 6, 15)));
    });

    // Mirror direction: no duplicate, but a whole night disappears (48 h gap).
    // Same cause, same fix, so it pins the upper side of the spacing too.
    test('Auckland -> Honolulu (east over the line): no night is skipped', () {
      final i =
          _in('Pacific/Auckland', 'Pacific/Honolulu', DateTime(2026, 6, 15));
      expectNightsAdvance(i);
      final onsets = [
        for (final d in plan(i).days) _nightStart(d.tz, d.date, d.targetOnset),
      ];
      for (var k = 1; k < onsets.length; k++) {
        expect(onsets[k].difference(onsets[k - 1]),
            lessThanOrEqualTo(const Duration(hours: 24) + kMaxDelayStepPerDay),
            reason: 'one night per 24 h, not a skipped night');
      }
    });
  });

  group('unknown time zone', () {
    test('origin', () {
      expect(() => plan(_in('Mars/Olympus_Mons', _london, DateTime(2026, 6, 15))),
          throwsArgumentError);
    });
    test('destination', () {
      expect(() => plan(_in(_ny, 'Not/AZone', DateTime(2026, 6, 15))),
          throwsArgumentError);
    });
  });

  group('DST change in the origin during the plan week', () {
    // US spring-forward is Sunday 2026-03-08. Depart Tuesday the 10th: New York
    // is on EDT (-4) and London still on GMT, so the shift is 4 h, not the 5 h
    // of the winter gap the first plan day would show.
    final input = _in(_ny, _london, DateTime(2026, 3, 10));
    late TravelPlan p;
    setUp(() => p = plan(input));

    test('the offsets are read on the departure date', () {
      expect(p.shiftHours, 4);
    });

    test('the plan crosses the change and stays inside the pace limit', () {
      _expectStructure(input, p, maxPre: 3);
      expect(_dayNum(p.days.first.date),
          _dayNum(input.departureLocalDate) - kMaxPreDepartureDays);
      final dates = [for (final d in p.days) d.date];
      expect(dates.any((d) => d.month == 3 && d.day == 8), isTrue,
          reason: 'the plan spans the DST day');
      final s = _shifts(input, p);
      expect(s.first, greaterThan(0));
      expect(s.first, lessThanOrEqualTo(1.0 + 1 / 30));
      for (final step in _steps(s)) {
        expect(step, greaterThanOrEqualTo(-1 / 30));
        expect(step, lessThanOrEqualTo(1.0 + 1 / 30));
      }
      expect(s.last, closeTo(4.0, 1 / 30));
      expect(p.days.last.targetOnset, _onset);
      expect(p.days.last.targetWake, _wake);
    });
  });

  group('wording', () {
    final plans = <String, TravelInput>{
      'NY -> London': _in(_ny, _london, DateTime(2026, 6, 15)),
      'London -> NY': _in(_london, _ny, DateTime(2026, 6, 15)),
      'UTC -> Auckland': _in('Etc/UTC', 'Pacific/Auckland', DateTime(2026, 6, 15)),
      'no change': _in(_london, _london, DateTime(2026, 6, 15)),
    };

    test('nothing says melatonin, a dose, an internal clock or a cure', () {
      for (final e in plans.entries) {
        for (final t in _allText(plan(e.value))) {
          expect(_banned.hasMatch(t), isFalse, reason: '${e.key}: "$t"');
        }
      }
    });

    test('light text is coarse: only the three phrases, never a clock window',
        () {
      for (final e in plans.entries) {
        for (final d in plan(e.value).days) {
          final h = d.lightHint;
          if (h == null) continue;
          expect(_clockText.hasMatch(h), isFalse, reason: '${e.key}: "$h"');
          expect(h.toLowerCase(), anyOf(_phrases.map(contains).toList()),
              reason: '${e.key}: "$h"');
        }
      }
    });
  });
}
