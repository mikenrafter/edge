// The Device lab's Logs tab: Export (a ZIP through the share flow) and Clear (a
// confirm first) for the persistent dev log.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

final _export = find.text('Export dev log (ZIP)');
final _clear = find.text('Clear dev log');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('no buttons when the screen has no dev log to act on',
      (t) async {
    await _pump(t, const DeviceLabView(initialTab: LabTab.logs, ecgSupported: false));
    expect(_export, findsNothing);
    expect(_clear, findsNothing);
  });

  testWidgets('both buttons are on the Logs tab, and only there', (t) async {
    await _pump(
        t,
        DeviceLabView(
          initialTab: LabTab.logs,
          ecgSupported: false,
          tapTools: true,
          exportDevLog: (_) async => true,
          clearDevLog: () async {},
        ));
    expect(_export, findsOneWidget);
    expect(_clear, findsOneWidget);
    await t.tap(find.byKey(const ValueKey('device-lab-tab:taps')));
    await t.pumpAndSettle();
    expect(_export, findsNothing);
  });

  testWidgets('Export hands the share flow an origin, once; a failure says so',
      (t) async {
    final origins = <Rect>[];
    var ok = true;
    await _pump(
        t,
        DeviceLabView(
          initialTab: LabTab.logs,
          ecgSupported: false,
          exportDevLog: (o) async {
            origins.add(o);
            return ok;
          },
          clearDevLog: () async {},
        ));
    await t.tap(_export);
    await t.pumpAndSettle();
    expect(origins, hasLength(1));
    expect(find.text('Could not export the dev log.'), findsNothing);
    ok = false;
    await t.tap(_export);
    await t.pumpAndSettle();
    expect(origins, hasLength(2));
    expect(find.text('Could not export the dev log.'), findsOneWidget);
  });

  testWidgets('an export that throws is the same message, not a crash',
      (t) async {
    await _pump(
        t,
        DeviceLabView(
          initialTab: LabTab.logs,
          ecgSupported: false,
          exportDevLog: (_) async => throw StateError('boom'),
        ));
    await t.tap(_export);
    await t.pumpAndSettle();
    expect(find.text('Could not export the dev log.'), findsOneWidget);
  });

  testWidgets('Clear asks first: keeping it clears nothing', (t) async {
    var cleared = 0;
    await _pump(
        t,
        DeviceLabView(
          initialTab: LabTab.logs,
          ecgSupported: false,
          clearDevLog: () async => cleared++,
        ));
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
    await _pump(
        t,
        DeviceLabView(
          initialTab: LabTab.logs,
          ecgSupported: false,
          clearDevLog: () async => cleared++,
        ));
    await t.tap(_clear);
    await t.pumpAndSettle();
    await t.tap(find.text('Clear').last);
    await t.pumpAndSettle();
    expect(cleared, 1);
    expect(find.text('Dev log cleared'), findsOneWidget);
  });

  testWidgets('a clear that fails says so', (t) async {
    await _pump(
        t,
        DeviceLabView(
          initialTab: LabTab.logs,
          ecgSupported: false,
          clearDevLog: () async => throw StateError('locked'),
        ));
    await t.tap(_clear);
    await t.pumpAndSettle();
    await t.tap(find.text('Clear').last);
    await t.pumpAndSettle();
    expect(find.text('Could not clear the dev log.'), findsOneWidget);
  });
}
