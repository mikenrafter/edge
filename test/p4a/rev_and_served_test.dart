// P4a: P3 keeps working. `dayResultRev` and the artifact signatures built on it
// move when a provisional row is replaced and do NOT move when a frozen write is
// refused; `dayResultComputedAt` gains the served-version ceiling (the same
// MAX(algo_version) <= kAlgoVersion that `dayResult` applies). Assumed API: see
// support.dart (nothing new is referenced; compiles today, fails on behaviour).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late LocalRepositoryImpl repo;

  setUp(() async {
    db = await freshDb('openstrap_p4a_rev_and_served_test.db');
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
  });
  tearDownAll(dropDb);

  group('dayResultRev', () {
    test('changes when a provisional row is replaced', () async {
      await seedRow(db, kDay, finalized: false);
      final before = await LocalDb.dayResultRev();
      await deriveWrite(kDay, tag: 'replace');
      expect(await LocalDb.dayResultRev(), isNot(before));
    });

    test('does not change when a finalized row refuses a write', () async {
      await seedRow(db, kDay, finalized: true);
      final before = await LocalDb.dayResultRev();
      final beforeSince = await LocalDb.dayResultRev(sinceDay: '2026-03-01');

      await deriveWrite(kDay, tag: 'late');

      expect(await LocalDb.dayResultRev(), before);
      expect(await LocalDb.dayResultRev(sinceDay: '2026-03-01'), beforeSince);
    });

    test('still changes when a new version row lands beside a frozen one',
        () async {
      await seedRow(db, kDay, finalized: true);
      final before = await LocalDb.dayResultRev();
      await deriveWrite(kDay, version: kAlgoVersion + 1, tag: 'next');
      expect(await LocalDb.dayResultRev(), isNot(before));
    });
  });

  group('artifact signatures', () {
    test('weekday_effect moves on a provisional replace, not on a refusal',
        () async {
      await seedRow(db, kDay, finalized: false);
      await seedRow(db, '2026-03-11', finalized: true);

      final s0 = await repo.artifactSignature('weekday_effect');
      await deriveWrite('2026-03-11', tag: 'late');
      expect(await repo.artifactSignature('weekday_effect'), s0,
          reason: 'refused write: nothing a reader sees has changed');

      await deriveWrite(kDay, tag: 'replace');
      expect(await repo.artifactSignature('weekday_effect'), isNot(s0));
    });

    test('beats|day moves on a provisional replace, not on a refusal',
        () async {
      await seedRow(db, kDay, finalized: false);
      await seedRow(db, '2026-03-11', finalized: true);

      final frozen0 = await repo.artifactSignature('beats|2026-03-11');
      await deriveWrite('2026-03-11', tag: 'late');
      expect(await repo.artifactSignature('beats|2026-03-11'), frozen0);

      final prov0 = await repo.artifactSignature('beats|$kDay');
      await deriveWrite(kDay, tag: 'replace');
      expect(await repo.artifactSignature('beats|$kDay'), isNot(prov0));
    });
  });

  group('dayResultComputedAt applies the served-version ceiling', () {
    test('a row above kAlgoVersion is not the newest row it reports',
        () async {
      await seedRow(db, kDay, finalized: true, computedAt: 5000);
      await seedRow(db, kDay,
          version: kAlgoVersion + 1, finalized: true, computedAt: 9000);

      expect(await LocalDb.dayResultComputedAt(kDay), 5000);
      expect((await LocalDb.dayResult(kDay))!['computed_at'], 5000,
          reason: 'the same row `dayResult` serves');
    });

    test('a day whose only rows are above the ceiling has no computed_at',
        () async {
      await seedRow(db, kDay,
          version: kAlgoVersion + 1, finalized: true, computedAt: 9000);
      expect(await LocalDb.dayResultComputedAt(kDay), isNull);
      expect(await LocalDb.dayResult(kDay), isNull);
    });

    test('an older served row still reports its own time', () async {
      await seedRow(db, kDay,
          version: kAlgoVersion - 1, finalized: true, computedAt: 3000);
      expect(await LocalDb.dayResultComputedAt(kDay), 3000);
    });

    test('a day with no row has none', () async {
      expect(await LocalDb.dayResultComputedAt(kDay), isNull);
    });

    test('beats|day signature ignores a row above the ceiling', () async {
      await seedRow(db, kDay, finalized: true, computedAt: 5000);
      final before = await repo.artifactSignature('beats|$kDay');
      await seedRow(db, kDay,
          version: kAlgoVersion + 1, finalized: true, computedAt: 9000);
      expect(await repo.artifactSignature('beats|$kDay'), before);
    });
  });
}
