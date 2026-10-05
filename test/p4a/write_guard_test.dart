// P4a: the putDayResult guard. A provisional row stays replaceable; a finalized
// (day, V) row refuses any further write at the same V and is left byte-for-byte
// as it was (day_result, metric_series and metric_series_version alike); a new
// version writes a NEW sibling row. Assumed API: see support.dart (nothing new
// is referenced here, so this file compiles today and fails on behaviour).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUp(() async => db = await freshDb('openstrap_p4a_write_guard_test.db'));
  tearDownAll(dropDb);

  group('a provisional row stays replaceable', () {
    test('a second derive write replaces payload, computed_at and series',
        () async {
      await seedRow(db, kDay, finalized: false);

      await deriveWrite(kDay, tag: 'second', rhr: 61.0);

      final row = (await rowOf(db, kDay))!;
      expect(row['payload_json'], payloadOf('second', rhr: 61.0));
      expect(row['computed_at'], isNot(kSeedComputedAt),
          reason: 'a real write stamps the clock');
      expect(row['rhr'], 61.0);
      expect(await seriesOf(db, kDay, 'rhr'), 61.0);
      expect(await seriesOf(db, kDay, 'readiness'), 44.0);
    });

    test('a provisional row can be replaced again and again', () async {
      await seedRow(db, kDay, finalized: false);
      await deriveWrite(kDay, tag: 'one', rhr: 61.0);
      await deriveWrite(kDay, tag: 'two', rhr: 62.0);
      await deriveWrite(kDay, tag: 'three', rhr: 63.0);
      expect((await rowOf(db, kDay))!['payload_json'],
          payloadOf('three', rhr: 63.0));
      expect(await seriesOf(db, kDay, 'rhr'), 63.0);
    });

    test('a partial provisional row is completed by a later write', () async {
      await seedRow(db, kDay, partial: true);
      await deriveWrite(kDay, tag: 'complete', partial: false);
      final row = (await rowOf(db, kDay))!;
      expect(row['partial'], 0);
      expect(row['payload_json'], payloadOf('complete', rhr: 61.0));
    });

    test('finalizing is itself a legal write; the row is frozen after it',
        () async {
      await seedRow(db, kDay, finalized: false);
      await deriveWrite(kDay, tag: 'final', finalized: true, rhr: 61.0);
      expect((await rowOf(db, kDay))!['finalized'], 1);
      expect((await rowOf(db, kDay))!['payload_json'],
          payloadOf('final', rhr: 61.0));

      await deriveWrite(kDay, tag: 'late', rhr: 99.0);
      expect((await rowOf(db, kDay))!['payload_json'],
          payloadOf('final', rhr: 61.0),
          reason: 'frozen from the moment it finalized');
    });

    test('a skip marker over a provisional row is still a write', () async {
      await seedRow(db, kDay, finalized: false);
      await deriveWrite(kDay, tag: 'skip', skipped: true);
      expect((await rowOf(db, kDay))!['skipped'], 1);
    });
  });

  group('a finalized row refuses a same-version rewrite', () {
    Future<void> seedFinal() => seedRow(db, kDay, finalized: true);

    test('payload, window, computed_at and every indexed column stay', () async {
      await seedFinal();
      final before = (await rowOf(db, kDay))!;

      await deriveWrite(kDay, tag: 'late', finalized: true, rhr: 99.0);

      final after = (await rowOf(db, kDay))!;
      for (final k in before.keys) {
        expect(after[k], before[k], reason: 'column $k changed');
      }
      expect(after['computed_at'], kSeedComputedAt);
    });

    test('a refused write leaves metric_series and its version stamp alone',
        () async {
      await seedFinal();
      await db.insert('metric_series_version', {
        'date': kDay,
        'algo_version': kAlgoVersion,
        'source': 'seed_src',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final stampBefore = await seriesVersionRows(db, kDay);

      await deriveWrite(kDay, tag: 'late', rhr: 99.0);

      expect(await seriesOf(db, kDay, 'rhr'), 50.0);
      expect(await seriesOf(db, kDay, 'readiness'), 70.0);
      expect(await seriesVersionRows(db, kDay), stampBefore);
    });

    test('a refused write does not run its blankKeys deletes', () async {
      await seedFinal();
      await deriveWrite(kDay, tag: 'blank', blankKeys: {'rhr', 'readiness'});
      expect(await seriesOf(db, kDay, 'rhr'), 50.0);
      expect(await seriesOf(db, kDay, 'readiness'), 70.0);
    });

    test('a thinner incoming write (partial / unfinalized) is refused too',
        () async {
      await seedFinal();
      await deriveWrite(kDay, tag: 'thin', finalized: false, partial: true);
      final row = (await rowOf(db, kDay))!;
      expect(row['finalized'], 1, reason: 'never demoted to recomputable');
      expect(row['partial'], 0);
      expect(row['payload_json'], payloadOf('seed'));
    });

    test('a skip marker never lands over a finalized row', () async {
      await seedFinal();
      await deriveWrite(kDay, tag: 'skip', skipped: true);
      final row = (await rowOf(db, kDay))!;
      expect(row['skipped'], 0);
      expect(row['payload_json'], payloadOf('seed'));
    });

    test('the refusal is silent: the write returns normally', () async {
      await seedFinal();
      await expectLater(deriveWrite(kDay, tag: 'late'), completes);
    });

    test('the refusal reports that it did not commit', () async {
      await seedFinal();
      final committed = await LocalDb.putDayResult(
        dayId: kDay,
        algoVersion: kAlgoVersion,
        payloadJson: payloadOf('late'),
        windowJson: '{}',
      );
      expect(committed, isFalse);
    });

    test('it is per (day, version): another day is unaffected', () async {
      await seedFinal();
      await seedRow(db, '2026-03-11', finalized: false);
      await deriveWrite('2026-03-11', tag: 'next', rhr: 61.0);
      expect((await rowOf(db, '2026-03-11'))!['payload_json'],
          payloadOf('next', day: '2026-03-11', rhr: 61.0));
    });
  });

  group('a new version writes a new sibling row', () {
    test('(day, V+1) is written beside a frozen (day, V)', () async {
      await seedRow(db, kDay, finalized: true);

      await deriveWrite(kDay,
          version: kAlgoVersion + 1, tag: 'next-version', rhr: 61.0);

      final old = (await rowOf(db, kDay))!;
      expect(old['payload_json'], payloadOf('seed'));
      expect(old['computed_at'], kSeedComputedAt);
      final next = (await rowOf(db, kDay, version: kAlgoVersion + 1))!;
      expect(next['payload_json'], payloadOf('next-version', rhr: 61.0));
    });

    test('(day, V) is written beside a frozen (day, V-1)', () async {
      await seedRow(db, kDay, version: kAlgoVersion - 1, finalized: true);

      await deriveWrite(kDay, tag: 'bump', rhr: 61.0);

      expect((await rowOf(db, kDay, version: kAlgoVersion - 1))!['computed_at'],
          kSeedComputedAt);
      expect((await rowOf(db, kDay))!['payload_json'],
          payloadOf('bump', rhr: 61.0));
    });

    test('a frozen older sibling does not freeze the current version',
        () async {
      await seedRow(db, kDay, version: kAlgoVersion - 1, finalized: true);
      await deriveWrite(kDay, tag: 'first', rhr: 61.0);
      await deriveWrite(kDay, tag: 'second', rhr: 62.0);
      expect((await rowOf(db, kDay))!['payload_json'],
          payloadOf('second', rhr: 62.0),
          reason: 'only (day, V) finalized rows freeze; (day, V-1) is another row');
    });
  });

  test('the engine-visible lock set is unchanged by a refused write', () async {
    await seedRow(db, kDay, finalized: true);
    await seedRow(db, '2026-03-11', finalized: false);
    await deriveWrite(kDay, tag: 'late');
    await deriveWrite('2026-03-11', tag: 'later');
    expect(await LocalDb.finalizedDayIds(kAlgoVersion), {kDay});
  });
}
