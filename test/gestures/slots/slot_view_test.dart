// The Gestures screen and gesture slots (RED): the overlap warning, the
// exclusive-mode refusal, and the per-slot Tell the time picker.
//
// New BandGesturesView API pinned (all optional, keyed by slot id):
//   overlaps             GestureSettings.overlaps(). In a slot's tab, under
//                        each action that is ON there and also on in other
//                        slots: "Also on Triple tap" (comma-separated other
//                        slots, GestureSlots.nameOf), key
//                        `gesture-overlap:<action id>`. Non-blocking: the
//                        switch stays live.
//   onSlotToggle         handles every switch, any tab, with the slot id. A
//                        refusal shows its reason (key `gesture-refusal`) in
//                        that tab and the switch is NOT flipped (it follows
//                        chosen / tapActions); an ok answer clears the message.
//   slotTimeBuzzModes    each tab's Tell the time picker shows its own slot's
//   onSlotTimeBuzzMode   mode (else timeBuzzMode), and a row tap reports
//                        (slot, mode) (else onTimeBuzzMode).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_slots.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
  DeviceAction.workoutToggle,
  DeviceAction.tellTime,
};

Finder _tab(int n) => find.byKey(ValueKey('gestures-tab:$n'));
Finder _overlap(DeviceAction a) => find.byKey(ValueKey('gesture-overlap:${a.id}'));
Finder _refusal = find.byKey(const ValueKey('gesture-refusal'));
Finder _row(String title) => find.widgetWithText(SwitchRow, title);
Finder _switch(String title) =>
    find.descendant(of: _row(title), matching: find.byType(Switch));
Finder _modeRow(TimeBuzzMode m) =>
    find.byKey(ValueKey('time-buzz-example:${m.name}'));
Finder _check(TimeBuzzMode m) =>
    find.descendant(of: _modeRow(m), matching: find.byIcon(LucideIcons.check));
Finder _now = find.byKey(const ValueKey('time-buzz-now'));

String _textOf(WidgetTester t, Finder f) => t.widget<Text>(f).data!;

