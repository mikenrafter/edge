// What a candidate official file must satisfy (spec §4.3, §6.2; P1 red:
// "baseline candidate payload fails empty-results/checkpoint requirements").
//
// WHY: a copy of the fork's rows into the target layout looks plausible and the
// receiver accepts it, yet it would serve fork scores as official results and
// feed a fork checkpoint to the target's night reader. The requirements checker
// must reject that baseline and accept a correct payload.
// CLAIM(official-export-no-fork-results), CLAIM(official-export-checkpoint-domain).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/official_export/payload_requirements.dart';
import 'package:openstrap_edge/data/official_export/profile_tables.dart';

import 'candidate_stub.dart';
import 'rich_fixture.dart';
import 'support.dart';

String _kinds(List<PayloadViolation> v) => (v.map((x) => x.kind).toSet().toList()..sort()).join(',');

void main() {
  late RichFixture fx;
  // WHY: receiver day/prune boundaries use rec_ts, even for zero/subsecond ts_ms.
  // catches: MIN(ts_ms)/1000, an unfiltered zero, or ignoring RR rows.
  test('mapped oldest exact second filters rec_ts and ignores ts_ms', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    try {
      for (final table in ['decoded_onehz', 'decoded_rr']) {
        await db.execute('CREATE TABLE $table(rec_ts INTEGER, ts_ms INTEGER)');
        await db.execute('INSERT INTO $table VALUES(NULL, 1), (0, 0), (-1, -1000)');
      }
      expect(await oldestMappedExactSec(db), isNull);
      await db.execute('INSERT INTO decoded_onehz VALUES(1792713600, 0)');
      await db.execute('INSERT INTO decoded_rr VALUES(1792670400, 9999999999999)');
      expect(await oldestMappedExactSec(db), 1792670400);
    } finally {
      await db.close();
    }
  });

  // Each candidate build creates ~80 tables and their triggers: seconds, not ms.
  const slow = Timeout(Duration(minutes: 3));
  setUpAll(() async => fx = await RichFixture.build());
  tearDownAll(() => fx.dispose());

  test('the naive copy of the fork file into the target layout is rejected',
      () async {
    final inv = await fx.inventoryOf(await naiveCopyCandidate(fx));
    final v = checkPayload(
      inv,
      officialProfile,
      target: loadCapture('target_schema_62.json'),
      expectedPrunedBefore: fx.expectedPrunedBefore,
    );
    expect(v.map((x) => x.text), containsAll([
      'day_result', // fork results at several versions incl. algorithm 124
      'day_checkpoint', // a fork DAY-format checkpoint in the target domain
      'sync_cursor:band_cursor', // a hardware cursor
      'compute_freshness:day_algo', // a non-archive freshness key
    ]));
    expect(_kinds(v), contains('droppedTableHasRows'));
    expect(_kinds(v), contains('foreignCursor'));
    expect(_kinds(v), contains('foreignFreshnessKey'));
  }, timeout: slow);

  test('the naive copy carries the fork cursor, not the recomputed edge',
      () async {
    final inv = await fx.inventoryOf(await naiveCopyCandidate(fx));
    final v = checkPayload(
      inv,
      officialProfile,
      target: loadCapture('target_schema_62.json'),
      expectedPrunedBefore: fx.expectedPrunedBefore,
    );
    expect(v.where((x) => x.kind == 'prunedBeforeMismatch'), hasLength(1));
  }, timeout: slow);

  test('a payload that follows the policy has no violation', () async {
    final inv = await fx.inventoryOf(await policyCandidate(fx));
    expect(
      checkPayload(
        inv,
        officialProfile,
        target: loadCapture('target_schema_62.json'),
        expectedPrunedBefore: fx.expectedPrunedBefore,
      ),
      isEmpty,
    );
  }, timeout: slow);

  // WHY: profile decisions must reach rows, not just remain policy metadata.
  test('policy carries wearing and measured calibration outputs', () async {
    final db = await databaseFactoryFfi.openDatabase(await policyCandidate(fx));
    try {
      final devices = await db.query('device', orderBy: 'id');
      expect(devices.map((r) => r['id']).toList(), ['', 'ring-A']);
      expect(devices.map((r) => r['remote_id']).toList(), [null, null]);
      expect(devices.first['wearing'], 2);
      final run = (await db.query('live_step_calibration_run')).single;
      expect((run['p2p_g'], run['confidence'], run['counter_version']), (1.2, 0.83, 2));
    } finally {
      await db.close();
    }
  }, timeout: slow);

  test('wrong schema version and a table the target does not have are caught',
      () async {
    final path = await policyCandidate(fx, userVersion: 58, extraTable: true);
    final v = checkPayload(
      await fx.inventoryOf(path),
      officialProfile,
      target: loadCapture('target_schema_62.json'),
      expectedPrunedBefore: fx.expectedPrunedBefore,
    );
    expect(_kinds(v), allOf(contains('userVersion'), contains('unknownTable')));
  }, timeout: slow);

  test('a day_result without the `imported` column is a layout violation',
      () async {
    final v = checkPayload(
      await fx.inventoryOf(await policyCandidate(fx, dropImported: true)),
      officialProfile,
      target: loadCapture('target_schema_62.json'),
      expectedPrunedBefore: fx.expectedPrunedBefore,
    );
    expect(_kinds(v), contains('layout'));
  }, timeout: slow);
  // WHY: same names do not prove tagged column semantics or receiver objects.
  // catches: names-only layout checks, or ignored index/trigger/view SQL.
  for (final (label, sql) in <(String, String)>[
    ('wrong default', "PRAGMA writable_schema=ON"),
    ('wrong type', "PRAGMA writable_schema=ON"),
    ('wrong nullability', "PRAGMA writable_schema=ON"),
    ('wrong primary key', "PRAGMA writable_schema=ON"),
    ('missing index', 'DROP INDEX idx_band_battery_ts'),
    ('missing trigger', 'DROP TRIGGER trg_day_result_imported_ins'),
    ('missing view', 'DROP VIEW raw_archive_view'),
    ('changed index SQL', 'DROP INDEX idx_band_battery_ts'),
    ('changed view SQL', 'PRAGMA writable_schema=ON'),
  ]) {
    test('$label is a layout violation', () async {
      final path = await policyCandidate(fx);
      final db = await databaseFactoryFfi.openDatabase(path);
      try {
        await db.execute(sql);
        if (label.startsWith('wrong ')) {
          final (old, replacement) = switch (label) {
            'wrong default' => ('imported INTEGER NOT NULL DEFAULT 0', 'imported INTEGER NOT NULL DEFAULT 1'),
            'wrong type' => ('imported INTEGER NOT NULL DEFAULT 0', 'imported TEXT NOT NULL DEFAULT 0'),
            'wrong nullability' => ('imported INTEGER NOT NULL DEFAULT 0', 'imported INTEGER DEFAULT 0'),
            _ => ('PRIMARY KEY (day_id, algo_version)', 'PRIMARY KEY (algo_version, day_id)'),
          };
          await db.rawUpdate('UPDATE sqlite_master SET sql = replace(sql, ?, ?) WHERE name = ?',
              [old, replacement, 'day_result']);
        } else if (label == 'changed view SQL') {
          // Keep both INSTEAD OF triggers: dropping the view also drops them,
          // which could mask a checker that ignores views entirely.
          await db.rawUpdate("UPDATE sqlite_master SET sql = replace(sql, 'lower(hex(frame))', 'upper(hex(frame))') WHERE name = 'raw_archive_view'");
        } else if (label == 'changed index SQL') {
          await db.execute('CREATE INDEX idx_band_battery_ts ON band_battery(ts ASC)');
        }
      } finally {
        await db.close();
      }
      final v = checkPayload(await fx.inventoryOf(path), officialProfile,
          target: loadCapture('target_schema_62.json'),
          expectedPrunedBefore: fx.expectedPrunedBefore);
      expect(v.where((v) => v.kind == 'layout'), isNotEmpty);
      if (label == 'changed view SQL') {
        expect(v.where((v) => v.kind == 'layout').map((v) => v.text).toList(),
            ['view raw_archive_view differs from the tagged release']);
      }
    }, timeout: slow);
  }

  // WHY: a present invalid cursor must not pass as an absent cursor.
  for (final (value, expected, kind) in [
    ('oops', null, 'prunedBeforeUnexpected'),
    ('oops', 123, 'prunedBeforeInvalid'),
    ('123', null, 'prunedBeforeUnexpected'),
  ]) {
    test('cursor $value with expected $expected reports $kind', () async {
      final path = await policyCandidate(fx);
      final db = await databaseFactoryFfi.openDatabase(path);
      try {
        await db.update('sync_cursor', {'value': value},
            where: "name = 'decoded_pruned_before'");
      } finally {
        await db.close();
      }
      final v = checkPayload(await fx.inventoryOf(path), officialProfile,
          target: loadCapture('target_schema_62.json'), expectedPrunedBefore: expected);
      expect(v.map((v) => v.kind), contains(kind));
      if (value == 'oops') expect(v.map((v) => v.kind), contains('prunedBeforeInvalid'));
    }, timeout: slow);
  }

}
