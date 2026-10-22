// The sync line (StatusLine, on all four tabs) listens to AppState.importProgress
// and AppState.deriveProgress only. An import started from the WELCOME screen
// goes through runImport -> AppState.importNoopCsv / importWhoopCsvs, which
// hand the engine a bare onProgress callback and publish NOTHING to either
// notifier; the derivation runs on the engine directly (deriveImportedDays),
// not through DeriveCoordinator, so deriveProgress never moves either. The
// phone works for minutes and the line says "Synced through ...".
//
// Seam under test: the real runImport (what welcome.dart calls) against a real
// AppState. The notifiers are sampled on every change, which is exactly what
// StatusLine's ValueListenableBuilders see.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:openstrap_edge/ui2/status_line.dart';

import 'step2/support/p23_support.dart';
import 'support/app_state_derive_harness.dart';

const _name = 'one_phase_welcome_path.db';

File _noop(Directory tmp) {
  final t = DateTime.now();
  final base = DateTime(t.year, t.month, t.day, 8).millisecondsSinceEpoch ~/ 1000;
  final rows = StringBuffer('unix_s,iso_utc,stream,hr_bpm,rr_ms\n');
  for (var i = 0; i < 600; i++) {
    rows.writeln('${base + i},x,hr,${60 + i % 5},');
  }
  return File(p.join(tmp.path, 'noop.csv'))..writeAsStringSync(rows.toString());
}

File _whoop(Directory tmp) {
  final wake = '${p23Day(1)} 08:30:00';
  return File(p.join(tmp.path, 'physiological_cycles.csv'))
    ..writeAsStringSync(
      'Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),'
      'Heart rate variability (ms),Day Strain,Energy burned (cal),'
      'Asleep duration (min)\n'
      '$wake,$wake,42,70,19,7.5,2400,300\n',
    );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState app;
  late List<ImportProgress?> imports;
  late List<DeriveProgress?> derives;

  setUp(() async {
    await deriveDbSetUp(_name);
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('one_phase_welcome_');
    app = AppState.forTesting();
    app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    imports = [];
    derives = [];
    app.importProgress.addListener(() => imports.add(app.importProgress.value));
    app.deriveProgress.addListener(() => derives.add(app.deriveProgress.value));
  });
  tearDown(() async {
    app.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    await deriveDbTearDown(_name);
  });

  /// Something the sync line would have rendered for this value.
  bool running(ImportProgress? v) =>
      v != null && v is! ImportDone && v is! ImportFailed;

  void expectImportShown(String entry) {
    expect(imports.where(running), isNotEmpty,
        reason: '$entry: no "Importing · <step>" was ever published, so the '
            'sync line on Home says nothing while rows are copied');
    for (final v in imports.where(running)) {
      expect(StatusLine.importLine(null, v!), startsWith('Importing'),
          reason: 'what the line would print for $v');
    }
    expect(running(app.importProgress.value), isFalse,
        reason: 'cleared when done');
  }

  void expectDeriveShown(String entry) {
    expect(derives.whereType<DeriveProgress>(), isNotEmpty,
        reason: '$entry: no "Recalculating · day i of N" was ever published; '
            'the days were derived on the engine, outside the coordinator');
    for (final d in derives.whereType<DeriveProgress>()) {
      if (d.dayTotal != null) {
        expect(d.dayTotal, greaterThan(0));
        expect(d.dayIndex ?? 0, lessThanOrEqualTo(d.dayTotal!),
            reason: 'never an invented "day i of N"');
      }
    }
    expect(app.deriveProgress.value, isNull, reason: 'cleared when done');
  }

  test('welcome: a NOOP raw CSV publishes import progress',
      () async {
    final f = _noop(tmp);

    final out = await runImport(app, [f.path]);

    expect(out.nothingLanded, isFalse, reason: 'guard: the import worked');
    expectImportShown('NOOP raw CSV');
  });

  test('welcome: a NOOP raw CSV publishes recalculation progress', () async {
    final f = _noop(tmp);
    await runImport(app, [f.path]);
    expectDeriveShown('NOOP raw CSV');
  });

  test('welcome: a WHOOP export publishes import progress',
      () async {
    final f = _whoop(tmp);

    final out = await runImport(app, [f.path]);

    expect(out.nothingLanded, isFalse, reason: 'guard: the import worked');
    expectImportShown('WHOOP export');
  });

  test('welcome: a WHOOP export publishes recalculation progress', () async {
    final f = _whoop(tmp);
    await runImport(app, [f.path]);
    expectDeriveShown('WHOOP export');
  });
}
