// 8AG-perf P3-C: the intraday calorie series, pure half.
//
// The analytics pin 7334289 has `Calories.minuteEnergy`: `dailyEnergy`'s
// computation, one record per minute. P3 persists it per day. This file pins
// the pure builder; p3_kcal_artifact_test.dart pins what the derive stores and
// the reader serves.
//
// ASSUMED API (new file lib/compute/kcal_minutes.dart, pure, isolate-safe: no
// I/O, no clock, plain maps in and out):
//
//   Map<String, dynamic>? buildKcalMinutes({
//     required Substrate daySub,
//     required Profile profile,
//     required double? restingHr,
//     required int sleepOnsetSec,
//     required int sleepOffsetSec,
//     List<List<int>> stepSpans = const [],   // [startSec, endSec, steps]
//   })
//
// THE MINUTE INPUTS ARE BUILT EXACTLY THE WAY `DerivationEngine.wakeDayEnergy`
// (the canonical day calorie pass) is fed from `_buildWakeDayFeatures`, so the
// series folds back to the day's stored ACTIVE figure:
//
//   * The series is the WAKE series: the per-minute MEAN of the seconds with
//     hr > 0, keyed by `tsSec ~/ 60`, minutes inside [sleepOnsetSec,
//     sleepOffsetSec) left out when `sleepOffsetSec > sleepOnsetSec` (sleep is
//     not exercise: an older sleeper's night would bill as active).
//   * hrmax = estimatedMaxHr(profile.ageYears, daySub.deviceFamily).
//   * cadence = cadenceSpmForMinutes(keys, stepSpans) when stepSpans is not
//     empty, else none.
//   * Null (never a made-up series) when wakeDayEnergy is null: no calorie
//     anchors (age, weight, sex), no height, no resting HR, no wake HR at all
//     (hrmax is Tanaka on age alone: `estimatedMaxHr` ignores the strap family).
//   * `Calories.minuteEnergy` is called over EVERY epoch minute from the first
//     to the last wake minute inclusive, so each record keeps its place on the
//     clock; a minute that is not in the wake series (a gap in the data, or
//     inside the sleep window) is passed with hr 0 AND its cadence MASKED to
//     null, because `dailyEnergy` never sees those minutes either and
//     `minuteEnergy` would otherwise bill a gap minute from cadence alone.
//
// PAYLOAD (JSON-safe, the stored artifact `kcal_minutes|<day>` minus
// bookkeeping):
//
//   {
//     'v': 1,
//     'basal_kcal_per_min': double,             // BMR / 1440
//     'covered_minutes': int,                   // minutes that did not abstain
//     'minutes': [                              // ascending, one per minute
//       {'t': int,                              // epoch SECONDS of the minute
//        'total': double?, 'active': double?, 'basal': double?,
//        'source': 'hr' | 'cadence' | 'rest' | null},
//       ...
//     ],
//   }
//
// An abstained minute has all four fields null (gaps stay gaps, never
// interpolated). A covered minute has total == basal + active, basal ==
// basal_kcal_per_min.
//
// Failure mode today: the library does not exist (the file fails to load).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/kcal_minutes.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/step_cadence.dart';
import 'package:openstrap_edge/compute/substrate.dart';

final int _base = DateTime(2025, 9, 10, 8).millisecondsSinceEpoch ~/ 1000;

const _profile = Profile(
  ageYears: 34,
  weightKg: 72,
  heightCm: 178,
  sex: 'm',
  restingHrManual: 55,
);

// Minute plan (offsets from 08:00):
//   0..39     hr 150 for minutes % 10 < 3, else 70   (HR-billed + rest)
//   40..44    NO SAMPLES (a gap)
//   45..59    hr 70
//   60..81    hr 95, below the HR gate; a 110 spm span covers 60..81 (walking)
//   82..99    hr 70
//   100..104  NO SAMPLES, but a 110 spm span covers it (must NOT bill)
//   105..119  hr 70
//   120..149  SLEEP window, hr 130 (would bill as active if not excluded)
//   150..179  hr 70
const _sleepFrom = 120, _sleepTo = 150;

int? _hrOf(int m) {
  if (m >= 40 && m <= 44) return null;
  if (m >= 100 && m <= 104) return null;
  if (m >= _sleepFrom && m < _sleepTo) return 130;
  if (m >= 60 && m <= 81) return 95;
  if (m < 40) return m % 10 < 3 ? 150 : 70;
  return 70;
}

