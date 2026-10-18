// Settings > Developer > Device lab (dev mode only) is the lab's
// entrance. The view is pure, so the push is a callback, like onGallery.
//
// Contract pinned here: MoreSettingsView gets `VoidCallback? onDeviceLab`
// (same name as DeviceDetailView and the Haptics hub use). Kept in its own
// file so a missing parameter fails only this file's compile.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
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

void main() {
  testWidgets('tapping Device lab in the Developer group calls onDeviceLab',
      (t) async {
    var opened = 0;
    await _pump(t, MoreSettingsView(devMode: true, onDeviceLab: () => opened++));
    await t.tap(find.text('Device lab'));
    await t.pump();
    expect(opened, 1);
  });

  testWidgets('with dev mode off there is no Device lab row to tap',
      (t) async {
    var opened = 0;
    await _pump(t, MoreSettingsView(onDeviceLab: () => opened++));
    expect(find.text('Device lab'), findsNothing);
    expect(opened, 0);
  });
}
