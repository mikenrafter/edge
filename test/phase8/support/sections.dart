// Shared widget-test helpers for the phase 8 settings-screen tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/ui2.dart';

/// Pump [w] in a view tall enough that a ListView builds every row.
Future<void> pumpTall(WidgetTester t, Widget w,
    {Brightness brightness = Brightness.light}) async {
  t.view.physicalSize = const Size(1170, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(brightness), home: w));
  await t.pumpAndSettle();
}

List<SettingsAccordion> accordions(WidgetTester t) =>
    t.widgetList<SettingsAccordion>(find.byType(SettingsAccordion)).toList();

List<String> sectionTitles(WidgetTester t) =>
    [for (final a in accordions(t)) a.title];

Finder section(String title) => find.byWidgetPredicate(
    (w) => w is SettingsAccordion && w.title == title,
    description: 'SettingsAccordion "$title"');

/// ≥ 1 accordion, and each one's first child is in the tree without a tap.
Future<void> expectAllSectionsExpanded(WidgetTester t, String screen) async {
  final all = accordions(t);
  expect(all, isNotEmpty, reason: '$screen has no SettingsAccordion');
  for (final a in all) {
    expect(a.children, isNotEmpty,
        reason: '$screen: section "${a.title}" has no rows');
    expect(
        find.descendant(
            of: section(a.title), matching: find.byWidget(a.children.first)),
        findsOneWidget,
        reason: '$screen: section "${a.title}" starts collapsed');
  }
}

/// A row is "disabled and dimmed": something at or above [rowText] is an
/// Opacity below 1, and the row does not respond (checked by the caller).
bool isDimmed(WidgetTester t, Finder rowText) => find
    .ancestor(
        of: rowText,
        matching: find.byWidgetPredicate(
            (w) => (w is Opacity && w.opacity < 1) ||
                (w is AnimatedOpacity && w.opacity < 1)))
    .evaluate()
    .isNotEmpty;