Substrate _substrate({String? family = 'gen4', bool noHr = false}) {
  final ts = <int>[], hr = <int>[];
  for (var m = 0; m < 180; m++) {
    final h = _hrOf(m);
    if (h == null) continue;
    for (var s = 0; s < 60; s++) {
      ts.add(_base + m * 60 + s);
      hr.add(noHr ? 0 : h + (s % 3)); // non-integer minute means
    }
  }
  final n = ts.length;
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: List<double>.filled(n, 0.0),
    ay: List<double>.filled(n, 0.0),
    az: List<double>.filled(n, 1.0),
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 3000),
    skinContact: List<int>.filled(n, 0),
    deviceFamily: family,
  );
}

// 110 spm over each span, as [start, end, steps].
List<List<int>> _spans() => [
      [_base + 60 * 60, _base + 82 * 60, 110 * 22],
      [_base + 100 * 60, _base + 105 * 60, 110 * 5],
    ];

Map<String, dynamic>? _build({
  Substrate? sub,
  Profile profile = _profile,
  double? restingHr = 55,
  bool sleep = true,
  List<List<int>>? spans,
}) =>
    buildKcalMinutes(
      daySub: sub ?? _substrate(),
      profile: profile,
      restingHr: restingHr,
      sleepOnsetSec: sleep ? _base + _sleepFrom * 60 : 0,
      sleepOffsetSec: sleep ? _base + _sleepTo * 60 : 0,
      stepSpans: spans ?? _spans(),
    );

/// The wake series exactly as `DerivationEngine._perMinuteMeanWake` builds it.
({List<int> keys, List<double> hr}) _wake(Substrate s, int onset, int offset) {
  final buckets = <int, List<double>>{};
  for (var i = 0; i < s.hr.length; i++) {
    if (s.hr[i] <= 0) continue;
    final t = s.tsSec[i];
    if (offset > onset && t >= onset && t < offset) continue;
    (buckets[t ~/ 60] ??= []).add(s.hr[i].toDouble());
  }
  final keys = buckets.keys.toList()..sort();
  return (
    keys: keys,
    hr: [
      for (final k in keys)
        () {
          var sum = 0.0;
          for (final x in buckets[k]!) {
            sum += x;
          }
          return sum / buckets[k]!.length;
        }()
    ],
  );
}

({double active, double basal, double total, double walking}) _expected({
  List<List<int>>? spans,
}) {
  final sub = _substrate();
  final w = _wake(sub, _base + _sleepFrom * 60, _base + _sleepTo * 60);
  final sp = spans ?? _spans();
  final e = DerivationEngine.wakeDayEnergy(
    w.hr,
    profile: _profile,
    restingHr: 55,
    dayMinutes: 1440,
    deviceFamily: 'gen4',
    cadenceSpmPerMin: sp.isEmpty ? null : cadenceSpmForMinutes(w.keys, sp),
  );
  expect(e, isNotNull, reason: 'harness: the fixture must price');
  return e!;
}

List<Map<String, dynamic>> _minutes(Map<String, dynamic> p) =>
    [for (final m in (p['minutes'] as List)) (m as Map).cast<String, dynamic>()];

