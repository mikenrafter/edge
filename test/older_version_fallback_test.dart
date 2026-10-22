// The read seam serves an older algo_version's stored value when the current
// row lacks it, WITH provenance: `from_older_version: {<key>: {version,
// reason}}` on the day shape and `from_older_version` / `older_version_reason`
// on the Metric envelope. The value is the older one verbatim; every fallback
// field is flagged on its own; nothing is invented when no older row has it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _age = 'need_input:name=age';

Future<void> _put(String day, int version,
        {Map<String, dynamic> scalars = const {},
        Map<String, dynamic> notes = const {}}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: version,
      payloadJson: jsonEncode({
        'date': day,
        'scalars': scalars,
        if (notes.isNotEmpty) 'absent_notes': notes,
      }),
      windowJson: '{}',
      finalized: true,
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_older_version_fallback_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  final repo = LocalRepositoryImpl(getProfileMap: () => const {'age': 30});

  test('a current row with no strain serves the older value, labelled',
      () async {
    const day = '2020-06-01';
    await _put(day, 104, scalars: {'strain': 12.3});
    await _put(day, kAlgoVersion,
        scalars: {'steps': 100.0}, notes: {'strain': _age});
    final s = await repo.getDayStrain(day);
    expect(s['strain'], 12.3);
    final from = (s['from_older_version'] as Map)['strain'] as Map;
    expect(from['version'], 104);
    expect(from['reason'], _age);
    expect((s['absent'] as Map).containsKey('strain'), isFalse);
  });

  test('no older value: stays null and absent, nothing is invented', () async {
    const day = '2020-06-02';
    await _put(day, 104, scalars: {'steps': 5.0});
    await _put(day, kAlgoVersion,
        scalars: {'steps': 100.0}, notes: {'strain': _age});
    final s = await repo.getDayStrain(day);
    expect(s['strain'], isNull);
    expect(s['from_older_version'] ?? const {}, isEmpty);
    expect((s['absent'] as Map).containsKey('strain'), isTrue);
  });

  test('each fallback field is flagged on its own; present fields are never '
      'replaced', () async {
    const day = '2020-06-03';
    await _put(day, 103, scalars: {'trimp': 55.0});
    await _put(day, 104,
        scalars: {'strain': 12.3, 'trimp': 99.0, 'calories': 2100.0});
    await _put(day, kAlgoVersion, scalars: {
      'calories': 2000.0
    }, notes: {
      'strain': _age,
      'trimp': _age,
    });
    final s = await repo.getDayStrain(day);
    expect(s['calories'], 2000, reason: 'the current value wins, unflagged');
    expect(s['strain'], 12.3);
    expect(s['training_load'], 99.0, reason: 'newest older row holding it');
    final from = (s['from_older_version'] as Map).cast<String, Map>();
    expect(from.keys.toSet(), {'strain', 'training_load'});
    expect(from['strain']!['version'], 104);
    expect(from['training_load']!['version'], 104);
  });

  test('a day with only its current row has no provenance', () async {
    const day = '2020-06-04';
    await _put(day, kAlgoVersion, scalars: {'strain': 8.0});
    final s = await repo.getDayStrain(day);
    expect(s['strain'], 8.0);
    expect(s['from_older_version'] ?? const {}, isEmpty);
  });

  test('getToday: the strain Metric carries the provenance', () async {
    final day = todayLabel();
    await _put(day, 104, scalars: {'strain': 9.5});
    await _put(day, kAlgoVersion,
        scalars: {'steps': 100.0}, notes: {'strain': _age});
    final daily = (await repo.getToday())['daily'] as Map;
    final m = Metric.parse(daily['strain']);
    expect(m.value, 9.5);
    expect(m.fromOlderVersion, 104);
    expect(m.olderVersionReason, _age);
  });

  test('Metric.parse carries the provenance', () {
    final m = Metric.parse({
      'value': 12.3,
      'confidence': 0.8,
      'tier': 'ESTIMATE',
      'from_older_version': 104,
      'older_version_reason': _age,
    });
    expect(m.fromOlderVersion, 104);
    expect(m.olderVersionReason, _age);
    expect(Metric.parse({'value': 1, 'confidence': 1}).fromOlderVersion, isNull);
    expect(Metric.empty.olderVersionReason, isNull);
  });
}
