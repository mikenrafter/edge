// The Wake settings are live: Natural Wake window, Gradual Wake window
// / pattern / cadence, the exact timeline, and the upgrade explanation. Rows
// that do not apply are present and dimmed, never hidden. Everything here
// edits the draft; nothing reaches the DB or the band until Save.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

import 'support/settings_sections.dart';

// Mon (0) off; Tue (1) 07:00 on; Sat (5) 06:30 on with Gradual already on.
final _saved = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 1, hour: 7, minute: 0, enabled: true),
  AlarmScheduleEntry(
    weekday: 5,
    hour: 6,
    minute: 30,
    enabled: true,
    gradualWindowMinutes: 30,
    gradualCadenceSec: 120,
  ),
]);

class _Harness {
  final saves = <List<AlarmScheduleEntry>>[];
  final acks = <bool>[];
  int sleepScheduleTaps = 0;
  int timelineCalls = 0;

  AlarmScreenView view({
    bool hasExpectedSleep = true,
    bool upgradePending = false,
    List<String> trace = const [],
    AlarmArmState state = AlarmArmState.none,
    DateTime? armedAt,
    bool withTimeline = false,
  }) => AlarmScreenView(
    connected: true,
    schedule: _saved,
    now: DateTime(2026, 10, 5, 22, 0),
    state: state,
    armedAt: armedAt,
    hasExpectedSleep: hasExpectedSleep,
    upgradePending: upgradePending,
    wakeTrace: trace,
    onSave: (e) async {
      saves.add(e);
      return const AlarmSaveOutcome(AlarmSaveStatus.sentToBand);
    },
    onAcknowledgeUpgrade: (n) async => acks.add(n),
    onSetSleepSchedule: () async => sleepScheduleTaps++,
    timelineFor: withTimeline
        ? (at, e) {
            timelineCalls++;
            return WakeTimeline.compute(
              wakeAt: at,
              naturalMinutes: e.naturalWindowMinutes,
              gradualMinutes: e.gradualWindowMinutes,
            );
          }
        : null,
  );
}

// The Wake settings of the selected day, and its timeline and status.
Finder _wake(String text) =>
    find.descendant(of: section('Alarm and wake'), matching: find.text(text));

Finder _timeline(String text) => find.descendant(
  of: section('Timeline and status'),
  matching: find.text(text),
);

Future<void> _selectDay(WidgetTester t, int weekday) async {
  await t.tap(find.byKey(ValueKey('wake-day-$weekday')));
  await t.pumpAndSettle();
}

Future<void> _choose(WidgetTester t, String row, String option) async {
  await t.tap(_wake(row));
  await t.pumpAndSettle();
  await t.tap(
    find.descendant(of: find.byType(SimpleDialog), matching: find.text(option)),
  );
  await t.pumpAndSettle();
}

List<String> _options(WidgetTester t) => [
  for (final o in t.widgetList<SimpleDialogOption>(
    find.descendant(
      of: find.byType(SimpleDialog),
      matching: find.byType(SimpleDialogOption),
    ),
  ))
    (o.child as Text).data!,
];

