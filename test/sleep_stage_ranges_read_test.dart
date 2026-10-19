// D27: a user's own sleep window stores `sleep.stage_ranges` ({wake, light,
// deep, rem} -> {lo, hi} minutes). The read seam hands it to the Sleep screen
// on the night map: on a staged night, on a typed window the band barely
// recorded (has_sleep false, no point values), and never on a detected night.
//
// Through the production repository over a real database, the way the other
// repository tests do. Fixed past days: nothing here reads the clock.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

Future<void> _put(String day, {Map<String, dynamic>? ranges, bool tst = true}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'date': day,
        'sleep_source': ranges == null ? 'auto' : 'manual',
        'sleep': {
          if (tst)
            'accounting': {
              'value': {
                'tst_sec': 25200,
                'waso_sec': 600,
                'light_sec': 15000,
                'deep_sec': 4800,
                'rem_sec': 5400,
              },
            },
          if (ranges != null)
            'stage_ranges': {'value': ranges, 'confidence': 0.5},
        },
      }),
      windowJson: '{}',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalRepositoryImpl repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_sleep_stage_ranges_read_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = await LocalDb.instance;
    await db.delete('day_result');
  });

  const ranges = {
    'wake': {'lo': 10, 'hi': 30},
    'light': {'lo': 250, 'hi': 250},
    'deep': {'lo': 40, 'hi': 75},
    'rem': {'lo': 80, 'hi': 100},
  };

  test('a typed night carries its stage bounds', () async {
    await _put('2026-05-20', ranges: ranges);
    final n = await repo.getDaySleepV2('2026-05-20');
    expect(n['has_sleep'], isTrue);
    expect(n['stage_ranges'], {
      'wake': {'lo': 10.0, 'hi': 30.0},
      'light': {'lo': 250.0, 'hi': 250.0},
      'deep': {'lo': 40.0, 'hi': 75.0},
      'rem': {'lo': 80.0, 'hi': 100.0},
    });
  });

  test('a typed window with nothing recorded keeps its bounds and no point '
      'value', () async {
    await _put('2026-05-21', tst: false, ranges: {
      for (final s in const ['wake', 'light', 'deep', 'rem'])
        s: {'lo': 0, 'hi': 480},
    });
    final n = await repo.getDaySleepV2('2026-05-21');
    expect(n['has_sleep'], isFalse);
    expect((n['stage_ranges'] as Map).length, 4);
    expect(n.containsKey('deep_min'), isFalse);
    expect(n.containsKey('duration_min'), isFalse);
  });

  test('a detected night has none', () async {
    await _put('2026-05-22');
    final n = await repo.getDaySleepV2('2026-05-22');
    expect(n['has_sleep'], isTrue);
    expect(n.containsKey('stage_ranges'), isFalse);
  });

  test('a malformed bound is dropped, never guessed', () async {
    await _put('2026-05-23', ranges: {
      'wake': {'lo': 30, 'hi': 10}, // inverted
      'light': {'lo': 'x', 'hi': 5}, // not a number
      'deep': {'lo': 40}, // half a bound
      'rem': {'lo': 80, 'hi': 100},
    });
    final n = await repo.getDaySleepV2('2026-05-23');
    expect(n['stage_ranges'], {
      'rem': {'lo': 80.0, 'hi': 100.0},
    });
  });
}
