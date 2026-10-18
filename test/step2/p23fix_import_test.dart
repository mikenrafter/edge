// P2.3 fix round 1, finding 3: every completed import publishes through the
// PublishGate, so the freshness row Home reads (`compute_freshness.today`) is
// rewritten BEFORE the revision bump that makes Home reload.
//
// Repro: today's freshness is stamped "missing"; yesterday's scored sleep is
// imported; Home reloads, but getToday keeps "missing" and the imported night
// is invisible until a restart. Behavioural: a real import, then the rows.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';

import '../support/app_state_derive_harness.dart';
import 'support/p23_support.dart';

const _name = 'p23fix_import.db';

class _Rollup implements ImportRollupProbe {
  _Rollup({this.throwing});
  final Object? throwing;
  @override
  Future<void> finalize(Profile profile) async {
    if (throwing != null) throw throwing!;
  }
}

Future<Map<String, dynamic>> _today() async =>
    jsonDecode((await p23FreshnessRows(await LocalDb.instance))['today']!) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Directory tmp;
  late AppState app;
  late List<Future<Map<String, dynamic>>> seenAtBump;

  setUp(() async {
    await deriveDbSetUp(_name);
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('p23fix_import_');
    app = AppState.forTesting();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    seenAtBump = [];
    // What Home would read the moment it is told to reload.
    app.insightsRevision.addListener(() => seenAtBump.add(_today()));
    // The freshness row Home reads is stamped before the import: nothing yet.
    await LocalDb.refreshComputeFreshness();
    final before = await _today();
    expect(before['overnight_day'], isNull, reason: 'guard: stamped "missing"');
    expect(before['recovery_day'], isNull);
  });
  tearDown(() async {
    app.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    await deriveDbTearDown(_name);
  });

  void expectHomeSeesYesterday(Map<String, dynamic> row) {
    expect(row['recovery_day'], p23Day(1));
    expect(row['showing_prior_overnight'] == true || row['overnight_day'] != null || row['recovery_day'] != null, isTrue);
  }

  test('a WHOOP CSV import: the freshness is rewritten before Home reloads',
      () async {
    final f = File(p.join(tmp.path, 'physiological_cycles.csv'));
    final wake = '${p23Day(1)} 08:30:00';
    f.writeAsStringSync(
      'Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),'
      'Heart rate variability (ms),Day Strain,Energy burned (cal),'
      'Asleep duration (min)\n'
      '$wake,$wake,42,70,19,7.5,2400,300\n',
    );

    final days = await app.importWhoopCsvs([f.path]);

    expect(days, 1);
    expect(app.insightsRevision.value, greaterThan(0));
    final atBump = await seenAtBump.last;
    expectHomeSeesYesterday(atBump);
    expectHomeSeesYesterday(await _today());
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    final out = await repo.getToday();
    expect((out['daily'] as Map), isNotEmpty,
        reason: 'the imported night reaches Home without a restart');
  });

  group('an Edge backup import', () {
    /// A backup holding yesterday's scored night; the local copy is deleted so
    /// the import is what brings it back.
    Future<String> backupWithYesterday() async {
      final db = await LocalDb.instance;
      await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 70),
          computedAt: 4000, readinessColumn: 70);
      final dest = p.join(tmp.path, 'backup.db');
      await db.execute('VACUUM INTO ?', [dest]);
      await LocalDb.deleteDays({p23Day(1)});
      await LocalDb.refreshComputeFreshness();
      expect((await _today())['recovery_day'], isNull);
      return dest;
    }

    test('publishes after the merge: Home sees the imported night', () async {
      final path = await backupWithYesterday();
      app.debugFinalizeImport = _Rollup();

      final days = await app.importEdgeBackup(path);

      expect(days, greaterThan(0));
      expect(app.importRollupError, isNull);
      expectHomeSeesYesterday(await seenAtBump.last);
      expectHomeSeesYesterday(await _today());
    });

    test('publishes when the rollup rebuild fails after the rows committed',
        () async {
      final path = await backupWithYesterday();
      app.debugFinalizeImport = _Rollup(throwing: StateError('rollup failed'));

      final days = await app.importEdgeBackup(path);

      expect(days, greaterThan(0));
      expect(app.importRollupError, contains('rollup failed'),
          reason: 'the failure is still reported');
      expect(app.insightsRevision.value, greaterThan(0));
      expectHomeSeesYesterday(await seenAtBump.last);
      expectHomeSeesYesterday(await _today());
    });
  });

  test('a NOOP raw CSV import: today\'s derived row is in the freshness before '
      'Home reloads', () async {
    final f = File(p.join(tmp.path, 'noop.csv'));
    final base = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day, 8)
            .millisecondsSinceEpoch ~/
        1000;
    final rows = StringBuffer('unix_s,iso_utc,stream,hr_bpm,rr_ms\n');
    for (var i = 0; i < 600; i++) {
      rows.writeln('${base + i},x,hr,${60 + i % 5},');
    }
    f.writeAsStringSync(rows.toString());

    final days = await app.importNoopCsv(f.path);

    expect(days, greaterThan(0));
    final atBump = await seenAtBump.last;
    expect(atBump['activity_state'], 'ready');
    expect((await _today())['activity_state'], 'ready');
  });
}
