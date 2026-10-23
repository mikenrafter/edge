// Import focus (owner 2026-10-22): the import runs alone. Lifecycle.
//
// Focus starts where ImportGate.beginImport raises the sync gate
// (ImportJournal.runExclusive), outlives the copy, and ends when the first
// post-import derive pass completes, or at once when the import fails, is
// deferred or is abandoned. A resume re-enters it.
//
// Assumed API (stubs in lib/sync/import_focus.dart):
//   ImportFocus.active / enter / leave / debugReset.
// The implementer chooses where the leave sits; the tests only fix WHEN:
// DeriveScheduler's pass for a job queued with reason 'import' completing.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/sync/import_focus.dart';
import 'package:openstrap_edge/sync/import_gate.dart';

import '../backup/backup_support.dart';
import '../import_resume/import_resume_support.dart';

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late BackupEnv env;
  late String src;
  setUpAll(() async {
    env = await BackupEnv.create('openstrap_import_focus_lifecycle_test.db');
    src = await buildSource(env.root);
  });
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    ImportHooks.reset();
    ImportGate.resetForTest();
    ImportFocus.debugReset();
    // The app's import flow declares the post-import pass before it starts.
    ImportFocus.expectPass();
  });
  tearDown(() {
    ImportHooks.reset();
    ImportGate.resetForTest();
    ImportFocus.debugReset();
  });

  DeriveScheduler? made;
  tearDown(() {
    made?.dispose();
    made = null;
  });

  /// A scheduler whose passes all complete, recording each kind.
  DeriveScheduler scheduler(List<DeriveJobKind> kinds) => made = DeriveScheduler(
        run: ({required DeriveJobKind kind}) async {
          kinds.add(kind);
          return const DeriveOutcome(computed: 1);
        },
        log: (_) {},
        onChanged: () {},
        lightSettle: const Duration(milliseconds: 10),
        heavySettle: const Duration(milliseconds: 10),
      );

  group('enter', () {
    test('runExclusive enters focus before the job starts', () async {
      expect(ImportFocus.active.value, isFalse);
      bool? during;
      await ImportJournal.runExclusive(
          stage: 't', job: () async => during = ImportFocus.active.value);
      expect(during, isTrue);
    });

    test('a real import is in focus for every chunk it copies', () async {
      final seen = <bool>[];
      ImportHooks.chunkRows = kChunk;
      ImportHooks.chunk = (txn, c) async => seen.add(ImportFocus.active.value);
      await LocalDb.importFromDbFile(src);
      expect(seen, isNotEmpty);
      expect(seen.every((a) => a), isTrue);
    });

    test('the active notifier tells listeners when focus flips', () async {
      final seen = <bool>[];
      void l() => seen.add(ImportFocus.active.value);
      ImportFocus.active.addListener(l);
      addTearDown(() => ImportFocus.active.removeListener(l));
      await ImportJournal.runExclusive(stage: 't', job: () async {});
      expect(seen, isNotEmpty);
      expect(seen.first, isTrue);
    });
  });

  test('an import nobody will recalculate after ends focus with its copy',
      () async {
    ImportFocus.debugReset(); // no expectPass: e.g. a restore path
    await LocalDb.importFromDbFile(src);
    expect(ImportFocus.active.value, isFalse,
        reason: 'no pass is coming to end it, so reads must not stay paused');
  });

  group('stay: the recalculation is part of the import', () {
    test('focus is still active after the copy returns', () async {
      await LocalDb.importFromDbFile(src);
      expect((await ImportJournal.current())?.state, ImportJournalState.done);
      expect(ImportFocus.active.value, isTrue,
          reason: 'the post-import derive pass has not run yet');
    });

    test('a pass that is not the post-import pass does not end it', () async {
      await LocalDb.importFromDbFile(src);
      final kinds = <DeriveJobKind>[];
      final s = scheduler(kinds);
      s.markStoredData(); // a light pass, reason stored_data
      await _until(() => kinds.length == 1);
      await _until(() => !s.running);
      expect(kinds, [DeriveJobKind.light]);
      expect(ImportFocus.active.value, isTrue);
      s.requestHeavy(reason: 'capture_settled', storedData: true);
      await _until(() => kinds.length == 2);
      await _until(() => !s.running);
      expect(kinds.last, DeriveJobKind.heavy);
      expect(ImportFocus.active.value, isTrue,
          reason: 'only the pass queued for the import ends focus');
    });
  });

  group('leave', () {
    test('when the post-import derive pass completes', () async {
      await LocalDb.importFromDbFile(src);
      final held = Completer<void>();
      var passes = 0;
      made = DeriveScheduler(
        run: ({required DeriveJobKind kind}) async {
          passes++;
          await held.future;
          return const DeriveOutcome(computed: 1);
        },
        log: (_) {},
        onChanged: () {},
        lightSettle: const Duration(milliseconds: 10),
        heavySettle: const Duration(milliseconds: 10),
      );
      made!.requestHeavy(reason: 'import', storedData: true);
      await _until(() => passes == 1);
      expect(made!.running, isTrue);
      expect(ImportFocus.active.value, isTrue,
          reason: 'still recalculating: focus holds while the pass runs');
      held.complete();
      await _until(() => !made!.running);
      await _until(() => !ImportFocus.active.value);
      expect(ImportFocus.active.value, isFalse);
    });

    test('when the import fails', () async {
      final seen = <bool>[];
      crashAt('decoded_onehz', 2);
      final crash = ImportHooks.chunk!;
      ImportHooks.chunk = (txn, c) async {
        seen.add(ImportFocus.active.value);
        await crash(txn, c);
      };
      await expectLater(
          LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
      expect(seen, contains(true), reason: 'it was in focus while it ran');
      expect(ImportFocus.active.value, isFalse);
    });

    test('when the job throws before anything is journaled', () async {
      await expectLater(
          ImportJournal.runExclusive<void>(stage: 't', job: () async {
            expect(ImportFocus.active.value, isTrue);
            throw StateError('boom');
          }),
          throwsA(isA<StateError>()));
      expect(ImportFocus.active.value, isFalse);
    });

    test('when the import is deferred behind a drain', () async {
      final engine = Object();
      ImportGate.drainChanged(engine, true);
      // beginImport waits 30 s by default; the drain is never ended here, so
      // shorten it through the gate's own timeout instead of waiting.
      final a = await ImportGate.beginImport(
          wait: const Duration(milliseconds: 50));
      expect(a, isA<ImportDeferred>());
      expect(ImportFocus.active.value, isFalse,
          reason: 'nothing started, so nothing is paused');
      ImportGate.drainChanged(engine, false);
    });

    test('when an unfinished import is abandoned (its source is gone)',
        () async {
      final seen = <bool>[];
      crashAt('decoded_onehz', 2);
      final crash = ImportHooks.chunk!;
      ImportHooks.chunk = (txn, c) async {
        seen.add(ImportFocus.active.value);
        await crash(txn, c);
      };
      await expectLater(
          LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
      expect(seen, contains(true), reason: 'the first run was in focus');
      ImportHooks.chunk = null;
      final path = (await (await LocalDb.instance).query('import_journal'))
          .first['source_path'] as String;
      File(path).deleteSync();
      final r = await ImportJournal.resumeIfUnfinished();
      expect(r.error, isNotNull);
      expect(ImportFocus.active.value, isFalse);
    });
  });

  group('re-enter on resume', () {
    test('a resume copies in focus and keeps it until the derive pass',
        () async {
      crashAt('decoded_onehz', 2);
      await expectLater(
          LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
      expect(ImportFocus.active.value, isFalse);

      final seen = <bool>[];
      ImportHooks.chunk = (txn, c) async => seen.add(ImportFocus.active.value);
      var requested = 0;
      ImportFocus.expectPass(); // as AppState.resumeUnfinishedImport does
      final r = await ImportJournal.resumeIfUnfinished(
          requestDerive: () => requested++);
      expect(r.resumed, isTrue);
      expect(requested, 1);
      expect(seen, isNotEmpty);
      expect(seen.every((a) => a), isTrue);
      expect(ImportFocus.active.value, isTrue,
          reason: 'the derive was requested but has not completed');
    });
  });
}
