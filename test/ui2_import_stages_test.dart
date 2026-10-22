// RED: finer import stages on the import page (Settings > Your data).
//
// Every ImportProgress the producers publish today:
//   ImportPreparing(inflating)            restore.dart  "Unpacking the backup"
//   ImportPreparing(opening)              restore.dart, app_state CSV paths
//   ImportPreparing(checking)             restore.dart
//   ImportPreparing(counting, done, total) restore.dart  (tables counted)
//   ImportPreparing(null)                 step not known yet
//   ImportCopying(stage, rows, total, i, n)
//   ImportResuming (a Copying)            import_run.dart, built as
//                                         (stage, lastRowid, total, 0, 1)
//   ImportRebuilding(done, total, day)
//   ImportDone / ImportFailed
//
// Gaps pinned here:
//   1. counting carries done/total and neither the header line, the full view
//      nor the compact Settings row shows it;
//   2. a null step shares the "Opening the backup" text;
//   3. a resumed import is drawn as a copy with "Step 0 of 1" (invented: the
//      journal does not know the stage count) and a row count taken from a
//      rowid, not from a count of rows;
//   4. a CSV import clears AppState.importProgress when its first day is
//      derived, so a fresh Your data page (leave and return) shows the Import
//      button again while the import is still running.
//
// New strings are asserted by English text plus a stable Key. ARB keys to add
// are listed in the commit report.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/import_progress_view.dart';
import 'package:openstrap_edge/ui2/status_line.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import 'support/app_state_derive_harness.dart';

const _counting = ImportPreparing(ImportPrepStep.counting, 3, 12);
const _countingNoCounts = ImportPreparing(ImportPrepStep.counting);
const _resuming = ImportResuming(ImportStage.sleep, 1234, 5000, 0, 1);

Future<void> _pump(WidgetTester t, ImportProgress s, {bool compact = false}) =>
    t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
          body: ListView(children: [ImportProgressView(s, compact: compact)])),
    ));

LinearProgressIndicator? _bar(WidgetTester t) {
  final f = find.byType(LinearProgressIndicator);
  return f.evaluate().isEmpty ? null : t.widget<LinearProgressIndicator>(f);
}

void main() {
  group('preparing stages', () {
    testWidgets('counting shows "3 of 12" in the header line, with its own '
        'text and no count when the producer gave none', (t) async {
      final withCounts = StatusLine.importLine(null, _counting);
      expect(withCounts, contains('Counting'));
      expect(withCounts, contains('3 of 12'),
          reason: 'the producer measured 3 of 12 tables');
      final without = StatusLine.importLine(null, _countingNoCounts);
      expect(without, contains('Counting'));
      expect(without, isNot(matches(RegExp(r'\d'))),
          reason: 'no count measured, so no number');
      // total 0 is "unknown", not "0 of 0".
      expect(
          StatusLine.importLine(
              null, const ImportPreparing(ImportPrepStep.counting, 0, 0)),
          isNot(contains('0 of 0')));
    });

    testWidgets('full view: count line with a stable key and a determinate '
        'bar; box height unchanged against other stages', (t) async {
      await _pump(t, _counting);
      final line = find.byKey(const ValueKey('import-prep-count'));
      expect(line, findsOneWidget);
      expect(t.widget<Text>(line).data, contains('3 of 12'));
      expect(_bar(t)?.value, closeTo(3 / 12, 1e-9));
      final h = t.getSize(find.byType(ImportProgressView)).height;

      await _pump(t, const ImportPreparing(ImportPrepStep.counting, 0, 12));
      expect(t.widget<Text>(line).data, contains('0 of 12'));
      expect(_bar(t)?.value, 0.0);

      await _pump(t, _countingNoCounts);
      expect(find.byKey(const ValueKey('import-prep-count')), findsNothing,
          reason: 'absent counts stay absent');
      expect(_bar(t)?.value, isNull, reason: 'no bar, or an indeterminate one');

      await _pump(t, const ImportCopying(ImportStage.sleep, 1, 4, 3, 9));
      expect(t.getSize(find.byType(ImportProgressView)).height, h);
    });

    testWidgets('compact (the Settings row) shows the count too', (t) async {
      await _pump(t, _counting, compact: true);
      expect(find.byKey(const ValueKey('import-prep-count')), findsOneWidget);
      expect(find.textContaining('3 of 12'), findsWidgets);
    });

    testWidgets('each step has its own text; an unknown step is not "Opening"',
        (t) async {
      final seen = <String>{};
      for (final s in [
        ImportPrepStep.inflating,
        ImportPrepStep.opening,
        ImportPrepStep.checking,
        ImportPrepStep.counting,
      ]) {
        seen.add(ImportProgressView.statusOf(null, ImportPreparing(s)));
      }
      expect(seen.length, 4);
      final unknown = ImportProgressView.statusOf(null, const ImportPreparing());
      expect(seen, isNot(contains(unknown)),
          reason: 'a step nobody has reported is not "Opening the backup"');
      expect(unknown, 'Getting the backup ready');
    });
  });

  group('resuming', () {
    testWidgets('has its own label and invents no step or row count',
        (t) async {
      final status = ImportProgressView.statusOf(null, _resuming);
      expect(status, contains('Resuming'));
      expect(status, contains('sleep'));
      final line = StatusLine.importLine(null, _resuming);
      expect(line, isNot(contains('step 0 of 1')),
          reason: 'the stage count is not known on resume');

      await _pump(t, _resuming);
      expect(find.textContaining('Step 0 of'), findsNothing);
      expect(find.textContaining('1,234 of 5,000'), findsNothing,
          reason: '1234 is a rowid, not a count of rows done');
      expect(find.byKey(const ValueKey('import-resuming')), findsOneWidget);
      expect(_bar(t)?.value, isNull);
    });
  });

  group('persistence for a CSV import', () {
    const name = 'import_stages_csv.db';
    late Directory tmp;
    late AppState app;

    setUp(() async {
      await deriveDbSetUp(name);
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('import_stages_');
      app = AppState.forTesting();
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    });
    tearDown(() async {
      app.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
      await deriveDbTearDown(name);
    });

    test('importProgress is never cleared while the import still runs',
        () async {
      final f = File(p.join(tmp.path, 'noop.csv'));
      final base = DateTime(2026, 10, 20, 8).millisecondsSinceEpoch ~/ 1000;
      final rows = StringBuffer('unix_s,iso_utc,stream,hr_bpm,rr_ms\n');
      for (var i = 0; i < 600; i++) {
        rows.writeln('${base + i},x,hr,${60 + i % 5},');
      }
      f.writeAsStringSync(rows.toString());

      // What the import page would read each time a day is being derived.
      final whileDeriving = <ImportProgress?>[];
      app.deriveProgress.addListener(() {
        if (app.deriveProgress.value != null) {
          whileDeriving.add(app.importProgress.value);
        }
      });
      final days = await app.importNoopCsv(f.path);
      expect(days, greaterThan(0));
      expect(whileDeriving, isNotEmpty, reason: 'guard: days were derived');
      // A page opened mid-import must show the spinner, not the Import button.
      expect(whileDeriving, everyElement(isNotNull),
          reason: 'the spinner must persist for the whole CSV import');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