void main() {
  group('folds back to the day\'s stored active figure', () {
    test('sum of active over covered minutes == wakeDayEnergy().active '
        '(walking term, gap-masked cadence and excluded sleep included)', () {
      final p = _build()!;
      final e = _expected();
      expect(e.walking, greaterThan(0), reason: 'harness: the walk must price');
      var sum = 0.0;
      for (final m in _minutes(p)) {
        sum += (m['active'] as num?)?.toDouble() ?? 0;
      }
      expect(sum, closeTo(e.active, 1e-6));
    });

    test('basal_kcal_per_min * 1440 == the day\'s basal', () {
      final p = _build()!;
      expect((p['basal_kcal_per_min'] as num) * 1440,
          closeTo(_expected().basal, 1e-6));
    });

    test('without any step spans the series still equals the HR-only figure',
        () {
      final p = _build(spans: const [])!;
      final e = _expected(spans: const []);
      var sum = 0.0;
      for (final m in _minutes(p)) {
        sum += (m['active'] as num?)?.toDouble() ?? 0;
      }
      expect(sum, closeTo(e.active, 1e-6));
      expect(_minutes(p).where((m) => m['source'] == 'cadence'), isEmpty);
    });
  });

  group('the series itself', () {
    late Map<String, dynamic> p;
    late List<Map<String, dynamic>> ms;
    setUp(() {
      p = _build()!;
      ms = _minutes(p);
    });

    int idx(int minuteOffset) => ms.indexWhere(
        (m) => m['t'] == _base + minuteOffset * 60);

    test('one record per minute from the first to the last wake minute, '
        'ascending, on the minute', () {
      expect(ms.first['t'], _base);
      expect(ms.last['t'], _base + 179 * 60);
      expect(ms, hasLength(180));
      for (var i = 0; i < ms.length; i++) {
        expect(ms[i]['t'], _base + i * 60);
        expect(ms[i]['t'], isA<int>());
      }
    });

    test('abstained minutes (a gap, the sleep window, a gap with a cadence '
        'span) are null in every field, never interpolated or filled', () {
      for (final m in [40, 42, 44, 100, 102, 104, 120, 135, 149]) {
        final r = ms[idx(m)];
        expect(r['total'], isNull, reason: 'minute $m');
        expect(r['active'], isNull, reason: 'minute $m');
        expect(r['basal'], isNull, reason: 'minute $m');
        expect(r['source'], isNull, reason: 'minute $m');
      }
    });

    test('covered_minutes counts exactly the minutes that did not abstain',
        () {
      final covered = ms.where((m) => m['total'] != null).length;
      expect(p['covered_minutes'], covered);
      expect(covered, 180 - 5 - 5 - 30);
    });

    test('a covered minute: total == basal + active, basal is the constant '
        'rate, active >= 0', () {
      final rate = (p['basal_kcal_per_min'] as num).toDouble();
      for (final m in ms.where((m) => m['total'] != null)) {
        expect((m['basal'] as num).toDouble(), closeTo(rate, 1e-12));
        expect((m['active'] as num).toDouble(), greaterThanOrEqualTo(0));
        expect((m['total'] as num).toDouble(),
            closeTo((m['basal'] as num) + (m['active'] as num), 1e-12));
      }
    });

    test('sources: hr above the gate, cadence for the below-gate walk, rest '
        'otherwise', () {
      expect(ms[idx(1)]['source'], 'hr', reason: 'minute 1: hr 150');
      expect((ms[idx(1)]['active'] as num), greaterThan(0));
      expect(ms[idx(5)]['source'], 'rest', reason: 'minute 5: hr 70');
      expect(ms[idx(5)]['active'], 0);
      expect(ms[idx(70)]['source'], 'cadence', reason: 'hr 95 + 110 spm walk');
      expect((ms[idx(70)]['active'] as num), greaterThan(0));
      expect(ms[idx(90)]['source'], 'rest');
    });

    test('the sleep window really was excluded: billing it would have added '
        'active kcal', () {
      // Harness check on the fixture: hr 130 is at or above the gate, so the
      // 30 sleep minutes WOULD bill if they were part of the series.
      final w = _wake(_substrate(), 0, 0); // no exclusion
      final withSleep = DerivationEngine.wakeDayEnergy(w.hr,
          profile: _profile,
          restingHr: 55,
          dayMinutes: 1440,
          deviceFamily: 'gen4')!;
      expect(withSleep.active, greaterThan(_expected(spans: const []).active));
    });
  });

  group('absent input => no series (never fabricated)', () {
    test('no height', () {
      expect(
          _build(
              profile: const Profile(
                  ageYears: 34, weightKg: 72, sex: 'm', restingHrManual: 55)),
          isNull);
    });
    test('no weight / age / sex (no calorie anchors)', () {
      for (final pr in const [
        Profile(ageYears: 34, heightCm: 178, sex: 'm'),
        Profile(weightKg: 72, heightCm: 178, sex: 'm'),
        Profile(ageYears: 34, weightKg: 72, heightCm: 178),
      ]) {
        expect(_build(profile: pr), isNull);
      }
    });
    test('no resting HR', () {
      expect(_build(restingHr: null), isNull);
    });
    test('no wake heart rate at all', () {
      expect(_build(sub: _substrate(noHr: true)), isNull);
    });
  });

  test('idempotent and JSON-safe: the same inputs give the same payload '
      '(no NaN, nothing non-encodable)', () {
    final a = jsonEncode(_build());
    final b = jsonEncode(_build());
    expect(a, b);
    expect(jsonDecode(a), isA<Map>());
  });
}
