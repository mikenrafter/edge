// RED tests: staging one target day must not segment days it will discard.
//
// `calendarDays` walks every calendar day the search substrate touches; for a
// target-day staging the previous day is fully segmented (~1 s, ~3 s with the
// HR-led fallback) and thrown away. Its only channel into the target is
// `sleepHistory` -> `habitualMidsleepSecFromHistory`, which abstains below 14
// distinct day keys. So below that count the earlier days cannot change the
// target and are skipped; days after the target are never walked.
//
// Seams (substrate.dart): `debugStageEveryWalkedDay` forces the old full walk,
// `debugSegmentedDayCount` counts bodies that ran.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/sleep_staging_worker.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/util/worker_init.dart';

const _inputs =
    WorkerInputs(nowEpochMs: 1760000000000, zoneId: 'UTC', localeTag: 'en');

final DateTime _mid = DateTime(2026, 6, 27);
const String _day = '2026-06-27';
int _h(double hours) =>
    _mid.add(Duration(minutes: (hours * 60).round())).millisecondsSinceEpoch ~/ 1000;

/// A synthetic substrate from [from] to [to] (hours from the target's local
/// midnight). [asleep] intervals are accel-still with low HR and high RMSSD;
/// [hrOnly] intervals have the low HR but keep moving (accel-led detection
/// finds nothing, so the HR-led fallback runs).
Substrate _sub(
  double from,
  double to, {
  List<(double, double)> asleep = const [],
  List<(double, double)> hrOnly = const [],
}) {
  bool inAny(List<(double, double)> l, int t) =>
      l.any((r) => t >= _h(r.$1) && t < _h(r.$2));
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  final rrTs = <double>[], rr = <double>[];
  var nextBeatMs = _h(from) * 1000.0;
  for (var t = _h(from); t < _h(to); t++) {
    final still = inAny(asleep, t);
    final low = still || inAny(hrOnly, t);
    final bpm = low ? 52 + (t % 7) : 80 + (t ~/ 60) % 20 + t % 3;
    ts.add(t);
    hr.add(bpm);
    ax.add(still ? 0.0 : .3 * math.sin(t * .21));
    ay.add(still ? 0.0 : .2 * math.cos(t * .13));
    az.add(still ? 1.0 : 1 + .05 * math.sin(t * .07));
    while (nextBeatMs < (t + 1) * 1000.0) {
      final ibi = 60000.0 / bpm + (low ? 40 : 12) * math.sin(t * (low ? .35 : .9));
      rrTs.add(nextBeatMs);
      rr.add(ibi);
      nextBeatMs += ibi;
    }
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: rrTs,
    rrMs: rr,
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List.filled(ts.length, 1),
    spo2Ir: List.filled(ts.length, 1),
    skinTemp: List.filled(ts.length, 3000),
    skinContact: List.filled(ts.length, 1),
    deviceFamily: 'gen4',
    deviceIds: const {'dev-a'},
  );
}

/// [n] distinct stored days before the target, one 7 h night each.
List<({int startSec, int endSec, String dayKey})> _prior(int n) => [
      for (var i = 0; i < n; i++)
        (
          startSec: _h(-24.0 * (30 - i) - 1),
          endSec: _h(-24.0 * (30 - i) + 6),
          dayKey: localDateLabel(_h(-24.0 * (30 - i) + 6)),
        ),
    ];

String _json(SleepSessionCandidate c) => jsonEncode(c.toJson());

/// The candidate under the old full walk, then under the default path.
({SleepSessionCandidate old, SleepSessionCandidate now}) _both(
  Substrate sub, {
  SleepWindowOverride? override,
  List<({int startSec, int endSec, String dayKey})> prior = const [],
  List<VendorNight> vendor = const [],
}) {
  SleepSessionCandidate run() => prepareSleepSessionCandidate(sub,
      targetDay: _day, override: override, priorSleep: prior, vendorNights: vendor);
  debugStageEveryWalkedDay = true;
  final old = run();
  debugStageEveryWalkedDay = false;
  return (old: old, now: run());
}

void _expectSame(({SleepSessionCandidate old, SleepSessionCandidate now}) r) {
  expect(_json(r.now), _json(r.old));
  expect(r.now.sleepOnsetSec, r.old.sleepOnsetSec);
  expect(r.now.sleepOffsetSec, r.old.sleepOffsetSec);
  expect(r.now.sleepSource, r.old.sleepSource);
  expect(r.now.hypnoStages, r.old.hypnoStages);
}

