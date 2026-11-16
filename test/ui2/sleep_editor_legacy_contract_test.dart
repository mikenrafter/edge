// WHY: editor review r1 legacy-source mismatch. CLAIM(sleep-editor-legacy).
// Use real SQLite, LocalRepositoryImpl, editor controls and the durable writer.
// Stored history is owned for validation but is not a user time override.
import 'dart:convert';
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/sleep_edit_write.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/day_timeline/sleep_timeline_editor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';
import '../support/day_timeline_fixtures.dart';
import '../support/as_of_recalc_fakes.dart' show settle;
import 'sleep_editor_review_r1_test.dart' as rig;

class _DatabaseSaver implements SleepEditSaver {
  _DatabaseSaver(this.db);
  final Database db;
  SleepEditPlan? plan;
  Future<void>? written;
  bool completed = false;
  Object? error;
  @override
  ({Future<void> written, Future<SleepOperationResult> done}) save(SleepEditPlan value) {
    plan = value;
    final receipt = written = writeSleepEdit(db, value);
    receipt.then((_) => completed = true, onError: (Object e) {
      error = e;
      completed = true;
    });
    return (written: receipt, done: receipt.then((_) => const SleepOperationResult(success: true),
      onError: (Object _) => const SleepOperationResult(success: false)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  late Database db;
  const day = '2026-11-14';
  final start = dtAt(800), end = dtAt(840), otherStart = dtAt(900);
  late String snapshot;
  late Map<String, Object?> unrelated;

  setUp(() async {
    env = await BackupEnv.create('sleep-editor-r1-legacy.db');
    db = await LocalDb.instance;
    BundleStore.debugResetShared();
    snapshot = jsonEncode({'start': start, 'end': end, 'source': 'legacy',
      'duration_min': 35, 'deep_min': 10, 'hypnogram': [{'start': start, 'end': end, 'stage': 'light'}]});
    await db.insert('sleep_nap', {'day_id': day, 'start_ts': start, 'end_ts': end,
      'source': 'legacy', 'created_at': 42, 'payload_json': snapshot});
    await db.insert('sleep_nap', {'day_id': day, 'start_ts': otherStart, 'end_ts': otherStart + 1800,
      'source': 'manual', 'created_at': 43, 'payload_json': null});
    unrelated = (await db.query('sleep_nap', where: 'start_ts = ?', whereArgs: [otherStart])).single;
    await db.insert('day_result', {'day_id': day, 'algo_version': kAlgoVersion,
      'payload_json': jsonEncode({'date': day, 'naps': {'value': [jsonDecode(snapshot)]}}),
      'computed_at': 1, 'finalized': 0});
  });
  tearDown(() async {
    BundleStore.debugResetShared();
    await env.dispose();
  });

  Future<Map<String, Object?>> target() async =>
    (await db.query('sleep_nap', where: 'start_ts = ?', whereArgs: [start])).single;

  for (final (label, action, sourceAfter) in [
    ('Calculate selected sleep block stages', SleepEntryAction.stages, 'legacy'),
    ('Remove selected sleep block', SleepEntryAction.remove, 'rejected'),
  ]) {
    testWidgets('legacy editor $label commits the exact row and durable job, preserving snapshots and other naps', (t) async {
      final repo = LocalRepositoryImpl(getProfileMap: () => const {});
      final data = await t.runAsync(() => SleepEditorData.load(repo, day,
        window: (dtAt(160), dtAt(690))));
      expect(data!.napSources.values, contains('legacy'));
      final saver = _DatabaseSaver(db);
      final state = await rig.openEditor(t, saver, data);
      // Real chart tap, not a direct State selection call.
      await rig.tapTime(t, state, start + 600);
      expect(find.text('Back to automatic'), findsNothing);
      expect(find.text('Calculate selected sleep block stages'), findsOneWidget);
      await rig.stage(t, label);
      await t.scrollUntilVisible(find.byKey(SleepTimelineEditor.saveKey), 200);
      await t.pumpAndSettle();
      await t.tap(find.byKey(SleepTimelineEditor.saveKey));
      await t.pump();
      await settle(t, until: () => saver.completed, what: 'legacy durable write');
      expect(saver.error, isNull);
      await t.pumpAndSettle();
      expect(saver.plan!.entry!.source, 'legacy');
      expect(saver.plan!.entry!.action, action);
      final row = await t.runAsync(target);
      expect(row!['source'], sourceAfter);
      expect(sleepEditorDetected((await t.runAsync(()=>sleepEditorPayload(row['payload_json'])))!),jsonDecode(snapshot));
      expect(await t.runAsync(() => db.query('sleep_nap', where: 'start_ts = ?', whereArgs: [otherStart])), [unrelated]);
      final jobs = await t.runAsync(() => db.query('sleep_edit_job'));
      expect(jobs!.map((r) => [r['day_id'], r['phase'], r['revision']]), [[day, 'queued', 1]]);
      // Reopen the durable ledger: history cannot depend on a widget/cache.
      await t.runAsync(() async { await LocalDb.close(); db = await LocalDb.instance; });
      expect(sleepEditorDetected((await t.runAsync(()async=>sleepEditorPayload((await target())['payload_json'])))!),jsonDecode(snapshot));
      if (action == SleepEntryAction.remove) {
        // A queued recomputation must not make the rejected entry disappear
        // from the editor. Restore it through the real UI after reopening.
        final reopened = await t.runAsync(() => SleepEditorData.load(repo, day,
          window: (dtAt(160), dtAt(690))));
        final rejected = reopened!.naps.singleWhere((n) => n.start == start);
        expect(reopened.napSources[rejected.id], 'rejected');
        expect(reopened.naps.map((n) => n.start), contains(otherStart));
        final restoreSaver = _DatabaseSaver(db);
        final restoredEditor = await rig.openEditor(t, restoreSaver, reopened);
        await rig.tapTime(t, restoredEditor, start + 600);
        expect(t.widget<TextButton>(find.byKey(const ValueKey('sleep-editor-calculate'))).onPressed,isNull);
        expect(t.widget<TextButton>(find.byKey(const ValueKey('sleep-editor-remove'))).onPressed,isNull);
        await rig.stage(t, 'Reset to detected (restore nap)');
        await t.tap(find.byKey(SleepTimelineEditor.saveKey));
        await t.pump();
        await settle(t, until: () => restoreSaver.completed, what: 'legacy restore');
        expect(restoreSaver.error, isNull);
        expect(restoreSaver.plan!.entry!.source, 'rejected');
        final restored = await t.runAsync(target);
        expect(restored!['source'], 'legacy');
        expect(sleepEditorDetected((await t.runAsync(()=>sleepEditorPayload(restored['payload_json'])))!),jsonDecode(snapshot));
        expect(await t.runAsync(() => db.query('sleep_nap', where: 'start_ts = ?', whereArgs: [otherStart])), [unrelated]);
        final receipt = await t.runAsync(() => db.query('sleep_edit_job'));
        expect(receipt!.single['revision'], 2);
      }
    });
  }

  test('legacy entry validation refuses a stale snapshot identity and writes nothing', () async {
    await db.update('sleep_nap', {'end_ts': end + 60}, where: 'start_ts = ?', whereArgs: [start]);
    final before = await db.query('sleep_nap', orderBy: 'start_ts');
    await expectLater(writeSleepEdit(db, SleepEditPlan(day: day,
      entry: SleepEntryEdit(start: start, end: end, main: false,
        source: 'legacy', action: SleepEntryAction.remove))), throwsA(isA<SleepEditInvalid>()));
    expect(await db.query('sleep_nap', orderBy: 'start_ts'), before);
    expect(await db.query('sleep_edit_job'), isEmpty);
  });

  test('outer rollback restores the legacy row and its job receipt together', () async {
    final before = await db.query('sleep_nap', orderBy: 'start_ts');
    await expectLater(db.transaction((tx) async {
      await writeSleepEditInTransaction(tx, SleepEditPlan(day: day,
        entry: SleepEntryEdit(start: start, end: end, main: false,
          source: 'legacy', action: SleepEntryAction.remove)));
      expect((await tx.query('sleep_nap', where: 'start_ts = ?', whereArgs: [start])).single['source'], 'rejected');
      expect((await tx.query('sleep_edit_job')).single['phase'], 'queued');
      throw StateError('roll back the surrounding transaction');
    }), throwsStateError);
    expect(await db.query('sleep_nap', orderBy: 'start_ts'), before);
    expect(await db.query('sleep_edit_job'), isEmpty);
  });
}
