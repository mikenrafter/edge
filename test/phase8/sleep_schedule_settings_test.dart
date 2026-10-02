// 8E — Settings has an expected-sleep-schedule editor that works with no data.
// See test/phase8/CONTRACTS.md §8E.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/control_operations.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 15000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('no schedule yet: the row is there, says "Not set", and opens',
      (t) async {
    var opened = 0;
    await _pump(t, MoreSettingsView(onEditSleepSchedule: () => opened++));
    final row = find.text('Expected sleep schedule');
    expect(row, findsOneWidget);
    expect(find.text('Not set'), findsOneWidget);
    await t.tap(row);
    expect(opened, 1);
  });

  testWidgets('a saved schedule shows its local times', (t) async {
    await _pump(
        t,
        MoreSettingsView(
          expectedSleepSchedule: const ExpectedSleepSchedule(
              onsetMinute: 23 * 60, wakeMinute: 7 * 60),
          onEditSleepSchedule: () {},
        ));
    expect(find.textContaining('23:00'), findsOneWidget);
    expect(find.textContaining('07:00'), findsOneWidget);
  });
}
