// 8AH, RED. The Data Explorer's pure half: the shared time grid, the line a
// metric becomes on it, normalisation, baselines, and the memory codec. No
// widgets, no database, no clock (every date is fixed).
//
// ASSUMED API (new file lib/compute/explorer_series.dart; pure Dart, no
// flutter/dart:ui import, so it can run under Isolate.run):
//
//   const int    kExploreMaxMetrics = 4;
//   const int    kExploreMinBaselineDays = 7;   // fewest readings a baseline needs
//   const int    kExploreBaselineDays = 28;     // newest N readings make it
//   const double kExploreGapFactor = 1.5;       // a gap is a step > 1.5x the
//                                               // series' own median step
//   enum ExploreRange { d7, d30, m6, y1, custom }
//   extension: int? get days  -> 7 / 30 / 180 / 365 / null for custom
//
//   typedef ExplorePoint = ({int t, double v});     // epoch SECONDS, real value
//   typedef ExploreXY    = ({double at, double y});
//
//   class ExploreWindow {                            // the shared DAY grid
//     final String from, to;                         // inclusive local labels
//     final List<String> days;
//     int get length;
//     factory ExploreWindow.trailing(ExploreRange r, {required String today});
//     factory ExploreWindow.custom(String a, String b);   // swaps a reversed pair
//   }
//
//   class ExploreBaseline { final double mean, sd; const ExploreBaseline(this.mean, this.sd); }
//   ExploreBaseline? exploreBaseline(Iterable<double> history);
//   double exploreZ(double v, ExploreBaseline b);          // (v - mean) / sd
//   double exploreZ01(double v, ExploreBaseline b);        // z clipped to +-3 -> 0..1
//   String? exploreZUnavailable(String key, Iterable<double> history,
//                               {bool intraday = false});  // null = z is on offer
//
//   class ExploreLine {                                    // one metric on the grid
//     final String key;
//     final List<List<({double at, double v})>> runs;      // real values, 0..1 across
//     factory ExploreLine.daily(String key, Iterable<ExplorePoint> pts, ExploreWindow w);
//     factory ExploreLine.intraday(String key, Iterable<ExplorePoint> pts,
//                                  {required int dayStart, required int dayEnd});
//     bool get isEmpty;
//     ({double min, double max})? get extent;
//     double? valueAt(double at);                          // REAL value or null
//     List<List<ExploreXY>> normalised({ExploreBaseline? z}); // min..max, or z
//   }
//
//   enum ExploreBandKind { sleep, nap, workout }
//   class ExploreBand { final ExploreBandKind kind; final double from, to; }
//   List<ExploreBand> exploreBands(Map<String, dynamic> timeline,
//                                  {required int dayStart, required int dayEnd});
//
//   class ExploreIntradaySource { final String key, timelineKey, specKey, label, unit; }
//   const List<ExploreIntradaySource> kExploreIntraday;    // hr hrv resp skin_temp activity calories
//   List<ExplorePoint> exploreIntradayPoints(String key,
//       {Map<String, dynamic>? timeline, Map<String, dynamic>? calories});
//
//   List<String> decodeExploreKeys(String? raw, {required Set<String> valid});
//   String encodeExploreKeys(List<String> keys);
//   ({ExploreRange range, String? from, String? to}) decodeExploreRange(String? raw);
//   String encodeExploreRange(ExploreRange r, {String? from, String? to});
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/explorer_series.dart';
import 'package:openstrap_edge/data/day_label.dart';

/// Noon, local, of [day] — what `getChart` stamps on a daily point.
int _noon(String day) {
  final p = day.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2], 12).millisecondsSinceEpoch ~/ 1000;
}

ExplorePoint _d(String day, double v) => (t: _noon(day), v: v);

/// A point [m] minutes into a day that starts at second 0.
ExplorePoint _m(num m, double v) => (t: (m * 60).round(), v: v);

const _today = '2026-10-04';
// 28 Sep .. 4 Oct.
const _week = [
  '2026-09-28',
  '2026-09-29',
  '2026-09-30',
  '2026-10-01',
  '2026-10-02',
  '2026-10-03',
  '2026-10-04',
];

ExploreWindow _w7() => ExploreWindow.trailing(ExploreRange.d7, today: _today);

List<int> _lens(ExploreLine l) => [for (final r in l.runs) r.length];
List<double> _ats(ExploreLine l) => [
      for (final r in l.runs)
        for (final p in r) p.at,
    ];
