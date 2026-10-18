// The Alarm screen's day tabs, its two accordions and "Apply to full week".
//
//   * One SubTabs (the app's sub-tab component) above the accordions picks the
//     day; each tab keeps the `wake-day-<weekday>` key (0=Mon..6=Sun).
//   * "Alarm and wake" (id alarm_day): the selected day's on/off, wake time,
//     Natural Wake, expected sleep schedule, Gradual Wake, pattern, cadence and
//     the "Apply to full week" button.
//   * "Timeline and status" (id alarm_timeline): the selected day's timeline
//     and the armed state, next alarm and last wake decision.
//   * The two footnotes about the band's own buzz and measured vocabulary are
//     gone.
// Edits stay a draft: nothing is saved until Save.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/settings_sections.dart';

const _day = 'Alarm and wake';
const _timeline = 'Timeline and status';
const _names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

// Every day on, one distinct time per day (Mon 06:00 ... Sun 12:00), except Wed
// (2), which is off.
final _week = fillDefaultAlarmSchedule([
  for (var i = 0; i < 7; i++)
    AlarmScheduleEntry(
      weekday: i,
      hour: 6 + i,
      minute: 0,
      enabled: i != 2,
      gradualWindowMinutes: i == 4 ? 30 : 0,
    ),
]);

class _Harness {
  final saves = <List<AlarmScheduleEntry>>[];

  AlarmScreenView view({
    List<AlarmScheduleEntry>? schedule,
    bool connected = true,
    bool naturalWakeSupported = true,
    AlarmArmState state = AlarmArmState.none,
    DateTime? armedAt,
    List<String> trace = const [],
  }) => AlarmScreenView(
    connected: connected,
    schedule: schedule ?? _week,
    now: DateTime(2026, 10, 5, 22, 0),
    state: state,
    armedAt: armedAt,
    wakeTrace: trace,
    naturalWakeSupported: naturalWakeSupported,
    onSave: (e) async {
      saves.add(e);
      return const AlarmSaveOutcome(AlarmSaveStatus.sentToBand);
    },
  );
}

Finder _in(String accordion, Finder f) =>
    find.descendant(of: section(accordion), matching: f);

Finder _tab(int weekday) => find.byKey(ValueKey('wake-day-$weekday'));

Future<void> _select(WidgetTester t, int weekday) async {
  await t.tap(_tab(weekday));
  await t.pumpAndSettle();
}

Finder get _apply => find.byKey(const ValueKey('alarm-apply-week'));
bool _applyLive(WidgetTester t) =>
    t.widget<BigButton>(_apply).onTap != null && !isDimmed(t, _apply);

