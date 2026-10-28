// N2 (review r1): a cardio-requested night's stored candidate
// (sleep_session_candidates.payload_json) must not gain the experimental
// model's provenance keys; an experimental request keeps them. Same filter as
// the day payload (staging_provenance.dart), so every stored representation of
// a cardio night is what 25d754dd wrote.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/sleep_staging_worker.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/util/worker_init.dart';

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


const _provenance = [
  'staging_effective_method',
  'staging_fallback',
  'staging_fallback_sec',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(WorkerInit.resetForTest);

  Future<Map<String, dynamic>> candidate(ana.StagingMethod? m) async {
    final r = await stageSleepCandidateHeavy(_inputs, _input(method: m));
    return jsonDecode(r.candidateJson) as Map<String, dynamic>;
  }

  for (final m in [null, ana.StagingMethod.cardio]) {
    test('cardio candidate ($m) carries no provenance key, in any form',
        () async {
      final c = await candidate(m);
      final sleep = (c['sleep_json'] as Map).cast<String, dynamic>();
      expect(sleep['staging_method'], 'cardio');
      for (final k in _provenance) {
        expect(sleep.containsKey(k), isFalse, reason: k);
      }
      // The same after the stored form is read back and written again.
      final again = SleepSessionCandidate.fromJson(c).toJson();
      for (final k in _provenance) {
        expect((again['sleep_json'] as Map).containsKey(k), isFalse, reason: k);
      }
    });
  }

  test('an experimental candidate keeps its provenance', () async {
    final c = await candidate(ana.StagingMethod.hmm628);
    final sleep = (c['sleep_json'] as Map).cast<String, dynamic>();
    expect(sleep['staging_method'], 'hmm628');
    expect(sleep['staging_effective_method'], isA<String>());
  });
}
