// RED: the three P2s Sol left on the import branch (round 5).
//
//  1. A fresh import must not clear acknowledgements while an older import is
//     still unfinished: when that one resumes it would re-raise a dismissed note.
//  2. A refused preference write must not leave the store believing the write
//     landed (the plugin updates its cache first). Reads reconcile from disk.
//  3. When automatic resumes are exhausted, the journal's stored error is
//     shown at launch and kept until the next import.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/data/import_reentry_store.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'import_resume/import_resume_support.dart';
import 'support/app_state_derive_harness.dart';
import 'ui2_import_fix_round4_test.dart' show NoRollup, killMidCopy, sourceWith;

const _prefKey = 'import_reentry_pending';
const _name = 'import_followup.db';

/// Refuses writes to the re-entry key while [refuse] is set; the plugin's own
/// cache still moves, as it does on a real platform failure.
class _FlakyStore extends SharedPreferencesStorePlatform {
  _FlakyStore(Map<String, Object> data)
      : _inner = InMemorySharedPreferencesStore.withData(data);
  final InMemorySharedPreferencesStore _inner;
  bool refuse = false;
  @override
  Future<bool> clear() => _inner.clear();
  @override
  Future<Map<String, Object>> getAll() => _inner.getAll();
  @override
  Future<bool> remove(String key) async =>
      refuse && key.endsWith(_prefKey) ? false : _inner.remove(key);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      refuse && key.endsWith(_prefKey)
          ? false
          : _inner.setValue(valueType, key, value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState app;

  setUp(() async {
    await deriveDbSetUp(_name);
    ImportHooks.reset();
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('import_followup_');
    app = AppState.forTesting();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    app.debugFinalizeImport = NoRollup();
  });
  tearDown(() async {
    ImportHooks.reset();
    app.dispose();
    SharedPreferences.setMockInitialValues({});
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    await deriveDbTearDown(_name);
  });

  test('1: a fresh import keeps acknowledgements that an unfinished older '
      'import still depends on', () async {
    SharedPreferences.setMockInitialValues({_prefKey: kNeedsReentryCoachKey});
    await app.loadImportReentry();
    await killMidCopy(await sourceWith(tmp, lostKey: true)); // backup A fails
    await app.dismissImportReentry(); // X dismissed while A is unfinished
    await app.beginFreshImport(); // a CSV-only import B starts
    final restarted = AppState.forTesting();
    addTearDown(restarted.importProgress.dispose);
    restarted.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    restarted.debugFinalizeImport = NoRollup();
    await restarted.loadImportReentry();
    await restarted.resumeUnfinishedImport(force: true); // A resumes, records X
    expect(restarted.importReentry.value, isEmpty,
        reason: 'X was dismissed; B had nothing to do with it');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('1b: with nothing unfinished, a fresh import does clear them (a new '
      'import that loses the key shows it again)', () async {
    SharedPreferences.setMockInitialValues({_prefKey: ';$kNeedsReentryCoachKey'});
    await app.beginFreshImport();
    await app.addImportReentry([kNeedsReentryCoachKey]);
    expect(app.importReentry.value, [kNeedsReentryCoachKey]);
  });

  test('2: a refused reset is retried, not skipped on a stale cache', () async {
    final store = _FlakyStore({'flutter.$_prefKey': ';$kNeedsReentryCoachKey'});
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    addTearDown(SharedPreferences.resetStatic);
    final s = ImportReentryStore();
    store.refuse = true;
    await expectLater(s.beginFreshImport(), throwsA(isA<StateError>()));
    store.refuse = false;
    await s.beginFreshImport(); // disk still holds the acknowledgement
    // The import's restore step reloads the preferences from disk.
    await (await SharedPreferences.getInstance()).reload();
    await s.add([kNeedsReentryCoachKey]);
    expect(s.pending.value, [kNeedsReentryCoachKey],
        reason: 'the new import\'s warning must not be suppressed by an '
            'acknowledgement the cache wrongly showed as cleared');
  });

  test('3: exhausted automatic resumes surface the stored error at launch',
      () async {
    await killMidCopy(await sourceWith(tmp, lostKey: false));
    final db = await LocalDb.instance;
    await db.update('import_journal', {
      'state': ImportJournalState.failed.name,
      'error': 'disk full while copying',
      'resumes': ImportJournal.kMaxAutoResumes + 1,
    });
    await app.resumeUnfinishedImport(); // launch: no force
    final v = app.importProgress.value;
    expect(v, isA<ImportFailed>());
    expect((v as ImportFailed).error, contains('disk full'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
