// RED tests (D36, owner chose "fix + bump"): a folding staging folds ONLY the
// target night's own observation into the personal profile, never the largest
// night of the whole calendar walk. Because the fold no longer reads other
// days, the previous-day skip (substrate.dart calendarDays) also applies when
// mayFold is true. kAlgoVersion moves by one and the staged-sleep cache, keyed
// by it, must not serve entries staged under the old fold.

import 'dart:convert';
import 'dart:math' as math;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/staged_sleep_cache.dart';
import 'package:openstrap_edge/compute/sleep_staging_worker.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/util/worker_init.dart';

const _inputs = WorkerInputs(
  nowEpochMs: 1760000000000,
  zoneId: 'UTC',
  localeTag: 'en',
);

final DateTime _mid = DateTime(2026, 6, 27);
const String _day = '2026-06-27';
int _h(double hours) =>
    _mid.add(Duration(minutes: (hours * 60).round())).millisecondsSinceEpoch ~/
    1000;

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
      final ibi =
          60000.0 / bpm + (low ? 40 : 12) * math.sin(t * (low ? .35 : .9));
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

SleepStagingResult _run(
  Substrate s, {
  required bool mayFold,
  List<({int startSec, int endSec, String dayKey})> prior = const [],
}) {
  return stageSleepCandidateHeavy(
    _inputs,
    SleepStagingInput(
      dayId: _day,
      searchSub: s,
      override: null,
      priorSleep: prior,
      confirmedWakeSec: null,
      profileJson: null,
      mayFold: mayFold,
      rowChunks: const [],
      rowsLoSec: _h(-40),
      rowsHiSec: _h(32),
      nowSec: _h(40),
    ),
  );
}

int _targetEpochs(SleepStagingResult r) {
  final cand = jsonDecode(r.candidateJson) as Map<String, dynamic>;
  final win = (cand['sleep_json'] as Map)['window'] as Map;
  return (win['spt_sec'] as int) ~/ 30;
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

  // The previous night (9 h) is deliberately LONGER than the target's (6 h).
  Substrate both() => _sub(-36, 30, asleep: [(-26, -17), (-1, 5)]);
  group('the fold takes the target night only', () {
    test("a 9 h previous night and a 6 h target: the target's own epochs", () {
      final res = _run(both(), mayFold: true);
      final t = _targetEpochs(res);
      expect(t, greaterThan(120));
      expect(res.observationJson, isNotNull);
      final obs = jsonDecode(res.observationJson!) as Map<String, dynamic>;
      expect(
        (obs['epochs'] as int) - t,
        inInclusiveRange(-30, 30),
        reason: 'the previous night (~1068 epochs) must not win the fold',
      );
    });

    test(
      'a target without a night folds nothing, whatever the day before has',
      () {
        final res = _run(_sub(-36, 30, asleep: [(-26, -17)]), mayFold: true);
        expect(res.observationJson, isNull);
      },
    );
  });

  group('the previous-day skip applies to folding passes', () {
    test('< 14 stored nights: one day segmented, target and fold exact', () {
      debugStageEveryWalkedDay = true;
      debugSegmentedDayCount = 0;
      final old = _run(both(), mayFold: true);
      expect(
        debugSegmentedDayCount,
        greaterThan(1),
        reason: 'seam sanity: the old walk segments the earlier days',
      );
      debugStageEveryWalkedDay = false;
      debugSegmentedDayCount = 0;
      final now = _run(both(), mayFold: true);
      expect(debugSegmentedDayCount, 1);
      expect(now.candidateJson, old.candidateJson);
      expect(now.observationJson, isNotNull);
      final obs = jsonDecode(now.observationJson!) as Map<String, dynamic>;
      expect(
        (obs['epochs'] as int) - _targetEpochs(now),
        inInclusiveRange(-30, 30),
      );
    });

    test('13 stored nights + the walked day (14): the old walk still runs', () {
      final prior = _prior(13);
      debugStageEveryWalkedDay = true;
      debugSegmentedDayCount = 0;
      final old = _run(both(), mayFold: true, prior: prior);
      final oldBodies = debugSegmentedDayCount;
      debugStageEveryWalkedDay = false;
      debugSegmentedDayCount = 0;
      final now = _run(both(), mayFold: true, prior: prior);
      expect(oldBodies, greaterThan(1));
      // The old walk also segments the day AFTER the target (the data runs to
      // 06:00 the next morning); no pass ever does that any more, so the
      // earlier days are all kept and only that later day is dropped.
      expect(debugSegmentedDayCount, oldBodies - 1);
      expect(now.candidateJson, old.candidateJson);
      final obs = jsonDecode(now.observationJson!) as Map<String, dynamic>;
      expect(
        (obs['epochs'] as int) - _targetEpochs(now),
        inInclusiveRange(-30, 30),
      );
    });
  });

  group('algo version and cache', () {
    final src = File('lib/compute/derivation_engine.dart').readAsStringSync();
    final m = RegExp(r'const int kAlgoVersion = (\d+);').firstMatch(src)!;

    test('kAlgoVersion is one more than before D36 (114 -> 115)', () {
      // 114 was the value when this test was written; the fold fix changes
      // stored output (AGENTS 3.4), so exactly one bump.
      expect(kAlgoVersion, 115);
    });

    test('the changelog block above the constant names D36', () {
      final lines = src.substring(0, m.start).split('\n');
      var i = lines.length - 1;
      while (i >= 0 && lines[i].trim().isEmpty) {
        i--;
      }
      final block = <String>[];
      while (i >= 0 && lines[i].trimLeft().startsWith('//')) {
        block.insert(0, lines[i]);
        i--;
      }
      expect(block.join('\n'), contains('D36'));
    });

    test('the staged-sleep cache misses an entry staged under the previous '
        'version', () {
      final cache = StagedSleepCache();
      cache.store(
        _day,
        StagedSleepEntry(
          algoVersion: kAlgoVersion - 1,
          digestA: 1,
          digestB: 2,
          stagedWithFold: true,
          candidateJson: '{}',
          observationJson: null,
        ),
        4,
      );
      expect(cache.lookup(_day, kAlgoVersion, (1, 2), mayFold: true), isNull);
    });
  });
}