void main() {
  group('day tabs', () {
    testWidgets('one SubTabs, one tab per weekday, above every accordion', (
      t,
    ) async {
      await pumpTall(t, _Harness().view());
      expect(find.byType(SubTabs), findsOneWidget);
      for (var i = 0; i < 7; i++) {
        expect(_tab(i), findsOneWidget, reason: 'tab $i');
        expect(
          find.descendant(of: _tab(i), matching: find.text(_names[i])),
          findsOneWidget,
        );
      }
      expect(
        t.getTopLeft(find.byType(SubTabs)).dy,
        lessThan(t.getTopLeft(find.byType(SettingsAccordion).first).dy),
      );
      expect(find.byType(SubTabs), findsOneWidget);
    });

    testWidgets('the tabs say which day they edit, for a screen reader', (
      t,
    ) async {
      final handle = t.ensureSemantics();
      await pumpTall(t, _Harness().view());
      expect(
        find.bySemanticsLabel(RegExp('Edit wake settings for Tue')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('starts on the first day that is on', (t) async {
      await pumpTall(t, _Harness().view());
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 0);
    });

    testWidgets('starts on a later day when the earlier ones are off', (
      t,
    ) async {
      final sat = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 5, hour: 6, minute: 30, enabled: true),
      ]);
      await pumpTall(t, _Harness().view(schedule: sat));
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 5);
    });

    testWidgets('a day that is off is drawn off but still selectable', (
      t,
    ) async {
      await pumpTall(t, _Harness().view());
      expect(t.widget<SubTabs>(find.byType(SubTabs)).muted, {2});
      expect(t.widget<SubTabs>(find.byType(SubTabs)).disabled, isEmpty);
      await _select(t, 2);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 2);
    });

    for (var i = 0; i < 7; i++) {
      testWidgets('${_names[i]} drives both accordions', (t) async {
        await pumpTall(t, _Harness().view());
        await _select(t, i);
        final hhmm = '${(6 + i).toString().padLeft(2, '0')}:00';
        expect(t.widget<SubTabs>(find.byType(SubTabs)).index, i);
        // The day accordion shows this day's wake time.
        expect(_in(_day, find.text(hhmm)), findsWidgets);
        // The timeline accordion is for the same day and time.
        expect(
          _in(
            _timeline,
            find.text('TIMELINE FOR ${_names[i].toUpperCase()} $hhmm'),
          ),
          findsOneWidget,
        );
        // On/off follows the day.
        final on = i != 2;
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('alarm-day-enabled')),
            matching: find.text(on ? 'On' : 'Off'),
          ),
          findsOneWidget,
        );
      });
    }
  });

  group('two accordions', () {
    testWidgets('exactly "Alarm and wake" then "Timeline and status", under '
        'stable ids', (t) async {
      await pumpTall(t, _Harness().view());
      expect(sectionTitles(t), [_day, _timeline]);
      expect(accordions(t).map((a) => a.id), ['alarm_day', 'alarm_timeline']);
      await expectAllSectionsExpanded(t, 'Alarm screen');
    });

    testWidgets('the day accordion: on/off, wake time, Natural, expected '
        'sleep, Gradual, pattern, cadence, apply', (t) async {
      await pumpTall(t, _Harness().view());
      await _select(t, 4);
      for (final row in [
        'Alarm',
        'Wake time',
        'Natural Wake',
        'Expected sleep schedule',
        'Gradual Wake',
        'Gradual pattern',
        'Gradual cadence',
        'Apply to full week',
      ]) {
        expect(_in(_day, find.text(row)), findsOneWidget, reason: row);
        expect(_in(_timeline, find.text(row)), findsNothing, reason: row);
      }
      expect(_in(_day, find.textContaining('TIMELINE')), findsNothing);
      expect(_in(_day, find.text('Band alarm')), findsNothing);
    });

    testWidgets('Natural Wake and the sleep schedule leave when unsupported',
        (t) async {
      await pumpTall(t, _Harness().view(naturalWakeSupported: false));
      expect(_in(_day, find.text('Natural Wake')), findsNothing);
      expect(_in(_day, find.text('Expected sleep schedule')), findsNothing);
      expect(_in(_day, find.text('Gradual Wake')), findsOneWidget);
      expect(_in(_day, find.text('Apply to full week')), findsOneWidget);
    });

    testWidgets('the timeline accordion: the timeline, then the three status '
        'rows', (t) async {
      await pumpTall(
        t,
        _Harness().view(
          state: AlarmArmState.confirmed,
          armedAt: DateTime(2026, 10, 6, 7, 0),
          trace: const ['Band alarm at wake time: armed and confirmed'],
        ),
      );
      await _select(t, 4);
      expect(_in(_timeline, find.textContaining('TIMELINE FOR FRI')),
          findsOneWidget);
      expect(_in(_timeline, find.text('Band alarm')), findsOneWidget);
      expect(_in(_timeline, find.text('Gradual Wake buzzes')), findsOneWidget);
      for (final row in ['Armed state', 'Next alarm', 'Last wake decision']) {
        expect(_in(_timeline, find.text(row)), findsOneWidget, reason: row);
      }
      expect(_in(_timeline, find.text('Confirmed')), findsWidgets);
      expect(_in(_timeline, find.text('Tue 07:00')), findsWidgets);
      expect(_in(_timeline, find.textContaining('armed and confirmed')),
          findsOneWidget);
    });

    testWidgets('no trace: says nothing was recorded', (t) async {
      await pumpTall(t, _Harness().view());
      expect(_in(_timeline, find.textContaining('Nothing recorded')),
          findsOneWidget);
    });

    testWidgets('each accordion still folds to a one-line summary', (t) async {
      await pumpTall(t, _Harness().view());
      for (final title in [_day, _timeline]) {
        await t.tap(_in(title, find.text(title)).first);
        await t.pumpAndSettle();
        final lines = t
            .widgetList<Text>(_in(title, find.byType(Text)))
            .map((w) => w.data ?? '')
            .where((s) => s.trim().isNotEmpty && s != title)
            .toList();
        expect(lines, isNotEmpty, reason: '$title needs a summary');
      }
    });

    testWidgets('the on/off row edits the draft and dims the rest', (t) async {
      final h = _Harness();
      await pumpTall(t, h.view());
      await _select(t, 2);
      expect(isDimmed(t, _in(_day, find.text('Wake time'))), isTrue);
      await t.tap(find.byKey(const ValueKey('alarm-day-enabled')));
      await t.pumpAndSettle();
      expect(isDimmed(t, _in(_day, find.text('Wake time'))), isFalse);
      expect(t.widget<SubTabs>(find.byType(SubTabs)).muted, isEmpty);
      expect(h.saves, isEmpty);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(h.saves.single[2].enabled, isTrue);
    });
  });

  group('the footnotes are gone', () {
    testWidgets('neither sentence appears, connected or not', (t) async {
      for (final connected in [true, false]) {
        await pumpTall(t, _Harness().view(connected: connected));
        await _select(t, 0);
        expect(find.textContaining('own buzz'), findsNothing);
        expect(find.textContaining('measured vocabulary'), findsNothing);
      }
    });
  });

  group('Apply to full week', () {
    testWidgets('copies the day to all seven; dirty; Save sends the week', (
      t,
    ) async {
      final h = _Harness();
      await pumpTall(t, h.view());
      await _select(t, 4); // Fri 10:00, Gradual 30 min
      expect(_applyLive(t), isTrue);
      await t.tap(_apply);
      await t.pumpAndSettle();
      expect(
        find.text('Applied to every day. Save to send it to the band.'),
        findsOneWidget,
      );
      expect(h.saves, isEmpty, reason: 'a draft edit, not a save');
      expect(find.textContaining('Unsaved changes'), findsOneWidget);
      // The screen already shows the copy on another day.
      await _select(t, 0);
      expect(_in(_day, find.text('10:00')), findsWidgets);
      expect(_in(_day, find.text('30 min')), findsOneWidget);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final week = h.saves.single;
      expect(week, hasLength(7));
      for (var i = 0; i < 7; i++) {
        expect(week[i].weekday, i);
        expect([week[i].enabled, week[i].hour, week[i].minute], [true, 10, 0]);
        expect(week[i].gradualWindowMinutes, 30);
        expect(week[i].gradualPattern, week[4].gradualPattern);
        expect(week[i].gradualCadenceSec, week[4].gradualCadenceSec);
      }
    });

    testWidgets('an off day applies as off to the whole week', (t) async {
      final h = _Harness();
      await pumpTall(t, h.view());
      await _select(t, 2);
      await t.tap(_apply);
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(h.saves.single.every((e) => !e.enabled), isTrue);
    });

    testWidgets('disabled, dimmed and inert once every day already matches', (
      t,
    ) async {
      final h = _Harness();
      await pumpTall(t, h.view(schedule: fillDefaultAlarmSchedule(const [])));
      expect(_apply, findsOneWidget, reason: 'present, not hidden');
      expect(_applyLive(t), isFalse);
      await t.tap(_apply, warnIfMissed: false);
      await t.pumpAndSettle();
      expect(find.textContaining('Applied to every day'), findsNothing);
      expect(find.textContaining('Unsaved changes'), findsNothing);
    });

    testWidgets('goes dim after it is used, live again after any edit', (
      t,
    ) async {
      await pumpTall(t, _Harness().view());
      await t.tap(_apply);
      await t.pumpAndSettle();
      expect(_applyLive(t), isFalse);
      await _select(t, 3);
      await t.tap(find.byKey(const ValueKey('alarm-day-enabled')));
      await t.pumpAndSettle();
      expect(_applyLive(t), isTrue);
    });

    testWidgets('Cancel puts every day back', (t) async {
      final h = _Harness();
      await pumpTall(t, h.view());
      await _select(t, 4);
      await t.tap(_apply);
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.textContaining('Unsaved changes'), findsNothing);
      await _select(t, 0);
      expect(_in(_day, find.text('06:00')), findsWidgets);
    });
  });

  group('360 pt', () {
    Future<void> pump360(WidgetTester t, {double scale = 1}) async {
      t.view.physicalSize = const Size(360, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: _Harness().view(
            state: AlarmArmState.confirmed,
            armedAt: DateTime(2026, 10, 6, 7, 0),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    testWidgets('no overflow; the first tabs are on screen and every day is '
        'reachable', (t) async {
      await pump360(t);
      expect(t.takeException(), isNull);
      expect(t.getRect(_tab(0)).left, greaterThanOrEqualTo(0));
      expect(t.getRect(_tab(1)).right, lessThanOrEqualTo(360));
      await t.ensureVisible(_tab(6));
      await t.pumpAndSettle();
      await t.tap(_tab(6));
      await t.pumpAndSettle();
      expect(t.widget<SubTabs>(find.byType(SubTabs)).index, 6);
      expect(t.takeException(), isNull);
    });

    testWidgets('large text: no overflow either', (t) async {
      await pump360(t, scale: 2);
      expect(t.takeException(), isNull);
    });
  });
}
