import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/sleep_staging_worker.dart';
import 'package:openstrap_edge/compute/staged_sleep_cache.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/frozen_day_result_fixtures.dart';

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
  if (method == null)
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
    Prefs.setExperimentalSleepHmm(false);
    WorkerInit.resetForTest();
    ana.cardioUserProfile = null;
    ana.cardioRecordObservations = false;
    ana.resetCardioObservations();
  });

  test(
    'setting defaults to cardio and switches worker method and cache identity',
    () {
      expect(Prefs.experimentalSleepHmm, isFalse);
      expect(Prefs.sleepStagingMethod, ana.StagingMethod.cardio);
      final off = _input(method: Prefs.sleepStagingMethod);
      expect(off.method, ana.StagingMethod.cardio);
      Prefs.setExperimentalSleepHmm(true);
      expect(Prefs.experimentalSleepHmm, isTrue);
      expect(Prefs.sleepStagingMethod, ana.StagingMethod.hmm628);
      final on = _input(method: Prefs.sleepStagingMethod);
      expect(on.method, ana.StagingMethod.hmm628);
      expect(
        _digest(on),
        isNot(_digest(off)),
        reason: 'a cached cardio night must not serve HMM',
      );
      Prefs.setExperimentalSleepHmm(false);
      expect(_digest(_input(method: Prefs.sleepStagingMethod)), _digest(off));
    },
  );

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

  test(
    'real engine reads the setting, stages on its worker, and publishes baselines',
    () async {
      final db = await freshDb('p2_hmm_engine_selection_test.db');
      addTearDown(dropDb);
      final sub = _night();
      final batch = db.batch();
      for (var i = 0; i < sub.length; i++) {
        final ts = sub.tsSec[i];
        batch.insert('decoded_onehz', {
          'device_id': LocalDb.kPrimaryDeviceId,
          'ts_ms': ts * 1000,
          'rec_ts': ts,
          'counter': i,
          'hr': 60,
          'ax': 0.0,
          'ay': 0.0,
          'az': 1.0,
          'device_family': 'gen4',
        });
      }
      for (var i = 0; i < sub.rrMs.length; i++) {
        final tsMs = sub.rrTsMs[i].toInt();
        final ts = tsMs ~/ 1000;
        batch.insert('decoded_rr', {
          'device_id': LocalDb.kPrimaryDeviceId,
          'ts_ms': ts * 1000,
          'rec_ts': ts,
          'beat_index': 0,
          'rr_ts_ms': tsMs,
          'rr_ms': sub.rrMs[i].toInt(),
          'device_family': 'gen4',
        });
      }
      await batch.commit(noResult: true);
      await LocalDb.putSleepOverride(
        dayId: _day,
        onsetTs: _start,
        offsetTs: _start + 600,
        source: 'manual',
      );
      final engine = DerivationEngine();
      for (final enabled in [false, true, false]) {
        Prefs.setExperimentalSleepHmm(enabled);
        // force is the existing explicit user reanalysis path; switching a
        // preference alone never authorizes rewriting a finalized day.
        expect(
          await engine.runDays(const Profile(ageYears: 35), {
            _day,
          }, force: true),
          1,
        );
        final row = (await LocalDb.dayResult(_day))!;
        final payload = SeriesCodec.decodePayloadJson(
          row['payload_json'] as String,
        )!;
        expect(
          (payload['sleep'] as Map)['staging_method'],
          enabled ? 'hmm628' : 'cardio',
        );
        expect((payload['scalars'] as Map)['hr_min_night'], 60.0);
        expect(
          (payload['scalars'] as Map)['rmssd_mean_night'],
          closeTo(100.0, 1e-9),
        );
        expect(
          engine.debugStagedSleepCacheSize,
          1,
          reason: 'one day is replaced when the selected method changes',
        );
      }
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
