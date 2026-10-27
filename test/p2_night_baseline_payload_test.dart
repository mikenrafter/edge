// Measured baseline projections travel in payload_json through the real day
// worker and the one DB writer. No day_result schema columns are needed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/sleep_blank.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/frozen_day_result_fixtures.dart';

const _start = 1782532800; // 2026-06-27 04:00 UTC.

Map<String, dynamic> _bundle({bool measured = true}) => deriveDayBundle(
  DayBundleInput(
    date: kDay,
    dayTsSec: const [_start, _start + 1, _start + 2],
    dayHr: const [80, 80, 80],
    sleepTsSec: const [],
    sleepHr: const [],
    sleepRrTsMs: const [],
    sleepRrMs: const [],
    sleepSkinTemp: const [],
    sleepJson: {
      'tst_sec': 600,
      'window': {'onset_ms': _start * 1000, 'offset_ms': (_start + 600) * 1000},
      if (measured) 'hr_min_night': 43.2,
      if (measured) 'rmssd_mean_night': 32.5,
    },
    hypnoStages: const [],
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    profile: const {'age': 35, 'sex': 'm', 'weight_kg': 75, 'height_cm': 178},
    deviceFamily: 'gen4',
  ).toJson(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('day worker publishes measured baselines, never substitute metrics', () {
    final scalars = _bundle()['scalars'] as Map;
    // Sentinel measurements deliberately differ from daytime HR and any
    // readiness HRV: these are projections, with no fallback computation.
    expect(scalars['hr_min_night'], 43.2);
    expect(scalars['rmssd_mean_night'], 32.5);
    final absent = _bundle(measured: false)['scalars'] as Map;
    expect(absent.containsKey('hr_min_night'), isTrue);
    expect(absent.containsKey('rmssd_mean_night'), isTrue);
    expect(absent['hr_min_night'], isNull);
    expect(absent['rmssd_mean_night'], isNull);
  });

  test(
    'blankNightInBundle clears both measured baselines and keeps day facts',
    () {
      final previous = {
        'scalars': {
          'hr_min_night': 43.2,
          'rmssd_mean_night': 32.5,
          'steps': 4000.0,
        },
      };
      final blanked = blankNightInBundle(
        previous,
        const {},
        source: 'rejected',
      );
      expect((blanked['scalars'] as Map)['hr_min_night'], isNull);
      expect((blanked['scalars'] as Map)['rmssd_mean_night'], isNull);
      expect((blanked['scalars'] as Map)['steps'], 4000.0);
      expect((previous['scalars'] as Map)['hr_min_night'], 43.2);
    },
  );

  group('atomic baseline publication', () {
    late Database db;
    setUp(() async => db = await freshDb('p2_baseline_payload_test.db'));
    tearDown(dropDb);

    Future<bool> publish(
      Map<String, dynamic> payload, {
      bool finalized = false,
    }) => LocalDb.putDayResult(
      dayId: kDay,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode(payload),
      windowJson: '{}',
      finalized: finalized,
      source: 'band',
    );

    test(
      'the day worker baselines survive the production payload writer',
      () async {
        expect(await publish(_bundle()), isTrue);
        final row = (await rowOf(db, kDay))!;
        final payload = SeriesCodec.decodePayloadJson(
          row['payload_json'] as String,
        )!;
        expect((payload['scalars'] as Map)['hr_min_night'], 43.2);
        expect((payload['scalars'] as Map)['rmssd_mean_night'], 32.5);
        final columns = await db.rawQuery('PRAGMA table_info(day_result)');
        expect(columns.map((e) => e['name']), isNot(contains('hr_min_night')));
        expect(
          columns.map((e) => e['name']),
          isNot(contains('rmssd_mean_night')),
        );
      },
    );

    test('a baseline change refuses the entire frozen row write', () async {
      final first = _bundle();
      expect(await publish(first, finalized: true), isTrue);
      final before = (await rowOf(db, kDay))!;
      final changed = jsonDecode(jsonEncode(first)) as Map<String, dynamic>;
      (changed['scalars'] as Map)['hr_min_night'] = 51.0;
      (changed['scalars'] as Map)['rmssd_mean_night'] = 62.0;
      expect(await publish(changed, finalized: true), isFalse);
      expect(await rowOf(db, kDay), before);
    });
  });
}
