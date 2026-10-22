// Owner directive: no syncing while an import is happening.
//
// One owner (ImportGate), a sealed answer, every sync entry point consulting
// it, a visible "waiting for the import" state, and an import that never
// starts under a drain that is mid-chunk (commit-before-ACK, AGENTS 3.1).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/import_gate.dart';

import 'backup/backup_support.dart';
import 'import_resume/import_resume_support.dart';

void main() {
  setUp(() {
    ImportGate.resetForTest();
    HeadlessSyncGate.resetForTest();
  });
  tearDown(ImportGate.resetForTest);

  group('the gate answers with a sealed result', () {
    test('allowed when nothing imports', () {
      expect(ImportGate.check('t'), isA<SyncAllowed>());
    });

    test('refused with a reason and a sentence while an import runs', () {
      ImportGate.enter();
      final r = ImportGate.check('t');
      expect(r, isA<SyncRefused>());
      r as SyncRefused;
      expect(r.reason, ImportBlock.importRunning);
      expect(r.message, 'Waiting for the import to finish');
      ImportGate.leave();
      expect(ImportGate.check('t'), isA<SyncAllowed>());
    });

    test('nested imports hold it until the last leaves', () {
      ImportGate.enter();
      ImportGate.enter();
      ImportGate.leave();
      expect(ImportGate.check('t'), isA<SyncRefused>());
      ImportGate.leave();
      expect(ImportGate.check('t'), isA<SyncAllowed>());
    });
  });

  group('every sync entry point is registered, refuses, and consults it', () {
    test('table-driven: each registered entry point is refused', () {
      expect(ImportGate.entryPoints, isNotEmpty);
      ImportGate.enter();
      for (final e in ImportGate.entryPoints) {
        expect(ImportGate.check(e), isA<SyncRefused>(), reason: e);
        expect(ImportGate.refusals[e], 1, reason: e);
      }
    });

    test('source guard: each entry point file consults ImportGate', () {
      const files = {
        'lib/ble/ble_engine.dart': 3, // refresh, INIT drain, offload flag
        'lib/sync/headless_gate.dart': 1,
        'lib/sync/background_sync.dart': 1,
        'lib/state/control_operations.dart': 1,
        'lib/state/sync_controller.dart': 1,
        'lib/ble/adapters/host.dart': 2, // run + commit
        'lib/data/import_journal.dart': 2, // enter/leave + beginImport
      };
      files.forEach((f, n) {
        final src = File(f).readAsStringSync();
        expect('ImportGate.'.allMatches(src).length, greaterThanOrEqualTo(n),
            reason: f);
      });
      // Every registered name appears at a call site somewhere in lib/.
      final all = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.readAsStringSync())
          .join('\n');
      for (final e in ImportGate.entryPoints) {
        expect(all.contains("ImportGate.check('$e')") ||
            all.contains('ImportGate.check(\n') ||
            all.contains("'$e'"), isTrue, reason: e);
      }
    });
  });

  group('headless and background: skipped, never queued', () {
    test('HeadlessSyncGate.tryRun skips the body and does not queue it',
        () async {
      ImportGate.enter();
      var ran = 0;
      final out = await HeadlessSyncGate.tryRun<int>('wake', () async => ++ran);
      expect(out, isNull);
      expect(ran, 0);
      ImportGate.leave();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ran, 0, reason: 'a skipped wake is not replayed later');
      expect(await HeadlessSyncGate.tryRun<int>('wake', () async => ++ran), 1);
    });

    test('an import refusal is not counted as wake starvation', () async {
      ImportGate.enter();
      for (var i = 0; i < 6; i++) {
        await HeadlessSyncGate.tryRun<int>('wake', () async => 1);
      }
      expect(HeadlessSyncGate.isStarved('wake'), isFalse);
    });
  });

  group('visible state', () {
    SyncCoordinator make(Future<void> Function(void Function(String)) run) =>
        SyncCoordinator(
            run: run, isConnected: () => true, reloadLocal: () async {});

    test('pull-to-sync during an import shows waiting_import and runs nothing',
        () async {
      var ran = false;
      final c = make((_) async => ran = true);
      ImportGate.enter();
      final r = await c.syncNow();
      expect(r.success, isFalse);
      expect(r.error, 'Waiting for the import to finish');
      expect(ran, isFalse);
      expect(c.presentation.phase, 'waiting_import');
      expect(c.presentation.busy, isFalse);
    });

    test('after the import, sync proceeds', () async {
      var ran = false;
      final c = make((_) async => ran = true);
      ImportGate.enter();
      await c.syncNow();
      ImportGate.leave();
      final r = await c.syncNow();
      expect(r.success, isTrue);
      expect(ran, isTrue);
      expect(c.presentation.phase, 'completed');
    });

    test('the state notifier flips with the gate', () {
      final seen = <SyncPermit>[];
      void l() => seen.add(ImportGate.state.value);
      ImportGate.state.addListener(l);
      addTearDown(() => ImportGate.state.removeListener(l));
      ImportGate.enter();
      ImportGate.leave();
      expect(seen.first, isA<SyncRefused>());
      expect(seen.last, isA<SyncAllowed>());
    });
  });

  group('an import does not start under a drain mid-chunk', () {
    test('it waits for the drain, then is admitted; syncs refuse meanwhile',
        () async {
      final engine = Object();
      ImportGate.drainChanged(engine, true);
      final admission =
          ImportGate.beginImport(wait: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ImportGate.check('t'), isA<SyncRefused>(),
          reason: 'no NEW drain may start while the import waits');
      ImportGate.drainChanged(engine, false);
      expect(await admission, isA<ImportAdmitted>());
      ImportGate.leave();
    });

    test('refused with a reason when the drain outlasts the wait', () async {
      final engine = Object();
      ImportGate.drainChanged(engine, true);
      final a = await ImportGate.beginImport(
          wait: const Duration(milliseconds: 50));
      expect(a, isA<ImportDeferred>());
      expect((a as ImportDeferred).reason, ImportBlock.drainInProgress);
      expect(ImportGate.check('t'), isA<SyncAllowed>(),
          reason: 'a deferred import must not leave the gate shut');
    });

    test('a drain flag is per engine and idempotent', () async {
      final a = Object(), b = Object();
      ImportGate.drainChanged(a, true);
      ImportGate.drainChanged(a, true);
      ImportGate.drainChanged(b, true);
      ImportGate.drainChanged(a, false);
      expect(ImportGate.drainActive, isTrue);
      ImportGate.drainChanged(b, false);
      expect(ImportGate.drainActive, isFalse);
    });
  });

  group('pending import at launch', () {
    late BackupEnv env;
    late String src;
    setUpAll(() async {
      env = await BackupEnv.create('openstrap_import_gate_test.db');
      src = await buildSource(env.root);
    });
    tearDownAll(() async => env.dispose());
    setUp(() async {
      await env.wipe();
      ImportHooks.reset();
    });
    tearDown(ImportHooks.reset);

    test('a persisted unfinished run blocks sync until resumed and done',
        () async {
      crashAt('decoded_onehz', 2);
      await expectLater(
          LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
      ImportHooks.chunk = null;
      await LocalDb.close();
      ImportGate.resetForTest(); // a new process
      expect(ImportGate.check('t'), isA<SyncAllowed>(),
          reason: 'nothing read yet');
      await ImportGate.probe();
      final r = ImportGate.check('t');
      expect(r, isA<SyncRefused>());
      expect((r as SyncRefused).reason, ImportBlock.importPending);

      await ImportJournal.resumeIfUnfinished();
      expect((await ImportJournal.current())?.state, ImportJournalState.done);
      expect(ImportGate.check('t'), isA<SyncAllowed>());
    });

    test('three failed resumes: the gate opens (no automatic retry is left)',
        () async {
      crashAt('decoded_onehz', 2);
      await expectLater(
          LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
      await LocalDb.close();
      ImportGate.resetForTest();
      for (var i = 0; i < ImportJournal.kMaxAutoResumes; i++) {
        crashAt('decoded_onehz', 2);
        final r = await ImportJournal.resumeIfUnfinished();
        expect(r.error, isNotNull, reason: 'resume $i fails again');
      }
      expect(ImportGate.check('t'), isA<SyncAllowed>(),
          reason: 'sync must not stay refused for a run nobody will retry');
    });

    test('a missing source: the gate opens', () async {
      crashAt('decoded_onehz', 2);
      await expectLater(
          LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
      ImportHooks.chunk = null;
      final path = (await (await LocalDb.instance).query('import_journal'))
          .first['source_path'] as String;
      File(path).deleteSync();
      await LocalDb.close();
      ImportGate.resetForTest();
      await ImportGate.probe();
      expect(ImportGate.check('t'), isA<SyncRefused>());
      final r = await ImportJournal.resumeIfUnfinished();
      expect(r.error, isNotNull);
      expect(ImportGate.check('t'), isA<SyncAllowed>());
    });

    test('a running import is registered by the journal itself', () async {
      final seen = <SyncPermit>[];
      ImportHooks.chunkRows = kChunk;
      ImportHooks.chunk = (txn, c) async => seen.add(ImportGate.check('t'));
      await LocalDb.importFromDbFile(src);
      expect(seen, isNotEmpty);
      expect(seen.every((p) => p is SyncRefused), isTrue);
      expect(ImportGate.check('t'), isA<SyncAllowed>());
    });
  });
}
