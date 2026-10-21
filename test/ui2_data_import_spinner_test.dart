// Your data > "Import a file": while an import runs, the button is replaced by
// the spinner, and the spinner says what the header StatusLine says. The state
// lives on AppState.importProgress, so leaving the page and coming back shows
// it again. No real clock; no file picker.
//
// Import kinds on this page that report through AppState.importProgress: only
// "Import a file" (backup / journal CSV / vendor export, all via runImport).
// "From your phone" opens PhoneImport, which has its own page-local busy flag
// and does not use importProgress; it is not covered here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/profile/import_progress_view.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/status_line.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

const _copying = ImportCopying(ImportStage.heartRate, 500, 2000, 2, 9);
const _copying2 = ImportCopying(ImportStage.sleep, 10, 40, 3, 9);
const _rebuilding = ImportRebuilding(3, 12, '2026-10-01');

String _line(ImportProgress p) => StatusLine.importLine(null, p);

// A spinner animates forever: explicit pumps, never pumpAndSettle.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1170, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _pumpView(WidgetTester t, Widget w) async {
  _tall(t);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await _settle(t);
}

Widget _view({bool busy = false, ImportProgress? progress, VoidCallback? onImport,
        VoidCallback? onPhone}) =>
    DataScreenView(
        busy: busy,
        importProgress: progress,
        onImport: onImport,
        onPhoneImport: onPhone);

class _App extends AppState {
  _App() : super.forTesting();
}

Widget _page(_App app, {bool show = true}) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: show ? const DataScreen() : const Scaffold(body: SizedBox())),
    );

void main() {
  group('the spinner carries the header status text', () {
    testWidgets('same text as StatusLine.importLine, and it follows progress',
        (t) async {
      await _pumpView(t, _view(busy: true, progress: _copying));
      expect(find.text(_line(_copying)), findsOneWidget);
      await _pumpView(t, _view(busy: true, progress: _copying2));
      expect(find.text(_line(_copying2)), findsOneWidget);
      expect(find.text(_line(_copying)), findsNothing);
      await _pumpView(t, _view(busy: true, progress: _rebuilding));
      expect(find.text(_line(_rebuilding)), findsOneWidget);
    });

    testWidgets('the spinner is inside the import progress view', (t) async {
      await _pumpView(t, _view(busy: true, progress: _copying));
      expect(
          find.descendant(
              of: find.byType(ImportProgressView),
              matching: find.text(_line(_copying))),
          findsOneWidget);
    });
  });

  group('the spinner replaces the Import button in its slot', () {
    testWidgets('button text gone, spinner where it was, rows below unmoved',
        (t) async {
      await _pumpView(t, _view(onImport: () {}, onPhone: () {}));
      final buttonTop = t.getTopLeft(find.text('Import a file')).dy;
      final rowRect = t.getRect(find.ancestor(
          of: find.text('Import a file'), matching: find.byType(SetRow)));
      final belowTop = t.getTopLeft(find.text('From your phone')).dy;

      await _pumpView(
          t, _view(busy: true, progress: _copying, onImport: () {}, onPhone: () {}));
      expect(find.text('Import a file'), findsNothing);
      final spin = t.getRect(find.byType(ImportProgressView));
      expect(spin.top, closeTo(rowRect.top, 1),
          reason: 'spinner takes the import row\'s slot');
      expect(spin.height, closeTo(rowRect.height, 1),
          reason: 'same slot height, so nothing below shifts');
      expect(t.getTopLeft(find.text('From your phone')).dy, closeTo(belowTop, 1));
      expect(buttonTop, greaterThan(0));
    });

    testWidgets('no second spinner at the foot of the page', (t) async {
      await _pumpView(t, _view(busy: true, progress: _copying));
      expect(find.byType(ImportProgressView), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('other rows are inert while the import runs', (t) async {
      var phone = 0;
      await _pumpView(t,
          _view(busy: true, progress: _copying, onPhone: () => phone++));
      await t.tap(find.text('From your phone'), warnIfMissed: false);
      await t.pump();
      expect(phone, 0);
    });
  });

  group('persistence comes from AppState, not page state', () {
    testWidgets('leave and return mid-import: spinner + status again',
        (t) async {
      _tall(t);
      final app = _App();
      addTearDown(app.importProgress.dispose);
      app.importProgress.value = _copying;
      await t.pumpWidget(_page(app));
      await _settle(t);
      expect(find.text(_line(_copying)), findsOneWidget);
      expect(find.text('Import a file'), findsNothing);

      await t.pumpWidget(_page(app, show: false)); // left the page
      await _settle(t);
      app.importProgress.value = _copying2; // still running meanwhile
      await t.pumpWidget(_page(app)); // came back: a fresh State
      await _settle(t);
      expect(find.text(_line(_copying2)), findsOneWidget);
      expect(find.text('Import a file'), findsNothing);
    });

    testWidgets('done: the button returns, the spinner is gone', (t) async {
      _tall(t);
      final app = _App();
      addTearDown(app.importProgress.dispose);
      app.importProgress.value = _copying;
      await t.pumpWidget(_page(app));
      await _settle(t);
      app.importProgress.value = const ImportDone();
      await _settle(t);
      expect(find.text('Import a file'), findsOneWidget);
      expect(find.byType(ImportProgressView), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('failed: the button returns and the failure is shown',
        (t) async {
      _tall(t);
      final app = _App();
      addTearDown(app.importProgress.dispose);
      app.importProgress.value = _copying;
      await t.pumpWidget(_page(app));
      await _settle(t);
      app.importProgress.value = const ImportFailed('disk full');
      await _settle(t);
      expect(find.text('Import a file'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('disk full'), findsOneWidget);
    });
  });
}
