// Runs candidate official files through the UNCHANGED v0.12.2 receiver
// (`LocalDb.importFromDbFile`, the plain-DB entry point) and checks the prune
// boundary and the unit-key scenarios. Copied into the tagged package by
// harness/run_receiver_scenarios.sh as receiver_scenarios_test.dart.
//
// WHY: only the real receiver can say what a cursor value means ("this day is
// deleted", "this day abstains") and what a REPLACE does to a same-key custom
// definition. A mapper-only test cannot. CLAIM(official-export-actual-receiver),
// CLAIM(official-export-prune-edge), CLAIM(official-export-unit-keys).
//
// Env: CANDIDATES_DIR holds naive.db, nocursor.db, policy.db, units_naive.db,
// units_control.db written by the fork-side write_candidates probe.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'receiver_expectations.dart';
import 'scenario.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

String get _dir => Platform.environment['CANDIDATES_DIR'] ?? 'build/official_probe/candidates';
String get _out => Platform.environment['OFFICIAL_PROBE_OUT'] ?? 'build/official_probe';

Future<T> _withFreshTarget<T>(
  Future<T> Function(Database db) body, {
  Future<void> Function(Database db)? populate,
}) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final root = await Directory.systemTemp.createTemp('official_receiver_');
  PathProviderPlatform.instance = _Paths(root.path);
  LocalDb.dbName = '${root.path}/official.db';
  try {
    final db = await LocalDb.instance;
    expect(LocalDb.schemaVersion, 62);
    if (populate != null) await populate(db);
    return await body(db);
  } finally {
    await LocalDb.close();
    await root.delete(recursive: true);
  }
}

Future<BoundaryObservation> _boundary(String candidate) => _withFreshTarget((db) async {
  await LocalDb.importFromDbFile('$_dir/$candidate');
  final cursor = await LocalDb.getCursorInt(LocalDb.kDecodedPrunedBeforeCursor);
  return BoundaryObservation(
    cursor: cursor,
    deleted: {for (final d in [d3, d4, d5]) d: await LocalDb.decodedPrunedFor(d)},
    abstains: {
      for (final d in [d3, d4, d5]) d: DerivationEngine.windowTruncatedByPrune(d, cursor),
    },
  );
});

Future<UnitObservation> _units(String candidate) => _withFreshTarget(
  (db) async {
    await LocalDb.importFromDbFile('$_dir/$candidate');
    return UnitObservation(
      definitions: {
        for (final r in await db.query('journal_field_def')) '${r['key']}': '${r['unit']}',
      },
      metrics: {
        for (final r in await db.query('journal_metric'))
          ('${r['date']}', '${r['field']}'): (r['value'] as num).toDouble(),
      },
    );
  },
  populate: (db) async {
    // The populated official target already tracks caffeine in MILLIGRAMS.
    await db.insert('journal_field_def', {
      'key': unitKeyCollision, 'label': 'Caffeine', 'kind': 'dose',
      'unit': 'mg', 'max_value': 1000.0, 'step': 10.0, 'has_time': 0, 'created_at': 1,
    });
    await db.insert('journal_metric', {
      'date': '2026-10-22', 'field': unitKeyCollision, 'value': 200.0, 'updated_at': 1,
    });
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{};
  tearDownAll(() async {
    Directory(_out).createSync(recursive: true);
    File('$_out/receiver-scenarios.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  });

  test('process zone is UTC (the literals are UTC epochs)', () {
    expect(DateTime.utc(2026, 7, 1).toLocal().timeZoneOffset, Duration.zero);
  });

  group('prune boundary through the real receiver', () {
    test('control: the policy payload satisfies every expectation', () async {
      final o = await _boundary('policy.db');
      report['boundary/policy'] = {'cursor': o.cursor, 'deleted': o.deleted, 'abstains': o.abstains};
      expect(boundaryViolations(o), isEmpty);
    });

    test('naive copy: the fork-live cursor blocks complete restored days (inverse)',
        () async {
      final o = await _boundary('naive.db');
      report['boundary/naive'] = {'cursor': o.cursor, 'deleted': o.deleted, 'abstains': o.abstains};
      expect(boundaryViolations(o), contains('cursor ${o.cursor}, expected $fixtureExpectedCursor'));
      expect(boundaryViolations(o), contains('complete day $d4 is labelled deleted'));
    });

    test('no cursor row: the cut oldest day is not labelled deleted', () async {
      final o = await _boundary('nocursor.db');
      report['boundary/nocursor'] = {'cursor': o.cursor, 'deleted': o.deleted, 'abstains': o.abstains};
      expect(boundaryViolations(o), contains('cursor null, expected $fixtureExpectedCursor'));
      expect(boundaryViolations(o), contains('cut day $d3 is not labelled deleted'));
      expect(boundaryViolations(o), contains('boundary day $d4 does not abstain'));
    });
  });

  group('populated target, same-label different-unit custom definition', () {
    test('control: mg stays mg and g history gets its own key', () async {
      final o = await _units('units_control.db');
      report['units/control'] = {'definitions': o.definitions, 'metrics': {for (final e in o.metrics.entries) '${e.key.$1}|${e.key.$2}': e.value}};
      expect(unitViolations(o), isEmpty);
    });

    test('naive copy: the g definition replaces the populated mg one', () async {
      final o = await _units('units_naive.db');
      report['units/naive'] = {'definitions': o.definitions, 'metrics': {for (final e in o.metrics.entries) '${e.key.$1}|${e.key.$2}': e.value}};
      expect(unitViolations(o), contains('$unitKeyCollision is g, the populated target had mg'));
    });
  });
}
