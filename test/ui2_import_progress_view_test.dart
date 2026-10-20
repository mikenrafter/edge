// ImportProgressView: what a running import is doing, stage by stage. Each
// line is a status (what is happening now); countable work shows done/total.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/ui2/profile/import_progress_view.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

Future<void> _pump(WidgetTester t, ImportProgress p) => t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: ListView(children: [ImportProgressView(p)])),
    ));

double? _barValue(WidgetTester t) =>
    t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value;

void main() {
  group('preparing', () {
    for (final (step, text) in [
      (ImportPrepStep.inflating, 'Unpacking the backup'),
      (ImportPrepStep.opening, 'Opening the backup'),
      (ImportPrepStep.checking, 'Checking the backup'),
      (null, 'Opening the backup'),
    ]) {
      testWidgets('$step => $text and a spinner', (t) async {
        await _pump(t, ImportPreparing(step));
        expect(find.text(text), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      });
    }
  });

  group('copying', () {
    testWidgets('stage, step count, row count and a determinate bar',
        (t) async {
      await _pump(t, const ImportCopying(ImportStage.heartRate, 500, 2000, 2, 9));
      expect(find.text('Copying heart rate'), findsOneWidget);
      expect(find.text('Step 2 of 9 · 500 of 2,000 rows'), findsOneWidget);
      expect(_barValue(t), closeTo(0.25, 1e-9));
    });

    testWidgets('rowsTotal 0 => indeterminate bar', (t) async {
      await _pump(t, const ImportCopying(ImportStage.heartRate, 0, 0, 1, 9));
      expect(find.text('Copying heart rate'), findsOneWidget);
      expect(_barValue(t), isNull);
    });
  });

  testWidgets('rebuilding: day count, last day and a determinate bar',
      (t) async {
    await _pump(t, const ImportRebuilding(41, 212, '2026-03-14'));
    expect(find.text('Recalculating · day 41 of 212 · 2026-03-14'),
        findsOneWidget);
    expect(_barValue(t), closeTo(41 / 212, 1e-9));
  });

  testWidgets('rebuilding with no finished day yet: no day suffix', (t) async {
    await _pump(t, const ImportRebuilding(0, 212, null));
    expect(find.textContaining('Recalculating'), findsOneWidget);
    expect(find.textContaining('2026'), findsNothing);
  });

  // The importer posts Rebuilding(0, 0, null) before the pass has chosen its
  // days: no "day 0 of 0", and no bar that claims a fraction.
  testWidgets('rebuilding before the day count is known', (t) async {
    await _pump(t, const ImportRebuilding(0, 0, null));
    expect(find.text('Recalculating your days'), findsOneWidget);
    expect(find.textContaining('of 0'), findsNothing);
    expect(_barValue(t), isNull);
  });

  testWidgets('failed: the error text', (t) async {
    await _pump(t, const ImportFailed('disk full'));
    expect(find.textContaining('disk full'), findsOneWidget);
  });

  testWidgets('done: nothing', (t) async {
    await _pump(t, const ImportDone());
    expect(find.byType(Text), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
