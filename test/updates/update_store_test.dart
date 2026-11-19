// WHY: the update store is the only place consent, leases and release claims
// live, and two isolates (the UI and the WorkManager worker) share it. Every
// guarantee here is about what survives a race, a crash, a clock jump or a
// corrupt file. Proves CLAIM(release-check-local-store), CLAIM(release-check-once),
// CLAIM(release-check-consent).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/event_claim_ledger.dart';
import 'package:openstrap_edge/sync/update_models.dart';
import 'package:openstrap_edge/sync/update_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FailInitializationFactory implements DatabaseFactory {
  int deletes = 0;
  int opens = 0;
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async {
    final db = await databaseFactoryFfi.openDatabase(path, options: options);
    return ++opens == 1 ? _FailInitializationDatabase(db) : db;
  }
  @override
  Future<void> deleteDatabase(String path) async {
    deletes++;
    await databaseFactoryFfi.deleteDatabase(path);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailInitializationDatabase implements Database {
  _FailInitializationDatabase(this.db);
  final Database db;
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) =>
      Future.error(StateError('transient initialization I/O failure'));
  @override
  Future<void> close() => db.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late String path;
  late UpdateStore store;
  final t0 = DateTime.utc(2026, 11, 15, 12);

  Future<UpdateStore> openStore() =>
      UpdateStore.openFile(path, factory: databaseFactoryFfi);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-store-');
    path = '${directory.path}/release-checks-v1.db';
    store = await openStore();
  });
  tearDown(() async {
    await store.db.close();
    await directory.delete(recursive: true);
  });

  group('schema and busy handling', () {
    // catches: no versioning, so a future additive change cannot be told from a
    // corrupt file; and an unbounded wait (or none) on a locked database.
    test('versioned schema, 2 s busy timeout', () async {
      expect(UpdateStore.schemaVersion, 1);
      expect(
        (await store.db.rawQuery('PRAGMA user_version')).single.values.single,
        UpdateStore.schemaVersion,
      );
      expect(
        (await store.db.rawQuery('PRAGMA busy_timeout')).single.values.single,
        UpdateStore.busyTimeout.inMilliseconds,
      );
    });

    // WHY: a downgrade must not misread a newer layout as its own.
    test('a newer schema is refused, not rewritten', () async {
      await store.db.execute('PRAGMA user_version = 2');
      await store.db.close();
      await expectLater(openStore(), throwsA(isA<UpdateStoreException>()));
      store = await databaseFactoryFfi.openDatabase(path).then(UpdateStore.new);
      expect(
        (await store.db.rawQuery('PRAGMA user_version')).single.values.single,
        2,
      );
    });

    // catches: surfacing SQLITE_BUSY to the user when the other isolate holds a
    // short write lock.
    test('a writer waits for a brief foreign write lock', () async {
      final other = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(other.close);
      final holding = other.transaction((txn) async {
        await txn.rawUpdate('UPDATE update_state SET manual_at=manual_at');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final lease = await store.claim(t0, manual: true);
      await holding;
      expect(lease, isNotNull);
    });
  });

  group('consent and corruption', () {
    // WHY: a restored or damaged file must never grant consent.
    // catches: a garbled `enabled` value reading as on; a silent reset.
    test('unreadable authorization resets to off and says so once', () async {
      await store.setEnabled(true);
      await store.db.rawUpdate("UPDATE update_state SET enabled='yes'");
      final snapshot = await store.read();
      expect(snapshot.enabled, isFalse);
      expect(snapshot.authorizationReset, isTrue);
      expect(await store.claim(t0, manual: false), isNull);
      await store.acknowledgeReset();
      expect((await store.read()).authorizationReset, isFalse);
      expect((await store.read()).enabled, isFalse);
    });

    // WHY: lock, full-disk and I/O errors must preserve permanent sent claims.
    // catches: deleting a valid store after any open/initialization exception.
    test('an operational initialization failure preserves consent and sent claims', () async {
      await store.setEnabled(true);
      final ticket = (await store.beginRelease('release:fork:71', t0))!;
      await store.settleRelease(ticket, ClaimOutcome.sent);
      await store.db.close();
      final original = await File(path).readAsBytes();
      final factory = _FailInitializationFactory();
      Object? failure;
      UpdateStore? recovered;
      try {
        recovered = await UpdateStore.openFile(path, factory: factory);
      } catch (error) {
        failure = error;
      }
      await recovered?.db.close();
      expect(factory.deletes, 0);
      expect(failure, isA<StateError>());
      expect(await File(path).readAsBytes(), original);
      store = await openStore();
      expect((await store.read()).enabled, isTrue);
      expect(await store.beginRelease('release:fork:71', t0), isNull);
    });

    test('a damaged file is replaced by an off store and reported', () async {
      await store.db.close();
      await File(path).writeAsString('this is not a sqlite database');
      store = await openStore();
      final snapshot = await store.read();
      expect(snapshot.enabled, isFalse);
      expect(snapshot.authorizationReset, isTrue);
    });

    // WHY: prior companion consent never authorizes GitHub (spec §5.1).
    test('a restored legacy switch grants nothing', () async {
      SharedPreferences.setMockInitialValues({
        UpdateStore.retiredCompanionSwitch: true,
      });
      await SharedPreferences.getInstance();
      expect((await store.read()).enabled, isFalse);
      expect(await store.claim(t0, manual: false), isNull);
    });

    // CLAIM(release-check-consent) catches: stale results crossing an opt-out.
    test('disabling bumps the generation and clears caches', () async {
      await store.setEnabled(true);
      final lease = (await store.claim(t0, manual: false))!;
      expect(
        await store.save(lease, ReleaseSource.official, SourceUpdate(checkedAt: t0)),
        isTrue,
      );
      expect(await store.saveManifest(lease, 'k', {'versionCode': 1}), isTrue);
      await store.setEnabled(false);
      expect(await store.valid(lease), isFalse);
      expect(
        await store.save(lease, ReleaseSource.fork, SourceUpdate(checkedAt: t0)),
        isFalse,
      );
      expect((await store.read()).sources, isEmpty);
      expect(await store.manifest('k'), isNull);
    });
  });

  group('lease', () {
    // catches: two isolates owning one batch.
    test('one winner across independent connections', () async {
      final second = UpdateStore(
        await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(singleInstance: false),
        ),
      );
      await second.initialize();
      addTearDown(second.db.close);
      final claims = await Future.wait([
        store.claim(t0, manual: true),
        second.claim(t0, manual: true),
      ]);
      expect(claims.whereType<UpdateLease>(), hasLength(1));
    });

    // catches: a recovered-after-expiry batch racing the stale holder's writes.
    test('a stale holder cannot write after recovery; renewal extends', () async {
      await store.setEnabled(true);
      final a = (await store.claim(t0, manual: false))!;
      // Held: nobody else may claim inside the lease.
      expect(
        await store.claim(t0.add(const Duration(minutes: 2)), manual: true),
        isNull,
      );
      // Renewal at minute 4 extends the lease past minute 6.
      expect(await store.renew(a, t0.add(const Duration(minutes: 4))), isTrue);
      expect(
        await store.claim(t0.add(const Duration(minutes: 6)), manual: true),
        isNull,
      );
      // Expired (no renewal): recovered by the next holder.
      final b = (await store.claim(
        t0.add(const Duration(minutes: 10)),
        manual: true,
      ))!;
      expect(b.token, greaterThan(a.token));
      expect(await store.valid(a), isFalse);
      expect(
        await store.save(a, ReleaseSource.official, SourceUpdate(checkedAt: t0)),
        isFalse,
      );
      expect(await store.renew(a, t0.add(const Duration(minutes: 11))), isFalse);
      expect(
        await store.save(b, ReleaseSource.official, SourceUpdate(checkedAt: t0)),
        isTrue,
      );
      // A release by the stale holder frees nothing it does not own.
      await store.release(a);
      expect(
        await store.claim(t0.add(const Duration(minutes: 11)), manual: true),
        isNull,
      );
      await store.release(b);
    });

    // catches: an indefinite lease after a wall-clock rollback.
    test('a lease from the far future (clock rollback) cannot stall checks', () async {
      await store.setEnabled(true);
      await store.claim(t0.add(const Duration(days: 30)), manual: false);
      expect(await store.claim(t0, manual: true), isNotNull);
    });
  });

  group('cadence', () {
    // CLAIM(release-check-once): once per 24 h plus bounded jitter.
    test('next automatic slot is 24 h plus jitter, capped at six hours', () async {
      await store.setEnabled(true);
      final lease = (await store.claim(
        t0,
        manual: false,
        jitter: const Duration(hours: 10),
      ))!;
      await store.release(lease);
      expect(
        await store.claim(t0.add(const Duration(hours: 29, minutes: 59)), manual: false),
        isNull,
        reason: 'cap is 6 h, so the slot is 30 h, not 34 h',
      );
      // Not before 24 h, and not after 30 h.
      expect(
        await store.claim(t0.add(const Duration(hours: 30, minutes: 1)), manual: false),
        isNotNull,
      );
    });

    test('no automatic claim before the slot; manual ignores it', () async {
      await store.setEnabled(true);
      final first = (await store.claim(t0, manual: false))!;
      await store.release(first);
      final soon = t0.add(const Duration(hours: 23));
      expect(await store.claim(soon, manual: false), isNull);
      expect(await store.claim(soon, manual: true), isNotNull);
    });

    // catches: a request storm or an indefinite stall after a clock rollback.
    test('a slot far in the future (clock rolled back) is pulled in once', () async {
      await store.setEnabled(true);
      final first = (await store.claim(t0.add(const Duration(days: 40)), manual: false))!;
      await store.release(first);
      expect(await store.claim(t0, manual: false), isNull);
      expect(await store.claim(t0.add(const Duration(days: 1, minutes: 1)), manual: false), isNotNull);
    });

    // catches: a throttle held only in memory.
    test('manual attempts keep a persistent 60 second minimum interval', () async {
      final a = (await store.claim(t0, manual: true))!;
      await store.release(a);
      expect(await store.claim(t0.add(const Duration(seconds: 59)), manual: true), isNull);
      final reopened = await openStore();
      addTearDown(() async {
        if (!identical(reopened.db, store.db)) await reopened.db.close();
      });
      expect(await reopened.claim(t0.add(const Duration(seconds: 59)), manual: true), isNull);
      expect(await reopened.claim(t0.add(const Duration(seconds: 61)), manual: true), isNotNull);
    });
  });

  group('manifest cache', () {
    // catches: unbounded growth from positive and negative entries.
    test('retention keeps the newest ${UpdateStore.manifestRetention} entries', () async {
      await store.setEnabled(true);
      final lease = (await store.claim(t0, manual: false))!;
      for (var i = 0; i < UpdateStore.manifestRetention + 6; i++) {
        expect(await store.saveManifest(lease, 'k$i', {'versionCode': i}), isTrue);
      }
      final rows = await store.db.query('update_manifests');
      expect(rows.length, UpdateStore.manifestRetention);
      expect(await store.manifest('k0'), isNull);
      expect(await store.manifest('k5'), isNull);
      expect(await store.manifest('k${UpdateStore.manifestRetention + 5}'), isNotNull);
    });

    test('a negative (unusable) result is a cached entry too', () async {
      final lease = (await store.claim(t0, manual: true))!;
      await store.saveManifest(lease, 'gone', {'unusable': true});
      expect((await store.manifest('gone'))?['unusable'], isTrue);
    });
  });

  group('release claims', () {
    String id(int n) => 'release:fork:$n';

    // catches: a check-then-record race giving two alerts.
    test('one winner among concurrent begins', () async {
      final tickets = await Future.wait(
        List.generate(8, (_) => store.beginRelease(id(1), t0)),
      );
      expect(tickets.whereType<ReleaseTicket>(), hasLength(1));
      final ticket = tickets.whereType<ReleaseTicket>().single;
      expect(ticket.osId, greaterThanOrEqualTo(500000));
    });

    test('osIds are unique per release and never touch another band', () async {
      final a = (await store.beginRelease(id(1), t0))!;
      final b = (await store.beginRelease(id(2), t0))!;
      expect(a.osId, isNot(b.osId));
    });

    // CLAIM(release-check-once) catches: re-announcing a presented release.
    test('sent is permanent, even across reopen and disable', () async {
      final ticket = (await store.beginRelease(id(1), t0))!;
      await store.settleRelease(ticket, ClaimOutcome.sent);
      expect(await store.beginRelease(id(1), t0), isNull);
      await store.setEnabled(true);
      await store.setEnabled(false);
      expect(await store.beginRelease(id(1), t0.add(const Duration(days: 400))), isNull);
      await store.db.close();
      store = await openStore();
      expect(await store.beginRelease(id(1), t0), isNull);
    });

    // catches: releasing or re-allocating a quiet-held claim (spec §5.5, mutation).
    test('a held claim is reserved and reused with the same OS id', () async {
      final ticket = (await store.beginRelease(id(1), t0))!;
      await store.settleRelease(ticket, ClaimOutcome.held);
      expect(await store.heldReleases(), [id(1)]);
      final again = (await store.beginRelease(id(1), t0.add(const Duration(hours: 9))))!;
      expect(again.osId, ticket.osId);
      expect(await store.heldReleases(), isEmpty);
      await store.settleRelease(again, ClaimOutcome.sent);
      expect(await store.beginRelease(id(1), t0), isNull);
    });

    test('a presenting claim is owned: nobody else may take it', () async {
      final ticket = (await store.beginRelease(id(1), t0))!;
      expect(await store.beginRelease(id(1), t0), isNull);
      await store.settleRelease(ticket, ClaimOutcome.held);
      final other = (await store.beginRelease(id(1), t0))!;
      expect(await store.beginRelease(id(1), t0), isNull);
      // The first owner's stale settle cannot overwrite the new owner's.
      await store.settleRelease(ticket, ClaimOutcome.released);
      expect(await store.beginRelease(id(1), t0), isNull);
      await store.settleRelease(other, ClaimOutcome.sent);
    });

    test('known non-delivery releases the unused claim for a retry', () async {
      final ticket = (await store.beginRelease(id(1), t0))!;
      await store.settleRelease(ticket, ClaimOutcome.released);
      expect(await store.beginRelease(id(1), t0), isNotNull);
    });

    // WHY: at most once beats exactly once (owner 2026-11-17, R12).
    test('an ambiguous attempt stays consumed, even if never settled', () async {
      final a = (await store.beginRelease(id(1), t0))!;
      await store.settleRelease(a, ClaimOutcome.unknown);
      expect(await store.beginRelease(id(1), t0.add(const Duration(days: 9))), isNull);
      await store.beginRelease(id(2), t0); // process dies before settling
      await store.db.close();
      store = await openStore();
      expect(await store.beginRelease(id(2), t0.add(const Duration(days: 9))), isNull);
    });

    test('opt-out discards held intents and nothing else', () async {
      final held = (await store.beginRelease(id(1), t0))!;
      await store.settleRelease(held, ClaimOutcome.held);
      final sent = (await store.beginRelease(id(2), t0))!;
      await store.settleRelease(sent, ClaimOutcome.sent);
      await store.discardHeld();
      expect(await store.heldReleases(), isEmpty);
      expect(await store.beginRelease(id(2), t0), isNull);
      expect(await store.beginRelease(id(1), t0), isNotNull);
    });

    // WHY: one release claim across every routed destination; the second
    // destination needs its own once-only mark inside the same ledger.
    test('per-destination marks are once-only and returnable', () async {
      expect(await store.claimTarget(id(1), 'band'), isTrue);
      expect(await store.claimTarget(id(1), 'band'), isFalse);
      expect(await store.claimTarget(id(1), 'phone'), isTrue);
      await store.releaseTarget(id(1), 'band');
      expect(await store.claimTarget(id(1), 'band'), isTrue);
    });

    // WHY: health-data deletion leaves claims (owner 2026-11-17, R8); only an
    // explicit full app-data reset (the file is gone) clears them.
    test('only a missing file resets claims', () async {
      final ticket = (await store.beginRelease(id(1), t0))!;
      await store.settleRelease(ticket, ClaimOutcome.sent);
      await store.db.close();
      await File(path).delete();
      store = await openStore();
      expect(await store.beginRelease(id(1), t0), isNotNull);
      expect((await store.read()).enabled, isFalse);
    });
  });
}