void main() {
  group('Natural Wake', () {
    testWidgets('offers Off, then 15 to 120 in 15-minute steps', (t) async {
      await pumpTall(t, _Harness().view());
      await _selectDay(t, 1);
      await t.tap(_wake('Natural Wake'));
      await t.pumpAndSettle();
      expect(_options(t), [
        'Off',
        for (var m = 15; m <= 120; m += 15) '$m min before',
      ]);
    });

    testWidgets('a choice is a draft edit: shown at once, saved only on Save', (
      t,
    ) async {
      final h = _Harness();
      await pumpTall(t, h.view());
      await _selectDay(t, 1);
      await _choose(t, 'Natural Wake', '45 min before');
      expect(find.text('45 min'), findsOneWidget);
      expect(h.saves, isEmpty);
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(h.saves.single[1].naturalWindowMinutes, 45);
      expect(h.saves.single[1].hour, 7, reason: 'T never moves');
    });

    testWidgets('no expected sleep schedule: dimmed with the reason, and a '
        'way to set it', (t) async {
      final h = _Harness();
      await pumpTall(t, h.view(hasExpectedSleep: false));
      await _selectDay(t, 1);
      expect(_wake('Natural Wake'), findsOneWidget, reason: 'present');
      expect(isDimmed(t, _wake('Natural Wake')), isTrue);
      expect(
        find.text('Set your expected sleep schedule in Settings first'),
        findsOneWidget,
      );
      await t.tap(_wake('Natural Wake'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing, reason: 'inert');
      expect(isDimmed(t, _wake('Expected sleep schedule')), isFalse);
      await t.tap(_wake('Expected sleep schedule'));
      await t.pumpAndSettle();
      expect(h.sleepScheduleTaps, 1);
    });

    testWidgets('with a schedule the Natural row is live', (t) async {
      await pumpTall(t, _Harness().view());
      await _selectDay(t, 1);
      expect(isDimmed(t, _wake('Natural Wake')), isFalse);
    });

    testWidgets('a day that is off keeps the row, dimmed and inert', (t) async {
      await pumpTall(t, _Harness().view());
      await _selectDay(t, 0);
      expect(isDimmed(t, _wake('Natural Wake')), isTrue);
      expect(isDimmed(t, _wake('Gradual Wake')), isTrue);
      await t.tap(_wake('Natural Wake'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
    });
  });

  group('Gradual Wake', () {
    testWidgets('window offers Off and 15 to 120', (t) async {
      await pumpTall(t, _Harness().view());
      await _selectDay(t, 1);
      await t.tap(_wake('Gradual Wake'));
      await t.pumpAndSettle();
      expect(_options(t), [
        'Off',
        for (var m = 15; m <= 120; m += 15) '$m min before',
      ]);
    });

    testWidgets('pattern and cadence are dimmed until the window is on, then '
        'offer ramp / steady and 60 to 900 s', (t) async {
      final h = _Harness();
      await pumpTall(t, h.view());
      await _selectDay(t, 1);
      expect(isDimmed(t, _wake('Gradual pattern')), isTrue);
      expect(isDimmed(t, _wake('Gradual cadence')), isTrue);
      await _choose(t, 'Gradual Wake', '45 min before');
      expect(isDimmed(t, _wake('Gradual pattern')), isFalse);
      expect(isDimmed(t, _wake('Gradual cadence')), isFalse);

      await t.tap(_wake('Gradual pattern'));
      await t.pumpAndSettle();
      expect(_options(t), ['Ramp up', 'Steady']);
      await t.tap(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text('Steady'),
        ),
      );
      await t.pumpAndSettle();

      await t.tap(_wake('Gradual cadence'));
      await t.pumpAndSettle();
      expect(_options(t), [
        for (var s = 60; s <= 900; s += 60) '${s ~/ 60} min',
      ]);
      await t.tap(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text('5 min'),
        ),
      );
      await t.pumpAndSettle();

      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final e = h.saves.single[1];
      expect(e.gradualWindowMinutes, 45);
      expect(e.gradualPattern, GradualPattern.steady);
      expect(e.gradualCadenceSec, 300);
    });

    testWidgets('each day keeps its own Wake settings', (t) async {
      await pumpTall(t, _Harness().view());
      await _selectDay(t, 5);
      expect(
        find.text('30 min'),
        findsOneWidget,
        reason: "Saturday's saved Gradual window",
      );
      await _selectDay(t, 1);
      expect(find.text('30 min'), findsNothing);
    });
  });

  group('timeline', () {
    testWidgets('each part says whether it needs the phone', (t) async {
      final h = _Harness();
      await pumpTall(t, h.view(withTimeline: true));
      await _selectDay(t, 1);
      await _choose(t, 'Natural Wake', '60 min before');
      await _choose(t, 'Gradual Wake', '30 min before');
      expect(
        h.timelineCalls,
        greaterThan(0),
        reason: 'drawn by the wake controller, from the DRAFT day',
      );
      expect(
        _timeline('works without phone'),
        findsOneWidget,
        reason: 'only the band alarm at the wake time',
      );
      expect(
        _timeline('phone must be connected'),
        findsNWidgets(3),
        reason: 'collection, Natural window, Gradual steps',
      );
      expect(_timeline('Band alarm'), findsOneWidget);
      expect(_timeline('07:00'), findsWidgets);
    });

    testWidgets('with nothing on, the timeline is the band alarm alone', (
      t,
    ) async {
      await pumpTall(t, _Harness().view());
      await _selectDay(t, 1);
      expect(_timeline('works without phone'), findsOneWidget);
      expect(_timeline('phone must be connected'), findsNothing);
    });

    testWidgets('a day that is off keeps its timeline, dimmed', (t) async {
      await pumpTall(t, _Harness().view());
      await _selectDay(t, 0);
      expect(_timeline('Band alarm'), findsOneWidget);
      expect(isDimmed(t, _timeline('Band alarm')), isTrue);
    });
  });

  group('Smart Wake -> Natural Wake explanation', () {
    testWidgets('shown while pending; acknowledging calls through', (t) async {
      final h = _Harness();
      await pumpTall(t, h.view(upgradePending: true));
      await _selectDay(t, 1);
      expect(_wake('Smart Wake is now Natural Wake'), findsOneWidget);
      expect(
        isDimmed(t, _wake('Natural Wake')),
        isTrue,
        reason: 'nothing starts before the explanation is read',
      );
      await t.tap(_wake('Got it'));
      await t.pumpAndSettle();
      expect(h.acks, [true]);
    });

    testWidgets('the other answer switches Natural Wake off', (t) async {
      final h = _Harness();
      await pumpTall(t, h.view(upgradePending: true));
      await t.tap(_wake('Keep Natural Wake off'));
      await t.pumpAndSettle();
      expect(h.acks, [false]);
    });

    testWidgets('not shown once settled', (t) async {
      await pumpTall(t, _Harness().view());
      expect(find.text('Smart Wake is now Natural Wake'), findsNothing);
    });
  });

  group('Status', () {
    testWidgets('armed state, next alarm and the last wake decision', (
      t,
    ) async {
      await pumpTall(
        t,
        _Harness().view(
          state: AlarmArmState.confirmed,
          armedAt: DateTime(2026, 10, 6, 7, 0),
          trace: const [
            'Natural Wake: the REM estimate was not confident enough',
            'Band alarm at wake time: armed and confirmed',
          ],
        ),
      );
      final status = section('Timeline and status');
      expect(
        find.descendant(of: status, matching: find.text('Confirmed')),
        findsWidgets,
      );
      expect(
        find.descendant(of: status, matching: find.text('Tue 07:00')),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: status,
          matching: find.textContaining('not confident enough'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: status,
          matching: find.textContaining('armed and confirmed'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no trace: says nothing was recorded, invents nothing', (
      t,
    ) async {
      await pumpTall(t, _Harness().view());
      expect(
        find.descendant(
          of: section('Timeline and status'),
          matching: find.textContaining('Nothing recorded'),
        ),
        findsOneWidget,
      );
    });
  });
}
