// A past day whose strain abstained on the quiet level and is FINAL (finalized
// at this version: its raw is gone or its level proven unreachable) must not
// promise "Need N more nights" through the read seam. No later night changes
// that day's figure; the promise is false.
//
// Contract: LocalRepositoryImpl.getDayStrain exposes a final-reason note
// instead of the `need_baseline:` pass-through, both at the top level
// (`note`) and under `absent.strain`. The exact wording of the note is left to
// the implementation; it must be non-empty and must not parse as
// need_baseline (Metric.needMoreNights == null).
// A provisional day still passes the cold-start note through unchanged.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _note = 'need_baseline:have=1,need=3';

Future<void> _put(String day, {required bool finalized}) => LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'absent_notes': {'strain': _note},
        'scalars': {'steps': 100.0},
      }),
      windowJson: '{}',
      finalized: finalized,
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_past_day_final_abstention_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  final repo = LocalRepositoryImpl(getProfileMap: () => const {'age': 30});

  test('a finalized past day does not say "Need N more nights"', () async {
    await _put('2020-04-01', finalized: true);
    final s = await repo.getDayStrain('2020-04-01');
    expect(s['strain'], isNull, reason: 'abstains, never fabricated');

    final top = s['note'] as String?;
    expect(top, isNotNull);
    expect(top, isNotEmpty);
    expect(needMoreNightsFromNote(top), isNull,
        reason: 'top-level note still promises more nights: $top');

    final strain = Metric.parse((s['absent'] as Map)['strain']);
    expect(strain.isEmpty, isTrue);
    expect(strain.note, isNotNull);
    expect(strain.needMoreNights, isNull,
        reason: 'absent.strain note still promises more nights: ${strain.note}');
  });

  test('control: a provisional day keeps the cold-start note', () async {
    await _put('2020-04-02', finalized: false);
    final s = await repo.getDayStrain('2020-04-02');
    expect(s['note'], _note);
    expect(Metric.parse((s['absent'] as Map)['strain']).needMoreNights, 2);
  });
}
