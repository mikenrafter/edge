// RED: review round 4 of the import notes. The pending and acknowledged sets
// have one owner (ImportReentryStore), persisted together.
//
//  1. A resume never erases a note that was saved durably, even when this
//     process has not loaded it (or the summary row is missing).
//  2. A dismissal made during the copy is persisted, so the later record step,
//     after a crash and a restart, cannot bring it back.
//  3. A failed resume keeps its ImportFailed until the next import.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';
import 'ui2_import_fix_round4_test.dart' show NoRollup, killMidCopy, sourceWith;

const _prefKey = 'import_reentry_pending';
const _name = 'import_round5.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState app;

  setUp(() async {
    await deriveDbSetUp(_name);
    ImportHooks.reset();
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('import_round5_');
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

  test('a resume does not erase a durable note this process never loaded',
      () async {
    SharedPreferences.setMockInitialValues({_prefKey: kNeedsReentryCoachKey});
    // No loadImportReentry(): the mirror is empty, the prefs are not.
    await killMidCopy(await sourceWith(tmp, lostKey: false));
    await app.resumeUnfinishedImport(force: true);
    final stored = (await SharedPreferences.getInstance()).getString(_prefKey);
    expect(stored, contains(kNeedsReentryCoachKey));
    expect(app.importReentry.value, [kNeedsReentryCoachKey],
        reason: 'the mirror follows the store');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a failed resume stays visible until the next import', () async {
    final path = await sourceWith(tmp, lostKey: false);
    await killMidCopy(path);
    // The journal resumes from its own saved copy; remove that.
    final db = await LocalDb.instance;
    final saved = (await db.query('import_journal', orderBy: 'id DESC', limit: 1))
        .first['source_path'] as String;
    File(saved).deleteSync();
    await app.resumeUnfinishedImport(force: true);
    expect(app.importProgress.value, isA<ImportFailed>(),
        reason: 'the failure is retained, not cleared by the finally');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