Future<void> _pump(
  WidgetTester t, {
  Set<DeviceAction> chosen = const {},
  Map<int, Set<DeviceAction>> tapActions = const {},
  Map<DeviceAction, Set<String>> overlaps = const {},
  Future<ActionToggleResult> Function(String, DeviceAction, bool)? onSlotToggle,
  TimeBuzzMode mode = TimeBuzzMode.count,
  Map<String, TimeBuzzMode> slotModes = const {},
  ValueChanged<TimeBuzzMode>? onMode,
  void Function(String, TimeBuzzMode)? onSlotMode,
}) async {
  t.view.physicalSize = const Size(390 * 3, 3200 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: BandGesturesView(
      chosen: chosen,
      supported: _supported,
      tapActions: tapActions,
      overlaps: overlaps,
      onSlotToggle: onSlotToggle,
      timeBuzzMode: mode,
      slotTimeBuzzModes: slotModes,
      onTimeBuzzMode: onMode,
      onSlotTimeBuzzMode: onSlotMode,
      timeBuzzNow: () => DateTime(2026, 10, 7, 9, 45),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _select(WidgetTester t, int n) async {
  await t.ensureVisible(_tab(n));
  await t.tap(_tab(n));
  await t.pumpAndSettle();
}

Future<void> _flip(WidgetTester t, String title) async {
  await t.ensureVisible(_switch(title));
  await t.tap(_switch(title));
  await t.pumpAndSettle();
}

const _ecgReason =
    "ECG takes over the band while it records, so it can't share a gesture "
    'with other actions. Turn ECG off first.';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() => Prefs.setString(kGesturesTabPref, ''));

  group('the overlap warning', () {
    final both = {
      DeviceAction.markMoment: {'double', 'triple'},
    };

    testWidgets('each affected tab names the other slot', (t) async {
      await _pump(t,
          chosen: const {DeviceAction.markMoment},
          tapActions: const {3: {DeviceAction.markMoment}},
          overlaps: both);
      expect(_overlap(DeviceAction.markMoment), findsOneWidget);
      expect(_textOf(t, _overlap(DeviceAction.markMoment)),
          'Also on Triple tap');
      await _select(t, 3);
      expect(_overlap(DeviceAction.markMoment), findsOneWidget);
      expect(_textOf(t, _overlap(DeviceAction.markMoment)),
          'Also on Double tap');
    });

    testWidgets('it does not block: the switch stays live and the other '
        'rows have no warning', (t) async {
      final asked = <(String, DeviceAction, bool)>[];
      await _pump(t,
          chosen: const {DeviceAction.markMoment, DeviceAction.workoutToggle},
          tapActions: const {3: {DeviceAction.markMoment}},
          overlaps: both,
          onSlotToggle: (s, a, on) async {
            asked.add((s, a, on));
            return const ActionToggleOk();
          });
      expect(_overlap(DeviceAction.workoutToggle), findsNothing);
      expect(t.widget<Switch>(_switch('Mark a moment')).onChanged, isNotNull);
      await _flip(t, 'Mark a moment');
      expect(asked, [('double', DeviceAction.markMoment, false)]);
    });

    testWidgets('three slots: all the others are named', (t) async {
      await _pump(t,
          chosen: const {DeviceAction.markMoment},
          tapActions: const {
            3: {DeviceAction.markMoment},
            4: {DeviceAction.markMoment},
          },
          overlaps: {
            DeviceAction.markMoment: {'double', 'triple', 'quad'},
          });
      final text = _textOf(t, _overlap(DeviceAction.markMoment));
      expect(text, startsWith('Also on '));
      expect(text, contains('Triple tap'));
      expect(text, contains('Quadruple tap'));
      expect(text, isNot(contains('Double tap')));
    });

    testWidgets('a tab where the action is off shows no warning', (t) async {
      await _pump(t,
          chosen: const {DeviceAction.markMoment},
          tapActions: const {
            3: {DeviceAction.markMoment},
            4: {DeviceAction.workoutToggle},
          },
          overlaps: both);
      expect(_overlap(DeviceAction.markMoment), findsOneWidget,
          reason: 'it is drawn where the action is on');
      await _select(t, 4);
      expect(_overlap(DeviceAction.markMoment), findsNothing);
      expect(find.textContaining('Also on'), findsNothing);
    });

    testWidgets('no overlaps, no warning', (t) async {
      await _pump(t, chosen: const {DeviceAction.markMoment});
      expect(find.textContaining('Also on'), findsNothing);
    });
  });

  group('the exclusive-mode refusal', () {
    testWidgets('a refusal shows its reason and the switch does not flip',
        (t) async {
      final asked = <(String, DeviceAction, bool)>[];
      await _pump(t, onSlotToggle: (s, a, on) async {
        asked.add((s, a, on));
        return const ActionToggleRefusedExclusive(_ecgReason);
      });
      expect(_refusal, findsNothing);
      await _flip(t, 'Start / stop workout');
      expect(asked, [('double', DeviceAction.workoutToggle, true)]);
      expect(_refusal, findsOneWidget);
      expect(_textOf(t, _refusal), _ecgReason);
      expect(t.widget<Switch>(_switch('Start / stop workout')).value, isFalse);
    });

    testWidgets('the tab of a counted tap reports its own slot', (t) async {
      final asked = <(String, DeviceAction, bool)>[];
      await _pump(t, onSlotToggle: (s, a, on) async {
        asked.add((s, a, on));
        return const ActionToggleRefusedExclusive(_ecgReason);
      });
      await _select(t, 3);
      await _flip(t, 'Start / stop workout');
      expect(asked, [('triple', DeviceAction.workoutToggle, true)]);
      expect(_textOf(t, _refusal), _ecgReason);
    });

    testWidgets('an ok answer shows no message, and clears an earlier one',
        (t) async {
      final answers = <ActionToggleResult>[
        const ActionToggleRefusedExclusive(_ecgReason),
        const ActionToggleOk(),
      ];
      await _pump(t, onSlotToggle: (s, a, on) async => answers.removeAt(0));
      await _flip(t, 'Start / stop workout');
      expect(_refusal, findsOneWidget);
      await _flip(t, 'Mark a moment');
      expect(_refusal, findsNothing);
    });

    testWidgets('the message is the tab\'s own: it is gone in another tab',
        (t) async {
      await _pump(t,
          onSlotToggle: (s, a, on) async =>
              const ActionToggleRefusedExclusive(_ecgReason));
      await _flip(t, 'Start / stop workout');
      expect(_refusal, findsOneWidget);
      await _select(t, 3);
      expect(_refusal, findsNothing);
    });
  });

  group('the per-slot Tell the time picker', () {
    testWidgets('each tab checks its own slot\'s mode', (t) async {
      await _pump(t,
          chosen: const {DeviceAction.tellTime},
          tapActions: const {3: {DeviceAction.tellTime}},
          mode: TimeBuzzMode.count,
          slotModes: const {
            'double': TimeBuzzMode.binary,
            'triple': TimeBuzzMode.morse,
          });
      for (final m in TimeBuzzMode.values) {
        expect(_check(m), m == TimeBuzzMode.binary ? findsOneWidget : findsNothing,
            reason: 'double tab, $m');
      }
      await _select(t, 3);
      for (final m in TimeBuzzMode.values) {
        expect(_check(m), m == TimeBuzzMode.morse ? findsOneWidget : findsNothing,
            reason: 'triple tab, $m');
      }
    });

    testWidgets('the now row follows the slot\'s mode too', (t) async {
      await _pump(t,
          chosen: const {DeviceAction.tellTime},
          tapActions: const {3: {DeviceAction.tellTime}},
          slotModes: const {'triple': TimeBuzzMode.morse});
      final at = DateTime(2026, 10, 7, 9, 45);
      expect(find.descendant(
              of: _now,
              matching: find.textContaining(
                  renderTimeBuzz(encodeTime(at, TimeBuzzMode.count)))),
          findsOneWidget);
      await _select(t, 3);
      expect(find.descendant(
              of: _now,
              matching: find.textContaining(
                  renderTimeBuzz(encodeTime(at, TimeBuzzMode.morse)))),
          findsOneWidget);
    });

    testWidgets('a slot with no own mode shows the default', (t) async {
      await _pump(t,
          chosen: const {DeviceAction.tellTime},
          tapActions: const {3: {DeviceAction.tellTime}},
          mode: TimeBuzzMode.binary,
          slotModes: const {'double': TimeBuzzMode.morse});
      await _select(t, 3);
      expect(_check(TimeBuzzMode.binary), findsOneWidget);
      expect(_check(TimeBuzzMode.morse), findsNothing);
    });

    testWidgets('a tap on a row reports the slot and the mode, not the '
        'global callback', (t) async {
      final slotAsked = <(String, TimeBuzzMode)>[];
      final globalAsked = <TimeBuzzMode>[];
      await _pump(t,
          chosen: const {DeviceAction.tellTime},
          tapActions: const {3: {DeviceAction.tellTime}},
          onMode: globalAsked.add,
          onSlotMode: (s, m) => slotAsked.add((s, m)));
      await _select(t, 3);
      await t.ensureVisible(_modeRow(TimeBuzzMode.binary));
      await t.tap(_modeRow(TimeBuzzMode.binary));
      await t.pumpAndSettle();
      await _select(t, 2);
      await t.ensureVisible(_modeRow(TimeBuzzMode.morse));
      await t.tap(_modeRow(TimeBuzzMode.morse));
      await t.pumpAndSettle();
      expect(slotAsked, [
        ('triple', TimeBuzzMode.binary),
        ('double', TimeBuzzMode.morse),
      ]);
      expect(globalAsked, isEmpty);
    });
  });
}