void main() {
  setUp(() {
    debugStageEveryWalkedDay = false;
    debugSegmentedDayCount = 0;
  });
  tearDown(() {
    debugStageEveryWalkedDay = false;
    WorkerInit.resetForTest();
    ana.cardioRecordObservations = false;
    ana.cardioUserProfile = null;
    ana.resetCardioObservations();
  });

  group('byte identity with the old full walk', () {
    test('a normal previous night and a target night', () {
      final r = _both(_sub(-36, 30, asleep: [(-25, -18), (-1, 6)]));
      expect(r.old.sleepOffsetSec, greaterThan(0), reason: 'fixture stages');
      _expectSame(r);
    });

    test('previous day without an accel-led night (HR-led fallback runs)', () {
      final r = _both(_sub(-36, 30, hrOnly: [(-27, -18)], asleep: [(-1, 6)]));
      _expectSame(r);
    });

    test('target without a night', () {
      _expectSame(_both(_sub(-36, 30, asleep: [(-25, -18)])));
    });

    test('override on the target', () {
      _expectSame(_both(
        _sub(-36, 30, asleep: [(-25, -18), (-1, 6)]),
        override: SleepWindowOverride(
            dayId: _day, onsetSec: _h(-0.5), offsetSec: _h(5.5), source: 'manual'),
      ));
    });

    test('vendor night on the target and on the previous day', () {
      VendorNight night(double a, double b) => VendorNight(
            deviceId: 'v',
            source: 'test',
            decodedAtSec: _h(40),
            epochs: [
              for (var t = _h(a); t < _h(b); t += 30)
                VendorEpoch(t, t + 30,
                    ((t - _h(a)) ~/ 1800) % 3 == 0 ? 'deep' : 'light'),
            ],
          );
      _expectSame(_both(
        _sub(-36, 30, asleep: [(-25, -18), (-1, 6)]),
        vendor: [night(-25, -18), night(-1, 6)],
      ));
    });

    test('worker-shaped search window (target midnight - 12 h onwards)', () {
      _expectSame(_both(_sub(-12, 24, asleep: [(-1, 6)])));
    });
  });

  group('work: only the days that can matter are segmented', () {
    // One earlier day (D-1) in the walk, like a real search window.
    Substrate sub() => _sub(-12, 24, asleep: [(-1, 6)]);

    int segmented({required int stored}) {
      debugSegmentedDayCount = 0;
      prepareSleepSessionCandidate(sub(),
          targetDay: _day, priorSleep: _prior(stored));
      return debugSegmentedDayCount;
    }

    test('empty priorSleep segments exactly the target', () {
      expect(segmented(stored: 0), 1);
    });

    test('12 stored days + 1 earlier walked day (13) still segments one', () {
      expect(segmented(stored: 12), 1);
    });

    test('13 stored days + 1 earlier walked day (14) segments the earlier day '
        'too, and equals the old walk', () {
      expect(segmented(stored: 13), 2);
      _expectSame(_both(sub(), prior: _prior(13)));
    });

    test('the old walk segments every walked day (seam sanity)', () {
      debugStageEveryWalkedDay = true;
      prepareSleepSessionCandidate(sub(), targetDay: _day);
      expect(debugSegmentedDayCount, 2);
    });

    test('a day AFTER the target is never segmented', () {
      final after = _sub(-12, 40, asleep: [(-1, 6), (23, 30)]);
      prepareSleepSessionCandidate(after, targetDay: _day);
      expect(debugSegmentedDayCount, 1);
      debugSegmentedDayCount = 0;
      prepareSleepSessionCandidate(after,
          targetDay: _day, priorSleep: _prior(20));
      // 20 stored >= 14: the earlier day is walked, the later one still not.
      expect(debugSegmentedDayCount, 2);
    });
  });

  group('mayFold observation', () {
    // INTENDED DIFFERENCE from the old walk: the previous night is no longer
    // staged under the target's id, so its observation can no longer win the
    // fold (largest by epochs). The fold sees the target's own night only.
    // The previous night here is deliberately LONGER than the target's so the
    // old walk folds it.
    test('the folded observation is the target night, not the previous one',
        () {
      final s = _sub(-36, 30, asleep: [(-26, -17), (-1, 5)]);
      SleepStagingResult run() => stageSleepCandidateHeavy(
            _inputs,
            SleepStagingInput(
              dayId: _day,
              searchSub: s,
              override: null,
              priorSleep: const [],
              confirmedWakeSec: null,
              profileJson: null,
              mayFold: true,
              rowChunks: const [],
              rowsLoSec: _h(-40),
              rowsHiSec: _h(32),
              nowSec: _h(40),
            ),
          );
      final res = run();
      final cand = jsonDecode(res.candidateJson) as Map<String, dynamic>;
      final win = (cand['sleep_json'] as Map)['window'] as Map;
      final targetEpochs = (win['spt_sec'] as int) ~/ 30;
      expect(targetEpochs, greaterThan(120), reason: 'the target staged a night');
      final obs = jsonDecode(res.observationJson!) as Map<String, dynamic>;
      expect(obs['epochs'] as int, closeTo(targetEpochs, 30),
          reason: 'a 9 h previous night (~1070 epochs) must not win the fold '
              'under the target night (~$targetEpochs epochs)');
    });
  });
}