List<double> _ys(List<List<ExploreXY>> runs) => [
      for (final r in runs)
        for (final p in r) p.y,
    ];

void main() {
  group('ExploreWindow: the shared day grid', () {
    test('trailing 7 days ends today and is seven local labels', () {
      expect(_w7().days, _week);
      expect(_w7().from, '2026-09-28');
      expect(_w7().to, _today);
      expect(_w7().length, 7);
    });

    test('ranges are 7 / 30 / 180 / 365 days; custom has no fixed length', () {
      expect(ExploreRange.d7.days, 7);
      expect(ExploreRange.d30.days, 30);
      expect(ExploreRange.m6.days, 180);
      expect(ExploreRange.y1.days, 365);
      expect(ExploreRange.custom.days, isNull);
      for (final r in [ExploreRange.d30, ExploreRange.m6, ExploreRange.y1]) {
        final w = ExploreWindow.trailing(r, today: _today);
        expect(w.length, r.days);
        expect(w.days.last, _today);
        expect(w.days.toSet().length, r.days, reason: 'no duplicate day');
      }
    });

    test('calendar arithmetic, not 86400 s: a DST week has seven consecutive days',
        () {
      // Europe fell back on 25 Oct and the US on 1 Nov: this week spans both.
      final w = ExploreWindow.trailing(ExploreRange.d7, today: '2026-11-02');
      expect(w.days, [
        '2026-10-27',
        '2026-10-28',
        '2026-10-29',
        '2026-10-30',
        '2026-10-31',
        '2026-11-01',
        '2026-11-02',
      ]);
      for (var i = 1; i < w.days.length; i++) {
        expect(
            calendarDaysBetween(DateTime.parse(w.days[i - 1]),
                DateTime.parse(w.days[i])),
            1);
      }
    });

    test('custom is inclusive, spans a leap day, and one day is a window', () {
      final w = ExploreWindow.custom('2028-02-27', '2028-03-02');
      expect(w.days,
          ['2028-02-27', '2028-02-28', '2028-02-29', '2028-03-01', '2028-03-02']);
      expect(ExploreWindow.custom('2026-10-04', '2026-10-04').days,
          ['2026-10-04']);
    });

    test('a reversed custom pair is swapped, never an empty window', () {
      final w = ExploreWindow.custom('2026-10-04', '2026-10-01');
      expect(w.from, '2026-10-01');
      expect(w.to, '2026-10-04');
      expect(w.length, 4);
    });
  });

  group('ExploreLine.daily: gaps stay gaps', () {
    test('a missing day breaks the line at that day, with nothing in it', () {
      // 1 Oct (slot 3) was never derived.
      final l = ExploreLine.daily(
          'resting_hr',
          [
            for (final (i, d) in _week.indexed)
              if (i != 3) _d(d, 50.0 + i),
          ],
          _w7());
      expect(_lens(l), [3, 3]);
      expect(_ats(l), [
        for (final i in [0, 1, 2, 4, 5, 6]) closeTo((i + .5) / 7, 1e-9),
      ]);
      expect(l.valueAt(3.5 / 7), isNull, reason: 'the gap reads nothing');
    });

    test('every other day is three isolated dots, never joined', () {
      final l = ExploreLine.daily(
          'hrv', [for (final i in [0, 2, 4]) _d(_week[i], 60.0 + i)], _w7());
      expect(_lens(l), [1, 1, 1]);
    });

    test('leading and trailing holes make no points and no run', () {
      final l = ExploreLine.daily(
          'hrv', [_d(_week[2], 60), _d(_week[3], 62)], _w7());
      expect(_lens(l), [2]);
      expect(_ats(l).first, closeTo(2.5 / 7, 1e-9));
      expect(l.valueAt(0.0), isNull);
      expect(l.valueAt(1.0), isNull);
    });

    test('days outside the window and non-finite values are dropped', () {
      final l = ExploreLine.daily(
          'hrv',
          [
            _d('2026-09-20', 999),
            _d(_week[1], double.nan),
            _d(_week[2], double.infinity),
            _d(_week[3], 61),
            _d('2026-10-09', 999),
          ],
          _w7());
      expect(_lens(l), [1]);
      expect(l.extent, (min: 61.0, max: 61.0),
          reason: 'out-of-window readings must not stretch the scale');
    });

    test('a point belongs to its LOCAL day: 23:30 and 00:30 stay on their days',
        () {
      int at(int d, int h, int m) =>
          DateTime(2026, 10, d, h, m).millisecondsSinceEpoch ~/ 1000;
      final l = ExploreLine.daily(
          'hrv',
          [
            (t: at(2, 23, 30), v: 40.0),
            (t: at(3, 0, 30), v: 50.0),
          ],
          _w7());
      expect(l.valueAt(4.5 / 7), 40, reason: '2 Oct is slot 4');
      expect(l.valueAt(5.5 / 7), 50, reason: '3 Oct is slot 5');
    });

    test('two points on one day: the later one wins, one slot is drawn', () {
      final l = ExploreLine.daily(
          'hrv',
          [
            (t: _noon(_week[3]) - 3600, v: 10.0),
            (t: _noon(_week[3]) + 3600, v: 20.0),
          ],
          _w7());
      expect(_lens(l), [1]);
      expect(l.valueAt(3.5 / 7), 20);
    });

    test('valueAt reads the slot under the position, REAL value, clamped', () {
      final l = ExploreLine.daily('resting_hr',
          [for (final (i, d) in _week.indexed) _d(d, 50.0 + i)], _w7());
      expect(l.valueAt(0.0), 50);
      expect(l.valueAt(0.5), 53);
      expect(l.valueAt(1.0), 56);
      expect(l.valueAt(-0.5), 50);
      expect(l.valueAt(1.5), 56);
    });

    test('no points at all: empty, no extent, nothing normalised', () {
      final l = ExploreLine.daily('hrv', const [], _w7());
      expect(l.isEmpty, isTrue);
      expect(l.runs, isEmpty);
      expect(l.extent, isNull);
      expect(l.normalised(), isEmpty);
      expect(l.valueAt(.5), isNull);
    });
  });

  group('normalisation', () {
    test('each line spans its own min..max over the visible window', () {
      final a = ExploreLine.daily('resting_hr',
          [for (final (i, d) in _week.indexed) _d(d, 100.0 + i * 10)], _w7());
      final b = ExploreLine.daily(
          'hrv', [for (final (i, d) in _week.indexed) _d(d, 1.0 + i * .5)], _w7());
      for (final l in [a, b]) {
        final y = _ys(l.normalised());
        expect(y.first, 0.0);
        expect(y.last, 1.0);
        expect(y[3], closeTo(.5, 1e-9));
      }
    });

    test('values map linearly and gaps keep their break', () {
      final l = ExploreLine.daily(
          'resting_hr',
          [
            _d(_week[0], 10),
            _d(_week[1], 20),
            _d(_week[3], 15),
          ],
          _w7());
      final runs = l.normalised();
      expect([for (final r in runs) r.length], [2, 1]);
      expect(_ys(runs), [closeTo(0, 1e-9), closeTo(1, 1e-9), closeTo(.5, 1e-9)]);
    });

    test('a flat series sits mid-band (0.5), not on the floor and not NaN', () {
      final l = ExploreLine.daily(
          'resting_hr', [for (final d in _week) _d(d, 52)], _w7());
      expect(_ys(l.normalised()), everyElement(0.5));
    });

    test('one reading is mid-band too', () {
      final l = ExploreLine.daily('hrv', [_d(_week[4], 70)], _w7());
      expect(_ys(l.normalised()), [0.5]);
    });

    test('normalised values are always finite and inside 0..1', () {
      final l = ExploreLine.daily('hrv',
          [for (final (i, d) in _week.indexed) _d(d, (i * i).toDouble() - 3)], _w7());
      for (final y in _ys(l.normalised())) {
        expect(y.isFinite, isTrue);
        expect(y, inInclusiveRange(0.0, 1.0));
      }
    });

    test('normalising never moves a point along the time axis', () {
      final l = ExploreLine.daily('hrv',
          [_d(_week[0], 1), _d(_week[1], 3), _d(_week[5], 2)], _w7());
      expect([
        for (final r in l.normalised())
          for (final p in r) p.at
      ], _ats(l));
    });
  });

  group('baseline and z', () {
    const seven = <double>[14, 16, 18, 20, 22, 24, 26];

    test('baseline is the mean and SAMPLE sd of the newest 28 readings', () {
      final b = exploreBaseline(seven)!;
      expect(b.mean, 20);
      expect(b.sd, closeTo(4.3205, 1e-3));

      final long = [for (var i = 0; i < 7; i++) 1000.0, for (var i = 1; i <= 28; i++) i.toDouble()];
      final c = exploreBaseline(long)!;
      expect(c.mean, 14.5, reason: 'older than the newest 28 is ignored');
    });

    test('fewer than 7 real readings is no baseline', () {
      expect(exploreBaseline(seven.take(6)), isNull);
      expect(exploreBaseline(const []), isNull);
      expect(exploreBaseline([...seven.take(6), double.nan]), isNull,
          reason: 'a NaN is not a reading');
    });

    test('a flat history has no spread to measure against', () {
      expect(exploreBaseline(List.filled(10, 52.0)), isNull);
    });

    test('z and its 0..1 form: the mean is the middle, +-3 sd are the ends', () {
      const b = ExploreBaseline(20, 4);
      expect(exploreZ(20, b), 0);
      expect(exploreZ(24, b), 1);
      expect(exploreZ01(20, b), 0.5);
      expect(exploreZ01(24, b), closeTo(4 / 6, 1e-9));
      expect(exploreZ01(32, b), 1.0);
      expect(exploreZ01(50, b), 1.0, reason: 'clipped, not off the canvas');
      expect(exploreZ01(8, b), 0.0);
      expect(exploreZ01(-40, b), 0.0);
    });

    test('a line normalised against a baseline uses z, not min..max', () {
      final l = ExploreLine.daily(
          'resting_hr', [_d(_week[0], 20), _d(_week[1], 24), _d(_week[2], 32)], _w7());
      final y = _ys(l.normalised(z: const ExploreBaseline(20, 4)));
      expect(y, [0.5, closeTo(4 / 6, 1e-9), 1.0]);
      // min..max would have put the first at 0.
      expect(_ys(l.normalised()).first, 0.0);
    });

    test('z is on offer only where a baseline means something', () {
      final hist = [for (var i = 0; i < 28; i++) 50.0 + (i % 5)];
      expect(exploreZUnavailable('resting_hr', hist), isNull);
      expect(exploreZUnavailable('hrv', hist), isNull);
      // Already a distance from a baseline, or a score built against one.
      expect(exploreZUnavailable('skin_temp', hist), isNotNull);
      expect(exploreZUnavailable('readiness', hist), isNotNull);
      // Not enough history: the reason says how many.
      expect(exploreZUnavailable('hrv', hist.take(3)), contains('7'));
      // Flat history.
      expect(exploreZUnavailable('hrv', List.filled(20, 60.0)), isNotNull);
      // Intraday series have no daily baseline.
      expect(exploreZUnavailable('hr', hist, intraday: true), isNotNull);
    });
  });

  group('ExploreLine.intraday: the series own gap rule', () {
    ExploreLine line(List<ExplorePoint> p, {String key = 'hr'}) =>
        ExploreLine.intraday(key, p, dayStart: 0, dayEnd: 86400);

    test('one-minute heart rate breaks where minutes are missing', () {
      final l = line([
        for (var m = 0; m < 10; m++) _m(m, 60.0 + m),
        for (var m = 20; m < 30; m++) _m(m, 70.0 + m),
      ]);
      expect(_lens(l), [10, 10]);
      expect(l.runs.first.first.at, 0.0);
      expect(l.runs.last.first.at, closeTo(20 / 1440, 1e-9));
    });

    test('a 5-minute series is NOT broken by its own sampling step', () {
      // The same 5 min would break a one-minute series; here it is the step.
      final l = line([for (final m in [0, 5, 10, 15, 20]) _m(m, 40.0)],
          key: 'hrv');
      expect(_lens(l), [5]);
    });

    test('one missing sample on a 5-minute series breaks it; none is a hole',
        () {
      final l = line([for (final m in [0, 5, 10, 20, 25]) _m(m, 40.0)],
          key: 'hrv');
      expect(_lens(l), [3, 2], reason: '10 min > 1.5 x the 5 min step');
    });

    test('jitter inside 1.5 steps does not break the line', () {
      final l = line([for (final m in [0, 1, 2, 3.4, 4.4, 5.4]) _m(m, 60.0)]);
      expect(_lens(l), [6]);
    });

    test('readings outside the day, and non-finite ones, are dropped', () {
      final l = line([
        (t: -60, v: 99.0),
        _m(1, 60),
        _m(2, double.nan),
        _m(3, 62),
        (t: 86400, v: 99.0),
        (t: 90000, v: 99.0),
      ]);
      expect(l.extent, (min: 60.0, max: 62.0));
    });

    test('valueAt: the nearest real sample, or nothing in a hole', () {
      final l = line([
        for (var m = 0; m < 10; m++) _m(m, 60.0 + m),
        for (var m = 20; m < 30; m++) _m(m, 70.0 + m),
      ]);
      expect(l.valueAt(5.2 / 1440), 65);
      expect(l.valueAt(25.1 / 1440), 95);
      expect(l.valueAt(15 / 1440), isNull, reason: 'the hole reads nothing');
      expect(l.valueAt(0.9), isNull, reason: 'late evening: nothing recorded');
    });

    test('normalised intraday: 0..1, same x, hole preserved', () {
      final l = line([
        for (var m = 0; m < 3; m++) _m(m, 60.0 + m * 10),
        for (var m = 20; m < 22; m++) _m(m, 70.0),
      ]);
      final runs = l.normalised();
      expect([for (final r in runs) r.length], [3, 2]);
      expect(runs.first.first.y, 0.0);
      expect(runs.first.last.y, 1.0);
      expect(runs.last.first.y, closeTo(.5, 1e-9));
    });
  });

  group('intraday sources', () {
    test('the six intraday metrics, in a fixed order, each with a colour spec',
        () {
      expect([for (final s in kExploreIntraday) s.key],
          ['hr', 'hrv', 'resp', 'skin_temp', 'activity', 'calories']);
      for (final s in kExploreIntraday) {
        expect(s.specKey, isNotEmpty, reason: '${s.key} colours from a MetricSpec');
        expect(s.label, isNotEmpty);
      }
    });

    test('lanes come straight off getDayTimeline; calories off the curve', () {
      final timeline = <String, dynamic>{
        'hr': [
          {'t': 60, 'v': 62},
          {'t': 120, 'v': 0}, // the pipeline's "no lock", not a stopped heart
          {'t': 180, 'v': 64},
        ],
        'hrv': [
          {'t': 300, 'v': 55.5},
        ],
        'resp': [
          {'t': 300, 'v': 14.2},
        ],
        'skin_temp': [
          {'t': 300, 'v': 0.2},
        ],
        'activity': [
          {'t': 300, 'v': 0.4},
          {'t': 600, 'v': 0.0},
        ],
      };
      final calories = <String, dynamic>{
        'minutes': [
          {'t': 60, 'total': 2.0, 'active': 1.5, 'basal': .5},
          {'t': 120, 'total': null, 'active': null, 'basal': null},
          {'t': 180, 'total': 2.5, 'active': 2.0, 'basal': .5},
        ],
      };
      List<double> vs(String k) => [
            for (final p in exploreIntradayPoints(k,
                timeline: timeline, calories: calories))
              p.v
          ];
      expect(vs('hr'), [62, 64], reason: 'hr 0 is no lock');
      expect(vs('hrv'), [55.5]);
      expect(vs('resp'), [14.2]);
      expect(vs('skin_temp'), [0.2]);
      expect(vs('activity'), [0.4, 0.0], reason: 'a measured 0 is a point');
      expect(vs('calories'), [1.5, 2.0],
          reason: 'active energy; the unmeasured minute is not a zero');
      expect([for (final p in exploreIntradayPoints('hr', timeline: timeline)) p.t],
          [60, 180]);
    });

    test('nothing stored is nothing: no points, never a placeholder', () {
      for (final s in kExploreIntraday) {
        expect(exploreIntradayPoints(s.key), isEmpty);
        expect(exploreIntradayPoints(s.key, timeline: const {}, calories: null),
            isEmpty);
      }
      expect(
          exploreIntradayPoints('calories',
              calories: {'minutes': const []}),
          isEmpty);
    });
  });

  group('bands from getDayTimeline', () {
    const start = 1000000, end = start + 86400;
    double f(int sec) => (sec - start) / 86400;

    test('sleep, nap and workout become fractions of the day, in order', () {
      final bands = exploreBands({
        'sleep': [
          {'onset_ts': start + 3600, 'wake_ts': start + 8 * 3600},
        ],
        'naps': [
          {'start': start + 14 * 3600, 'end': start + 15 * 3600},
        ],
        'sessions': [
          {'start_ts': start + 17 * 3600, 'end_ts': start + 18 * 3600},
        ],
      }, dayStart: start, dayEnd: end);
      expect([for (final b in bands) b.kind],
          [ExploreBandKind.sleep, ExploreBandKind.nap, ExploreBandKind.workout]);
      expect(bands[0].from, closeTo(f(start + 3600), 1e-9));
      expect(bands[0].to, closeTo(f(start + 8 * 3600), 1e-9));
      expect(bands[2].from, closeTo(17 / 24, 1e-9));
    });

    test('a night that began yesterday is clipped to midnight, not dropped', () {
      final bands = exploreBands({
        'sleep': [
          {'onset_ts': start - 3600, 'wake_ts': start + 7 * 3600},
        ],
      }, dayStart: start, dayEnd: end);
      expect(bands.single.from, 0.0);
      expect(bands.single.to, closeTo(7 / 24, 1e-9));
    });

    test('reversed, empty and outside spans draw nothing', () {
      final bands = exploreBands({
        'sleep': [
          {'onset_ts': start + 5000, 'wake_ts': start + 4000},
          {'onset_ts': end + 10, 'wake_ts': end + 5000},
        ],
        'sessions': [
          {'start_ts': start + 100, 'end_ts': start + 100},
          {'start_ts': null, 'end_ts': start + 100},
        ],
      }, dayStart: start, dayEnd: end);
      expect(bands, isEmpty);
    });

    test('a day with none of them has no bands and no placeholder', () {
      expect(exploreBands(const {}, dayStart: start, dayEnd: end), isEmpty);
    });
  });

  group('memory codec', () {
    test('keys round-trip; unknown and repeated keys are dropped; capped at 4',
        () {
      const valid = {'hrv', 'resting_hr', 'steps', 'readiness', 'stress'};
      expect(encodeExploreKeys(['hrv', 'steps']), 'hrv,steps');
      expect(decodeExploreKeys('hrv,steps', valid: valid), ['hrv', 'steps']);
      expect(decodeExploreKeys('hrv,nope,hrv,steps', valid: valid),
          ['hrv', 'steps']);
      expect(
          decodeExploreKeys('hrv,steps,readiness,stress,resting_hr', valid: valid),
          ['hrv', 'steps', 'readiness', 'stress']);
      expect(decodeExploreKeys('', valid: valid), isEmpty);
      expect(decodeExploreKeys(null, valid: valid), isEmpty);
      expect(kExploreMaxMetrics, 4);
    });

    test('range round-trips, including a custom span', () {
      for (final r in [
        ExploreRange.d7,
        ExploreRange.d30,
        ExploreRange.m6,
        ExploreRange.y1,
      ]) {
        expect(decodeExploreRange(encodeExploreRange(r)).range, r);
      }
      final c = decodeExploreRange(encodeExploreRange(ExploreRange.custom,
          from: '2026-09-01', to: '2026-09-20'));
      expect(c.range, ExploreRange.custom);
      expect((c.from, c.to), ('2026-09-01', '2026-09-20'));
    });

    test('anything unreadable falls back to 30 days', () {
      for (final bad in [null, '', 'x', 'custom', 'custom:nope..2026-01-01', 'd9']) {
        expect(decodeExploreRange(bad).range, ExploreRange.d30, reason: '$bad');
      }
    });
  });

  group('off the UI isolate', () {
    test('alignment runs under Isolate.run and gives the same lines', () async {
      final pts = [for (final (i, d) in _week.indexed) if (i != 3) _d(d, 50.0 + i)];
      final local = ExploreLine.daily('resting_hr', pts, _w7());
      final remote = await Isolate.run(() {
        final w = ExploreWindow.trailing(ExploreRange.d7, today: _today);
        final l = ExploreLine.daily('resting_hr', pts, w);
        return [
          for (final r in l.normalised())
            [for (final p in r) (p.at, p.y)],
        ];
      });
      expect(remote, [
        for (final r in local.normalised())
          [for (final p in r) (p.at, p.y)],
      ]);
    });

    test('the module imports no Flutter, so it can', () {
      final src = File('lib/compute/explorer_series.dart').readAsStringSync();
      expect(src, isNot(contains('package:flutter')));
      expect(src, isNot(contains('dart:ui')));
    });
  });
}
