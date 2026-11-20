import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/timeline_chart.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/bundled_fonts.dart';
import 'support/pilot_shots.dart';

final _start = DateTime(2026, 11, 19).millisecondsSinceEpoch ~/ 1000;
const _list = ValueKey('pilot-day-list');

Moment _workout(int index) => Moment(
  at: _start + 8 * 3600 + index * 25 * 60,
  until: _start + 8 * 3600 + (index * 25 + 15) * 60,
  title: 'Session ${index + 1}',
  detail: '15 min',
  icon: LucideIcons.dumbbell,
  identity: 'session:$index',
  annotationKind: AnnotationKind.workout,
  color: index.isEven ? C.purple : C.blue,
);

Future<void> _timeline(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({PilotFlag.timelines.key: true});
  await Prefs.reload();
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(390, 900);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.dark),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: pilotShot(DayTimelineScreen(data: TimelineData(
      day: '2026-11-19',
      days: const ['2026-11-19', '2026-11-18'],
      graph: DayGraph(
        dayStart: _start,
        hr: List.generate(1440, (i) => 61 + (i % 90 < 25 ? 30 : 0) + (i % 11) / 2),
        movement: List.generate(1440, (i) => i % 90 < 25 ? .4 : .03),
      ),
      moments: [
        for (final minute in [0, 1])
          Moment(
            at: _start + 7 * 3600 + (40 + minute) * 60,
            title: 'Band tap',
            icon: LucideIcons.hand,
            eventId: 14,
          ),
        for (var index = 0; index < 30; index++) _workout(index),
      ],
    ))),
  ));
  await t.pumpAndSettle();
}

PilotTimelineChart _chart(WidgetTester t) =>
    t.widget<PilotTimelineChart>(find.byType(PilotTimelineChart));

void main() {
  setUpAll(loadFonts);

  // why: a row body should narrow the chart, reveal that list item and use its
  // colour. Reverting to reveal-only leaves the timeline at its full-day span.
  testWidgets('item tap zooms and subsequent scrolling follows the focused kind', (t) async {
    await _timeline(t);
    final item = find.byKey(const ValueKey('apk2-day-row:session:4'));
    final list = find.byKey(_list);
    await Scrollable.ensureVisible(t.element(item), alignment: .5);
    await t.pumpAndSettle();
    final initialItemTop = t.getTopLeft(item).dy;
    final homeSpan = _chart(t).controller.home.span;
    expect(_chart(t).controller.view.span, homeSpan);
    await takePilotShot(t, 'timeline-before-build');

    await t.tap(find.text('Session 5'));
    await t.pumpAndSettle();
    final selected = _chart(t);
    // The tap zooms to the item itself: a 15-minute session gets the 1-hour
    // minimum window, centred on it (was 70% of the day: 16.8 h).
    final w = _workout(4);
    final v = selected.controller.view;
    expect(v.span, closeTo(3600, 1));
    expect(v.start, lessThanOrEqualTo(w.at.toDouble()));
    expect(v.end, greaterThanOrEqualTo((w.until ?? w.at).toDouble()));
    expect(selected.controller.scrub, _workout(4).at);
    expect(selected.focusId, 'session:4');
    expect(selected.focusColor, C.purple);
    expect(initialItemTop - t.getTopLeft(item).dy, greaterThan(60));
    expect(t.getTopLeft(item).dy, closeTo(t.getTopLeft(list).dy, 1));
    final palette = P.of(t.element(item));
    expect(t.widget<Container>(item).color, palette.wash(C.purple));
    await takePilotShot(t, 'timeline-after-build');

    final drag = await t.startGesture(t.getCenter(list));
    await drag.moveBy(const Offset(0, -100));
    await t.pump();
    await drag.moveBy(const Offset(0, -120));
    await t.pump();
    final focused = _chart(t);
    expect(focused.focusId, isNot(equals('session:4')));
    final index = int.parse(focused.focusId!.split(':').last);
    final row = find.byKey(ValueKey('apk2-day-row:session:$index'));
    expect(t.widget<Container>(row).color, palette.wash(_workout(index).color!));
    expect(focused.focusColor, _workout(index).color);
    await drag.up();
    await t.pumpAndSettle();
  });

  // why: the chevron is a button and must not select or zoom the timeline.
  testWidgets('group button expands and the group body zooms', (t) async {
    await _timeline(t);
    final chevron = find.descendant(of: find.byType(MomentGroupRow),
        matching: find.byIcon(LucideIcons.chevronDown));
    final grouped = find.text('Band tap · 2 times');
    final controller = _chart(t).controller;
    expect(controller.zoomed, isFalse);
    await t.tap(chevron);
    await t.pumpAndSettle();
    expect(controller.zoomed, isFalse);
    expect(find.descendant(of: find.byType(MomentGroupRow),
        matching: find.byIcon(LucideIcons.chevronUp)), findsOneWidget);
    await t.tap(grouped);
    await t.pumpAndSettle();
    expect(controller.zoomed, isTrue);
    expect(controller.scrub, _start + 7 * 3600 + 40 * 60);
  });
}
