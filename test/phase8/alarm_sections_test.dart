// 8J — the Alarm screen as sections: Alarm, Wake, Status (8AE dropped the
// Haptics group; the alarm buzz is the band's own).
// All expanded by default; a collapsed section still shows a one-line summary
// under its header; disconnected means disabled rows, not missing ones (8K).
// Compile-safe on purpose: reads SettingsAccordion only through its existing
// `title`/`children` fields. See test/phase8/CONTRACTS.md §8J.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;

import 'support/sections.dart';

final _schedule = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 5, hour: 6, minute: 30, enabled: true),
  AlarmScheduleEntry(weekday: 2, hour: 7, minute: 0, enabled: true),
]);

AlarmScreenView _view({bool connected = true}) => AlarmScreenView(
      connected: connected,
      schedule: _schedule,
      armedAt: DateTime(2026, 8, 22, 6, 30),
      state: AlarmArmState.confirmed,
      now: DateTime(2026, 8, 21, 22, 40),
    );

const _sections = ['Alarm', 'Wake', 'Status'];

void main() {
  testWidgets('three sections, in order, all expanded', (t) async {
    await pumpTall(t, _view());
    expect(sectionTitles(t), _sections);
    await expectAllSectionsExpanded(t, 'Alarm screen');
  });

  testWidgets('Wake holds Natural Wake and Gradual Wake', (t) async {
    await pumpTall(t, _view());
    for (final row in ['Natural Wake', 'Gradual Wake']) {
      expect(
          find.descendant(of: section('Wake'), matching: find.textContaining(row)),
          findsWidgets,
          reason: row);
    }
  });

  testWidgets('Status holds the armed state', (t) async {
    await pumpTall(t, _view());
    expect(
        find.descendant(of: section('Status'), matching: find.text('Confirmed')),
        findsWidgets);
  });

  for (final title in _sections) {
    testWidgets('$title collapsed still shows a one-line summary', (t) async {
      await pumpTall(t, _view());
      expect(section(title), findsOneWidget, reason: 'section $title');
      final header = find.descendant(of: section(title), matching: find.text(title));
      await t.tap(header.first);
      await t.pumpAndSettle();
      final first = t.widget<SettingsAccordion>(section(title)).children.first;
      expect(find.descendant(of: section(title), matching: find.byWidget(first)),
          findsNothing,
          reason: 'tapping the header collapses $title');
      final lines = t
          .widgetList<Text>(
              find.descendant(of: section(title), matching: find.byType(Text)))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .where((s) => s.trim().isNotEmpty && s != title)
          .toList();
      expect(lines, isNotEmpty, reason: '$title needs a summary when collapsed');
    });
  }

  testWidgets('disconnected: every section and every day row is still there',
      (t) async {
    await pumpTall(t, _view(connected: false));
    expect(sectionTitles(t), _sections);
    expect(find.text('The band is not connected'), findsOneWidget,
        reason: 'the reason is stated once');
    final wake = find.text('Wake time');
    expect(wake, findsNWidgets(_schedule.length),
        reason: 'one wake-time row per day, enabled or not');
    // 8O: edits are a draft, so a missing band does not block them. Only the
    // days that are off dim their time row, connected or not.
    final dimmed = wake.evaluate().where((e) => isDimmed(t, find.byWidget(e.widget)));
    expect(dimmed, hasLength(_schedule.where((d) => !d.enabled).length));
  });

  testWidgets('connected: a day that is off still shows its wake time, dimmed',
      (t) async {
    await pumpTall(t, _view());
    final wake = find.text('Wake time');
    expect(wake, findsNWidgets(_schedule.length));
    final dimmed = wake.evaluate().where((e) => isDimmed(t, find.byWidget(e.widget)));
    expect(dimmed, hasLength(_schedule.where((d) => !d.enabled).length));
  });
}
