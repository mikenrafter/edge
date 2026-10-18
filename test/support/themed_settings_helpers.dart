// Shared helpers for the themed settings tests. References no symbol that does not
// exist today, so every test file that imports it compiles before the
// implementation lands and fails for its own reason.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';

/// [home] under a themed app with the locale provider the settings views read.
Widget g123App(Widget home) => ChangeNotifierProvider<LocaleController>.value(
      value: LocaleController.seed(null),
      child: MaterialApp(theme: buildTheme(Brightness.light), home: home),
    );

/// A phone-sized, 390 x [height] pt view. A tall view builds every row of a
/// lazy list; a phone height keeps the list lazy and scrollable.
void g123View(WidgetTester t, {double width = 390, double height = 800}) {
  t.view.physicalSize = Size(width * 3, height * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

/// Let the app-prefs queue drain: several short frames, then a full settle.
Future<void> g123Settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await t.pumpAndSettle();
}

Finder accordionById(String id) => find.byWidgetPredicate(
    (w) => w is SettingsAccordion && w.id == id,
    description: 'SettingsAccordion id "$id"');

/// True when the accordion's rows are in the tree (its first child is built).
bool accordionOpen(WidgetTester t, Finder accordion) {
  final a = t.widget<SettingsAccordion>(accordion);
  return find
      .descendant(of: accordion, matching: find.byWidget(a.children.first))
      .evaluate()
      .isNotEmpty;
}

/// Every accordion that carries an id, as `id -> open`, in tree order. Only
/// accordions that are currently built are listed (use a tall view).
Map<String, bool> openStates(WidgetTester t) {
  final out = <String, bool>{};
  for (final e in find
      .byType(SettingsAccordion)
      .evaluate()
      .map((e) => e.widget as SettingsAccordion)) {
    final id = e.id;
    if (id == null) continue;
    out[id] = accordionOpen(t, accordionById(id));
  }
  return out;
}

/// Tap the header of the accordion with [id] and let the write settle.
Future<void> toggleAccordion(WidgetTester t, String id) async {
  await t.tap(find
      .descendant(of: accordionById(id), matching: find.byType(Pressable))
      .first);
  await g123Settle(t);
}
