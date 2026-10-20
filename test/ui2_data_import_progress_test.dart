// Your data, while busy: the bare spinner at the foot of the screen becomes
// ImportProgressView when an import reports progress, and otherwise an
// InlineLoading with a status, never a spinner on its own.
//
// ASSUMED: DataScreenView takes `ImportProgress? importProgress`; DataScreen
// feeds it from AppState.importProgress. Tested at the headless view, which
// is where `busy` lives (DataScreen's busy flag is private state set only
// inside an action). Built through Function.apply so this file compiles
// before the parameter exists; until then the first case fails with a
// NoSuchMethodError.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show InlineLoading, buildTheme;


// A spinner animates forever, so pumpAndSettle never returns: explicit pumps.
Future<void> pumpTall(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

Widget _data({required bool busy, ImportProgress? progress}) =>
    Function.apply(DataScreenView.new, const [], {
      #busy: busy,
      #importProgress: progress,
    }) as Widget;

void main() {
  testWidgets('busy with import progress: the stage, not a bare spinner',
      (t) async {
    await pumpTall(
        t,
        _data(
            busy: true,
            progress:
                const ImportCopying(ImportStage.heartRate, 500, 2000, 2, 9)));
    expect(find.text('Copying heart rate'), findsOneWidget);
    expect(find.text('Step 2 of 9 · 500 of 2,000 rows'), findsOneWidget);
  });

  testWidgets('busy with no import: a spinner with a status', (t) async {
    await pumpTall(t, const DataScreenView(busy: true));
    expect(find.byType(InlineLoading), findsOneWidget);
  });
}
