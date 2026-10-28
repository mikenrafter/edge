// HMM staging fix (analytics d876c427), edge side: the stored night keeps the
// provenance of what actually produced its stages, recalculation clears it when
// it no longer applies, and cardio output carries none of it (spec §7 items 1,
// 3, 4 and 5). Real engine over a real database; one fixed past night.

import 'dart:convert';
import 'dart:math' as math;

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
const _fallbackNote =
    'The experimental model showed little stage variation; showing the default estimate.';
const _claim =
    'Experimental sleep-stage estimates. Not validated against a clinical sleep study. Not for medical decisions.';

Future<void> _clearNight() async {
  final db = await LocalDb.instance;
  await db.delete('decoded_onehz');
  await db.delete('decoded_rr');
}

/// Seeds [seconds] of 1 Hz data. [hr] and [rr] give each second's values.
Future<void> _seed(int seconds, int Function(int) hr, int Function(int) rr) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var i = 0; i < seconds; i++) {
    final ts = _start + i;
    batch.insert('decoded_onehz', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': i,
      'hr': hr(i),
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
      'rr_ms': rr(i),
      'device_family': 'gen4',
    });
  }
  await batch.commit(noResult: true);
  await LocalDb.putSleepOverride(
    dayId: _day,
    onsetTs: _start,
    offsetTs: _start + seconds,
    source: 'manual',
  );
}

Future<Map<String, dynamic>> _payload(DerivationEngine engine) async {
  expect(
    await engine.runDays(const Profile(ageYears: 35), {_day}, force: true),
    1,
  );
  final row = (await LocalDb.dayResult(_day))!;
  return SeriesCodec.decodePayloadJson(row['payload_json'] as String)!;
}

Future<Map<String, dynamic>> _sleepSection(DerivationEngine engine) async =>
    ((await _payload(engine))['sleep'] as Map).cast<String, dynamic>();

const _provenanceKeys = [
  'staging_effective_method',
  'staging_fallback',
  'staging_fallback_sec',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(() {
    Prefs.setExperimentalSleepHmm(false);
    WorkerInit.resetForTest();
  });

  test(
    'a flat night under the experimental model falls back, and the stored '
    'night keeps why; switching back to the default clears all of it',
    () async {
      await freshDb('hmm_provenance_engine_test.db');
      addTearDown(dropDb);
      // Flat heart rate and alternating beats: one stage everywhere.
      await _seed(5400, (_) => 60, (i) => i.isEven ? 1000 : 1100);
      final engine = DerivationEngine();

      Prefs.setExperimentalSleepHmm(true);
      final hmm = await _sleepSection(engine);
      expect(hmm['staging_method'], 'hmm628',
          reason: 'staging_method stays the REQUESTED method');
      expect(hmm['staging_effective_method'], 'cardio');
      expect(hmm['staging_fallback'], 'hmm628_degenerate');
      expect(hmm['staging_fallback_sec'], isA<num>());
      expect(hmm['staging_fallback_sec'], greaterThan(0));
      expect(hmm['staging_note'], contains(_claim));
      expect(hmm['staging_note'], contains(_fallbackNote));

      Prefs.setExperimentalSleepHmm(false);
      final cardio = await _sleepSection(engine);
      expect(cardio['staging_method'], 'cardio');
      for (final k in _provenanceKeys) {
        expect(cardio.containsKey(k), isFalse,
            reason: 'recalculation must clear a previous $k');
      }
      expect(cardio['staging_note'], isNot(contains(_fallbackNote)));
    },
  );

  test(
    'a varied night under the experimental model keeps the model and carries '
    'no fallback; a fallback from the earlier calculation is cleared',
    () async {
      await freshDb('hmm_provenance_engine_varied_test.db');
      addTearDown(dropDb);
      final engine = DerivationEngine();
      Prefs.setExperimentalSleepHmm(true);

      await _seed(5400, (_) => 60, (i) => i.isEven ? 1000 : 1100);
      final flat = await _sleepSection(engine);
      expect(flat['staging_fallback'], 'hmm628_degenerate');

      // The same night re-recorded with slow heart-rate cycles and a
      // beat-to-beat spread that follows them: several stages are plausible.
      await _clearNight();
      await _seed(
        5400,
        (i) => (62 + 14 * math.sin(i / 600) + (i % 7)).round(),
        (i) => (950 + 120 * math.sin(i / 900) + (i.isEven ? 40 : -40)).round(),
      );
      final varied = await _sleepSection(engine);
      expect(varied['staging_method'], 'hmm628');
      expect(varied['staging_effective_method'], 'hmm628');
      expect(varied.containsKey('staging_fallback'), isFalse,
          reason: 'the earlier fallback no longer applies');
      expect(varied.containsKey('staging_fallback_sec'), isFalse);
      expect(varied['staging_note'], contains(_claim));
      expect(varied['staging_note'], isNot(contains(_fallbackNote)));
    },
  );

  test(
    'cardio output is untouched by the repin: no provenance keys, the same '
    'stages, and the published night baselines do not depend on the model',
    () async {
      await freshDb('hmm_provenance_engine_cardio_test.db');
      addTearDown(dropDb);
      await _seed(
        5400,
        (i) => (62 + 14 * math.sin(i / 600) + (i % 7)).round(),
        (i) => (950 + 120 * math.sin(i / 900) + (i.isEven ? 40 : -40)).round(),
      );
      final engine = DerivationEngine();
      final cardio = await _payload(engine);
      final cardioSleep = (cardio['sleep'] as Map).cast<String, dynamic>();
      expect(cardioSleep['staging_method'], 'cardio');
      for (final k in _provenanceKeys) {
        expect(cardioSleep.containsKey(k), isFalse, reason: k);
      }
      expect(cardioSleep['staging_note'], isNot(contains('Experimental')));
      final baselines = {
        for (final k in ['hr_min_night', 'rmssd_mean_night'])
          k: (cardio['scalars'] as Map)[k],
      };
      expect(baselines['hr_min_night'], isA<num>());
      expect(baselines['rmssd_mean_night'], isA<num>());

      // Asking for the experimental model moves stages, never the published
      // baselines (they are measured from the first two hours, per night).
      Prefs.setExperimentalSleepHmm(true);
      final hmm = await _payload(engine);
      for (final k in baselines.keys) {
        expect((hmm['scalars'] as Map)[k], baselines[k], reason: k);
      }
      // And back: the cardio night is exactly what it was.
      Prefs.setExperimentalSleepHmm(false);
      final again = await _payload(engine);
      expect(again['sleep'], cardio['sleep']);
      expect(again['scalars'], cardio['scalars']);
    },
  );

  test('the stored payload round-trips through the codec with the keys', () {
    final stored = {
      'sleep': {
        'staging_method': 'hmm628',
        'staging_effective_method': 'mixed',
        'staging_fallback': 'hmm628_degenerate',
        'staging_fallback_sec': 14219,
        'staging_note': '$_claim $_fallbackNote',
      },
    };
    final back = SeriesCodec.decodePayloadJson(
        SeriesCodec.encodePayloadJson(jsonEncode(stored)))!;
    expect(back, stored);
  });
}
