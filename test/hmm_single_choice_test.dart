import 'support/sleep_writes.dart';
// One HMM sleep-staging choice (fix round 1, F2). The upstream key
// `sleep_hmm_stages` is the persisted choice and the worker HMM is the one
// staging owner. The fork's older `compute.experimental_sleep_hmm` key migrates
// into it once and never selects a second classifier (hmm628) in the
// coordinator. Real engine over a real database; one fixed past night.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/frozen_day_result_fixtures.dart';

const _start = 1782532800; // 2026-06-27 04:00 UTC
const _day = '2026-06-27';
const _legacy = 'compute.experimental_sleep_hmm';
const _upstream = 'sleep_hmm_stages';

Future<void> _seed(int seconds) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var i = 0; i < seconds; i++) {
    final ts = _start + i;
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
    batch.insert('decoded_rr', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'beat_index': 0,
      'rr_ts_ms': ts * 1000,
      'rr_ms': i.isEven ? 1000 : 1100,
      'device_family': 'gen4',
    });
  }
  await batch.commit(noResult: true);
  await TestSleepWrites.putSleepOverride(
    dayId: _day,
    onsetTs: _start,
    offsetTs: _start + seconds,
    source: 'manual',
  );
}

Future<Map<String, dynamic>> _sleepSection(DerivationEngine engine) async {
  expect(
    await engine.runDays(const Profile(ageYears: 35), {_day}, force: true),
    1,
  );
  final row = (await LocalDb.dayResult(_day))!;
  final payload = SeriesCodec.decodePayloadJson(row['payload_json'] as String)!;
  return (payload['sleep'] as Map).cast<String, dynamic>();
}

Future<void> _savedPrefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  await Prefs.reload();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(WorkerInit.resetForTest);

  test('the older Labs key alone migrates into the upstream key and stages '
      'through the one worker HMM', () async {
    await _savedPrefs({_legacy: true});
    await freshDb('hmm_single_choice_legacy_test.db');
    addTearDown(dropDb);
    await _seed(5400);
    final sleep = await _sleepSection(DerivationEngine());
    expect(sleep['staging_method'], 'hmm');
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    expect(sp.getBool(_upstream), isTrue);
    expect(sp.containsKey(_legacy), isFalse,
        reason: 'the migration removes the older key');
  });

  test('both keys saved: the coordinator stages nothing itself, the worker HMM '
      'is the only owner and the stored night says so', () async {
    await _savedPrefs({_legacy: true, _upstream: true});
    await freshDb('hmm_single_choice_both_test.db');
    addTearDown(dropDb);
    await _seed(5400);
    final engine = DerivationEngine();
    final candidate = await engine.debugSleepCandidate(_day);
    expect(candidate.sleepJson['staging_method'], 'cardio',
        reason: 'the coordinator keeps the default stager; hmm628 is retired');
    final sleep = await _sleepSection(engine);
    expect(sleep['staging_method'], 'hmm');
    expect(sleep['staging_effective_method'], isNot('hmm628'));
  });

  test('upstream key false and older key true: the opt-in is kept, once',
      () async {
    await _savedPrefs({_legacy: true, _upstream: false});
    await freshDb('hmm_single_choice_conflict_test.db');
    addTearDown(dropDb);
    await _seed(5400);
    final sleep = await _sleepSection(DerivationEngine());
    expect(sleep['staging_method'], 'hmm');
  });

  test('older key false is dropped and nothing selects HMM', () async {
    await _savedPrefs({_legacy: false});
    await freshDb('hmm_single_choice_off_test.db');
    addTearDown(dropDb);
    await _seed(5400);
    final sleep = await _sleepSection(DerivationEngine());
    expect(sleep['staging_method'], 'cardio');
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    expect(sp.containsKey(_legacy), isFalse);
    expect(sp.getBool(_upstream) ?? false, isFalse);
  });
}
