// Import follow-ups. The first two (acknowledgements across a fresh import,
// and a refused reset) are retired: acknowledgements are keyed by import run,
// so there is no reset (see ui2_import_reentry_identity_test.dart).
//  3. When automatic resumes are exhausted, the journal's stored error is
//     shown at launch and kept until the next import.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';
import 'ui2_import_fix_round4_test.dart' show NoRollup, killMidCopy, sourceWith;

const _name = 'import_followup.db';

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

  test('3b: launch recovery does not put an old error back after a newer '
      'backup started', () async {
    await killMidCopy(await sourceWith(tmp, lostKey: false)); // A, unfinished
    final db = await LocalDb.instance;
    await db.update('import_journal', {
      'state': ImportJournalState.failed.name,
      'error': 'old failure of A',
      'resumes': ImportJournal.kMaxAutoResumes + 1,
    });
    final dirB = Directory.systemTemp.createTempSync('import_followup_b_');
    addTearDown(() => dirB.deleteSync(recursive: true));
    final pathB = await sourceWith(dirB, lostKey: false);

    final launch = app.resumeUnfinishedImport(); // launch recovery, no await
    final b = app.importEdgeBackup(pathB); // B starts at once
    await launch;
    await b;

    expect(app.importProgress.value, isNot(isA<ImportFailed>()));
    // A later CSV import hands back whatever failure is retained: it must not
    // be A's old one.
    final csv = File('${tmp.path}/noop.csv');
    final base = DateTime(2026, 10, 20, 8).millisecondsSinceEpoch ~/ 1000;
    final rows = StringBuffer('unix_s,iso_utc,stream,hr_bpm,rr_ms\n');
    for (var i = 0; i < 600; i++) {
      rows.writeln('${base + i},x,hr,${60 + i % 5},');
    }
    csv.writeAsStringSync(rows.toString());
    await app.importNoopCsv(csv.path);
    expect(app.importProgress.value, isNot(isA<ImportFailed>()),
        reason: 'B succeeded; A\'s old error must not be put back');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
