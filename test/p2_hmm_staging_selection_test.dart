import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/sleep_staging_worker.dart';
import 'package:openstrap_edge/compute/staged_sleep_cache.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _start = 1782532800;
const _day = '2026-06-27';
const _inputs = WorkerInputs(
  nowEpochMs: 1782540000000,
  zoneId: 'UTC',
  localeTag: 'en',
);

Substrate _night() => Substrate(
  tsSec: [for (var i = 0; i < 600; i++) _start + i],
  hr: List.filled(600, 60),
  rrTsMs: [for (var i = 0; i < 570; i++) (_start * 1000 + i * 1050).toDouble()],
  rrMs: [for (var i = 0; i < 570; i++) i.isEven ? 1000.0 : 1100.0],
  ax: List.filled(600, 0),
  ay: List.filled(600, 0),
  az: List.filled(600, 1),
  spo2Red: List.filled(600, 1),
  spo2Ir: List.filled(600, 1),
  skinTemp: List.filled(600, 3000),
  skinContact: List.filled(600, 1),
  deviceFamily: 'gen4',
  deviceIds: const {'band'},
);

SleepStagingInput _input({ana.StagingMethod? method}) {
  final sub = _night();
  const override = SleepWindowOverride(
    dayId: _day,
    onsetSec: _start,
    offsetSec: _start + 600,
    source: 'manual',
  );
  // Exercise the actual omitted default, independently of explicit cardio.
  if (method == null) {
    return SleepStagingInput(
      dayId: _day,
      searchSub: sub,
      override: override,
      priorSleep: const [],
      confirmedWakeSec: null,
      profileJson: null,
      mayFold: false,
      rowChunks: const [],
      rowsLoSec: _start,
      rowsHiSec: _start + 600,
      nowSec: _start + 7200,
    );
  }
  return SleepStagingInput(
    dayId: _day,
    searchSub: sub,
    override: override,
    priorSleep: const [],
    confirmedWakeSec: null,
    profileJson: null,
    mayFold: false,
    rowChunks: const [],
    rowsLoSec: _start,
    rowsHiSec: _start + 600,
    nowSec: _start + 7200,
    method: method,
  );
}

(int, int) _digest(SleepStagingInput input) => stagingInputDigest(
  _inputs,
  input,
  zoneKey: 'UTC',
  provenance: const StagingProvenance(
    fromSec: _start,
    toSec: _start + 600,
    revs: {1: 3},
    ownership: {},
    wipeEpoch: 0,
    openCount: 1,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(() {
    WorkerInit.resetForTest();
    ana.cardioUserProfile = null;
    ana.cardioRecordObservations = false;
    ana.resetCardioObservations();
  });

  test('the worker method is part of the staged-night cache identity', () {
    final off = _input(method: ana.StagingMethod.cardio);
    final on = _input(method: ana.StagingMethod.hmm628);
    expect(
      _digest(on),
      isNot(_digest(off)),
      reason: 'a cached cardio night must not serve HMM',
    );
  });

  test(
    'omitted method returns byte-identical cardio candidate and observation',
    () {
      expect(_input().method, ana.StagingMethod.cardio);
      final implicit = stageSleepCandidateHeavy(_inputs, _input());
      final explicit = stageSleepCandidateHeavy(
        _inputs,
        _input(method: ana.StagingMethod.cardio),
      );
      expect(implicit.candidateJson, explicit.candidateJson);
      expect(implicit.observationJson, explicit.observationJson);
      expect(implicit.rowsJson, explicit.rowsJson);
    },
  );

  for (final method in [ana.StagingMethod.cardio, ana.StagingMethod.hmm628]) {
    test(
      '$method real worker returns measured baselines through an isolate',
      () async {
        final result = await Isolate.run(
          () => stageSleepCandidateHeavy(_inputs, _input(method: method)),
        );
        final candidate = jsonDecode(result.candidateJson) as Map;
        final sleep = candidate['sleep_json'] as Map;
        expect(candidate['staging_method'], method.name);
        expect(sleep['staging_method'], method.name);
        if (method == ana.StagingMethod.hmm628) {
          expect(
            sleep.containsKey('stage_ranges'),
            isFalse,
            reason: 'cardio evidence ranges cannot describe HMM labels',
          );
        }
        // Every HR sample is 60; successive alternating 1000/1100 ms RR
        // differences all have magnitude 100, so each epoch's RMSSD is 100.
        expect(sleep['hr_min_night'], 60.0);
        expect(sleep['rmssd_mean_night'], closeTo(100.0, 1e-9));
      },
    );
  }
}
