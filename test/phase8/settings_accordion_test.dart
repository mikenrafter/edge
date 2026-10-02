// 8C/8J — the SettingsAccordion API: expanded by default, and a one-line
// summary that stays visible under the header while collapsed.
// See test/phase8/CONTRACTS.md §8C.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';

import 'support/sections.dart';

void main() {
  testWidgets('expanded is the default', (t) async {
    await pumpTall(
        t,
        const Scaffold(
          body: SettingsAccordion('Alarm', children: [Text('Wake time')]),
        ));
    expect(find.text('Wake time'), findsOneWidget);
    expect(const SettingsAccordion('x', children: []).initiallyExpanded, isTrue);
  });

  testWidgets('collapsed: header + summary line, rows hidden', (t) async {
    await pumpTall(
        t,
        const Scaffold(
          body: SettingsAccordion('Alarm',
              summary: 'Weekdays at 07:00',
              initiallyExpanded: false,
              children: [Text('Wake time')]),
        ));
    expect(find.text('Alarm'), findsOneWidget);
    expect(find.text('Weekdays at 07:00'), findsOneWidget);
    expect(find.text('Wake time'), findsNothing);

    await t.tap(find.text('Alarm'));
    await t.pumpAndSettle();
    expect(find.text('Wake time'), findsOneWidget);

    await t.tap(find.text('Alarm'));
    await t.pumpAndSettle();
    expect(find.text('Weekdays at 07:00'), findsOneWidget,
        reason: 'collapsing again brings the summary back');
    expect(find.text('Wake time'), findsNothing);
  });

  testWidgets('the summary is one line', (t) async {
    await pumpTall(
        t,
        const Scaffold(
          body: SettingsAccordion('Haptics',
              summary: 'A long summary that would wrap onto a second line if '
                  'it were allowed to, which it must not be',
              initiallyExpanded: false,
              children: [Text('row')]),
        ));
    final text = t.widget<Text>(find.textContaining('A long summary'));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('the header keeps its position when toggled', (t) async {
    await pumpTall(
        t,
        const Scaffold(
          body: SettingsAccordion('Status',
              summary: 'Confirmed', children: [Text('row')]),
        ));
    final before = t.getTopLeft(find.text('Status'));
    await t.tap(find.text('Status'));
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.text('Status')), before);
  });
}
