// RED: review round 2 of the import notes.
//
//  1. The pending re-entry list is kept in the preferences until it is
//     acknowledged and read back at startup; a resumed import publishes its
//     notes too. Otherwise a kill before the user read them loses the warning.
//  2. Each runImport owns its publishing: a dismissed item stays dismissed for
//     that run, a later backup in the run merges instead of overwriting, and an
//     older run cannot republish after a newer one started.
//  Plus the consent round trip: the real setter writes, a fresh app reads it.
//
// RED STUB in lib/: AppState.loadImportReentry() (does nothing).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as pth;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';

import 'import_resume/import_resume_support.dart';
import 'support/app_state_derive_harness.dart';

const _prefKey = 'import_reentry_pending';
const _lost = ImportSummary(needsReentry: [kNeedsReentryCoachKey]);
const _other = ImportSummary(needsReentry: ['other_secret']);

class _App extends AppState {
  _App(this.summaries) : super.forTesting();
  final Map<String, ImportSummary?> summaries;

  /// Runs inside importEdgeBackup for a file name, before it returns.
  final Map<String, Future<void> Function()> during = {};

  @override
  Future<int> importEdgeBackup(String path) async {
    final n = pth.basename(path);
    lastBackupSummary = null;
    await during[n]?.call();
    lastBackupSummary = summaries[n];
    return 1;
  }
}

Future<List<String>> _backups(Directory dir, List<String> names) async => [
      for (final n in names)
        (File('${dir.path}/$n')..writeAsBytesSync([1, 2, 3, 4])).path
    ];

Future<String?> _stored() async =>
    (await SharedPreferences.getInstance()).getString(_prefKey);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('2: a run owns what it publishes', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('import_round3_');
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('an item dismissed mid-run is not brought back by the next backup',
        () async {
      final app = _App({'a.db': _lost, 'b.db': _lost});
      addTearDown(app.importProgress.dispose);
      app.during['b.db'] = () async {
        expect(app.importReentry.value, [kNeedsReentryCoachKey],
            reason: 'guard: a.db published it');
        app.dismissImportReentry();
      };
      await runImport(app, await _backups(tmp, ['a.db', 'b.db']));
      expect(app.importReentry.value, isEmpty,
          reason: 'acknowledged once for this run');
    });

    test('later backups merge with what is still unacknowledged', () async {
      final app = _App({'a.db': _lost, 'b.db': _other});
      addTearDown(app.importProgress.dispose);
      await runImport(app, await _backups(tmp, ['a.db', 'b.db']));
      expect(app.importReentry.value,
          unorderedEquals([kNeedsReentryCoachKey, 'other_secret']));
    });

    test('a later run never loses unread notes, and a late backup adds nothing '
        'twice', () async {
      final app = _App({'a.db': _lost, 'b.db': _lost, 'c.db': const ImportSummary()});
      addTearDown(app.importProgress.dispose);
      final gate = Completer<void>();
      app.during['b.db'] = () => gate.future;
      final run1 = runImport(app, await _backups(tmp, ['a.db', 'b.db']));
      for (var i = 0; i < 100 && app.importReentry.value.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(app.importReentry.value, isNotEmpty, reason: 'guard: run 1 published');
      await runImport(app, await _backups(tmp, ['c.db']));
      // One owner, a set: a newer import does not delete what was never read
      // (it only clears acknowledgements), and run 1's late backup unions the
      // same item.
      expect(app.importReentry.value, [kNeedsReentryCoachKey]);
      gate.complete();
      await run1;
      expect(app.importReentry.value, [kNeedsReentryCoachKey]);
    });
  });

  group('1: the list survives a restart', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('import_round3_');
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('kept in the preferences until acknowledged, read back at startup',
        () async {
      final app = _App({'a.db': _lost});
      addTearDown(app.importProgress.dispose);
      await runImport(app, await _backups(tmp, ['a.db']));
      expect(await _stored(), contains(kNeedsReentryCoachKey));

      final restarted = AppState.forTesting();
      addTearDown(restarted.importProgress.dispose);
      await restarted.loadImportReentry();
      expect(restarted.importReentry.value, [kNeedsReentryCoachKey]);

      restarted.dismissImportReentry();
      await Future<void>.delayed(Duration.zero);
      // The stored value is "pending;acknowledged": nothing pending any more.
      expect((await _stored() ?? '').split(';').first, isEmpty);
      final again = AppState.forTesting();
      addTearDown(again.importProgress.dispose);
      await again.loadImportReentry();
      expect(again.importReentry.value, isEmpty);
    });

    test('the key is device-only, with a reason', () {
      expect(kPrefsNotBackedUp[_prefKey], isNotNull);
      expect(kPrefsNotBackedUp[_prefKey], isNotEmpty);
    });
  });

  group('1: a resumed import publishes its notes', () {
    const name = 'import_round3_resume.db';
    late Directory tmp;
    late AppState app;

    setUp(() async {
      await deriveDbSetUp(name);
      ImportHooks.reset();
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('import_round3_');
      app = AppState.forTesting();
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      app.debugFinalizeImport = _Noop();
    });
    tearDown(() async {
      ImportHooks.reset();
      app.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
      await deriveDbTearDown(name);
    });

    test('the resume leaves the coach-key warning for the user', () async {
      final path = await buildSource(tmp);
      final s = await databaseFactoryFfi.openDatabase(path);
      await s.execute('CREATE TABLE backup_prefs '
          '(key TEXT PRIMARY KEY, type TEXT, value TEXT)');
      await s.insert('backup_prefs', {
        'key': 'coach_api_key_present', 'type': 'bool', 'value': 'true',
      });
      await s.close();
      crashAt('decoded_onehz', 2);
      await expectLater(
          LocalDb.importFromDbFile(path), throwsA(isA<StateError>()));
      ImportHooks.chunk = null;
      await LocalDb.close();

      await app.resumeUnfinishedImport(force: true);

      expect(app.importReentry.value, [kNeedsReentryCoachKey]);
      expect(await _stored(), contains(kNeedsReentryCoachKey));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('consent: a real round trip', () {
    test('the setter writes; a fresh app reads the answer back', () async {
      SharedPreferences.setMockInitialValues({});
      final first = AppState.forTesting();
      addTearDown(first.importProgress.dispose);
      await first.setTelemetryConsent(false);
      expect(first.consentChosen, isTrue);

      final second = AppState.forTesting();
      addTearDown(second.importProgress.dispose);
      await second.loadConsent();
      expect(second.consentLoaded, isTrue);
      expect(second.consentChosen, isTrue, reason: 'read back from the prefs');
      expect(second.telemetryConsent, isFalse);
      expect(second.consentPromptDue, isFalse);
    });
  });
}

class _Noop implements ImportRollupProbe {
  @override
  Future<void> finalize(profile) async {}
}
