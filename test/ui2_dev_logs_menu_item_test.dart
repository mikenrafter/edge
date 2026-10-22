// RED: a separate "Logs" item in Settings > Developer (developer mode only)
// opens a Logs page with Share and Clear, built on the Device lab's dev-log
// path (shareDevLog + the clear confirm). Never the clipboard (AGENTS.md 16).
//
// Contract pinned here:
//   * MoreSettingsView gets `VoidCallback? onLogs`; the row's title is "Logs".
//   * `DevLogsPage({export, clear})` in lib/ui2/profile/dev_logs_page.dart takes
//     the same injectable seams as the Device lab's dev-log section, with
//     buttons keyed `dev-logs-share` and `dev-logs-clear`.
//   * Copy reuses the lab's: 'Could not export the dev log.', 'Clear the dev
//     log?' with 'Keep it' / 'Clear', and 'Dev log cleared'.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/dev_logs_page.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
    value: LocaleController.seed(null),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: w),
  ));
  await t.pumpAndSettle();
}

final _share = find.byKey(const ValueKey('dev-logs-share'));
final _clear = find.byKey(const ValueKey('dev-logs-clear'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the Developer menu item', () {
    testWidgets('developer mode on: a Logs row is there and calls onLogs',
        (t) async {
      var opened = 0;
      await _pump(t, MoreSettingsView(devMode: true, onLogs: () => opened++));
      expect(find.text('Logs'), findsOneWidget);
      await t.tap(find.text('Logs'));
      await t.pump();
      expect(opened, 1);
    });

    testWidgets('developer mode off: no Logs row', (t) async {
      await _pump(t, MoreSettingsView(onLogs: () {}));
      expect(find.text('Logs'), findsNothing);
    });

    testWidgets('the Device lab row is still there beside it', (t) async {
      await _pump(t, MoreSettingsView(devMode: true, onLogs: () {}));
      expect(find.text('Device lab'), findsOneWidget);
    });
  });

  group('the Logs page', () {
    testWidgets('has Share and Clear, and no Copy', (t) async {
      await _pump(
          t, DevLogsPage(export: (_) async => true, clear: () async {}));
      expect(_share, findsOneWidget);
      expect(_clear, findsOneWidget);
      expect(find.textContaining('Copy'), findsNothing);
    });

    testWidgets('Share calls the export once with an origin; a failure says so',
        (t) async {
      final origins = <Rect>[];
      await _pump(t, DevLogsPage(
        export: (o) async {
          origins.add(o);
          return false;
        },
        clear: () async {},
      ));
      await t.tap(_share);
      await t.pumpAndSettle();
      expect(origins, hasLength(1));
      expect(find.text('Could not export the dev log.'), findsOneWidget);
    });

    testWidgets('a successful Share shows no failure message', (t) async {
      var n = 0;
      await _pump(t, DevLogsPage(
        export: (_) async {
          n++;
          return true;
        },
        clear: () async {},
      ));
      await t.tap(_share);
      await t.pumpAndSettle();
      expect(n, 1);
      expect(find.text('Could not export the dev log.'), findsNothing);
    });

    testWidgets('Clear asks first; Keep it clears nothing', (t) async {
      var cleared = 0;
      await _pump(t, DevLogsPage(
          export: (_) async => true, clear: () async => cleared++));
      await t.tap(_clear);
      await t.pumpAndSettle();
      expect(find.text('Clear the dev log?'), findsOneWidget);
      expect(cleared, 0);
      await t.tap(find.text('Keep it'));
      await t.pumpAndSettle();
      expect(cleared, 0);
      expect(find.text('Clear the dev log?'), findsNothing);
    });

    testWidgets('confirming clears once and says so', (t) async {
      var cleared = 0;
      await _pump(t, DevLogsPage(
          export: (_) async => true, clear: () async => cleared++));
      await t.tap(_clear);
      await t.pumpAndSettle();
      await t.tap(find.text('Clear').last);
      await t.pumpAndSettle();
      expect(cleared, 1);
      expect(find.text('Dev log cleared'), findsOneWidget);
    });

    testWidgets('Share and Clear never touch the clipboard', (t) async {
      final calls = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (c) async {
        calls.add(c.method);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await _pump(t, DevLogsPage(
          export: (_) async => true, clear: () async {}));
      // Without the page's buttons there is nothing exercised: require them.
      expect(_share, findsOneWidget);
      await t.tap(_share);
      await t.pumpAndSettle();
      await t.tap(_clear);
      await t.pumpAndSettle();
      await t.tap(find.text('Clear').last);
      await t.pumpAndSettle();
      expect(calls.where((m) => m.startsWith('Clipboard.')), isEmpty);
    });
  });
}
