// "Tasker connection" off: the Tasker toggles and choices are still
// DRAWN but disabled and dimmed, with the hint "Turn on Tasker first". Same
// rule as test/settings_disable_not_hide_test.dart: a dependent row is never
// hidden behind its parent; only a row the platform cannot offer is omitted.
//
// Where the Tasker controls are:
//   * Gestures: the "Broadcast to Tasker" switch, in the tab of every gesture
//     (double, triple, quadruple, quintuple tap).
//   * Automation: the "Tasker connection" switch itself (key
//     `tasker-connection`, Android only) and, below it, the token's "Copy the
//     token" button.
// Android only: on iOS the phone does not offer the broadcast action and the
// Automation screen has no connection switch at all.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_slots.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

import '../../support/settings_sections.dart';

const _hint = 'Turn on Tasker first';
const _label = 'Broadcast to Tasker';

typedef _Toggle = (String slot, DeviceAction action, bool on);

Future<List<_Toggle>> _pumpGestures(
  WidgetTester t, {
  required bool taskerOn,
  Set<DeviceAction> supported = const {
    DeviceAction.none,
    DeviceAction.mediaPlayPause,
    DeviceAction.broadcastToTasker,
  },
  Set<DeviceAction> chosen = const {},
}) async {
  final calls = <_Toggle>[];
  await pumpTall(
    t,
    BandGesturesView(
      chosen: chosen,
      supported: supported,
      taskerOn: taskerOn,
      onSlotToggle: (slot, a, on) async {
        calls.add((slot, a, on));
        return const ActionToggleOk();
      },
    ),
  );
  return calls;
}

Finder _switchOf(Finder label) => find.descendant(
    of: find.ancestor(of: label, matching: find.byType(Row)).first,
    matching: find.byType(Switch));

void main() {
  group('Gestures: Broadcast to Tasker', () {
    for (var taps = 2; taps <= 5; taps++) {
      final name = GestureSlots.nameOf(GestureSlots.ofTaps(taps));
      testWidgets('connection off, $name: drawn, disabled, dimmed, with the '
          'hint', (t) async {
        final calls = await _pumpGestures(t, taskerOn: false);
        await openGesturesTab(t, taps);
        final label = find.text(_label);
        expect(label, findsOneWidget, reason: 'never hidden');
        expect(t.widget<Switch>(_switchOf(label)).onChanged, isNull);
        expect(isDimmed(t, label), isTrue);
        expect(find.text(_hint), findsOneWidget);
        await t.tap(label, warnIfMissed: false);
        await t.pumpAndSettle();
        expect(calls, isEmpty, reason: 'a disabled row does nothing');
      });
    }

    testWidgets('connection off: a mapping the wearer already made stays '
        'shown as on (the switch keeps its value)', (t) async {
      await _pumpGestures(t,
          taskerOn: false, chosen: const {DeviceAction.broadcastToTasker});
      final label = find.text(_label);
      expect(label, findsOneWidget);
      expect(t.widget<Switch>(_switchOf(label)).value, isTrue);
    });

    testWidgets('connection off leaves the other actions alone', (t) async {
      final calls = await _pumpGestures(t, taskerOn: false);
      final other = find.text('Play / pause music');
      expect(other, findsOneWidget);
      expect(isDimmed(t, other), isFalse);
      expect(t.widget<Switch>(_switchOf(other)).onChanged, isNotNull);
      await t.tap(_switchOf(other));
      await t.pumpAndSettle();
      expect(calls, [('double', DeviceAction.mediaPlayPause, true)]);
    });

    testWidgets('connection on: enabled, not dimmed, no hint, and the toggle '
        'reports the slot', (t) async {
      final calls = await _pumpGestures(t, taskerOn: true);
      await openGesturesTab(t, 3);
      final label = find.text(_label);
      expect(label, findsOneWidget);
      expect(isDimmed(t, label), isFalse);
      expect(find.text(_hint), findsNothing);
      await t.tap(_switchOf(label));
      await t.pumpAndSettle();
      expect(calls, [('triple', DeviceAction.broadcastToTasker, true)]);
    });

    testWidgets('platform gate: a phone that does not offer the broadcast '
        '(iOS) has no row, with the connection off too', (t) async {
      await _pumpGestures(t,
          taskerOn: false,
          supported: const {DeviceAction.none, DeviceAction.markMoment});
      expect(find.text(_label), findsNothing);
      expect(find.text(_hint), findsNothing);
    });
  });

  group('Automation: the Tasker connection', () {
    testWidgets('the connection switch is drawn and reports a change',
        (t) async {
      final changes = <bool>[];
      await pumpTall(
          t,
          AutomationSettingsView(
              token: 'tok123', taskerOn: false, onTaskerOn: changes.add));
      final row = find.byKey(const ValueKey('tasker-connection'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Tasker connection')),
          findsOneWidget);
      final sw = find.descendant(of: row, matching: find.byType(Switch));
      expect(t.widget<Switch>(sw).value, isFalse);
      expect(t.widget<Switch>(sw).onChanged, isNotNull,
          reason: 'the connection switch is the one control that is never '
              'disabled by the connection');
      await t.tap(sw);
      await t.pumpAndSettle();
      expect(changes, [true]);
    });

    testWidgets('on: the switch reads on, the token button works, no hint',
        (t) async {
      var copies = 0;
      await pumpTall(
          t,
          AutomationSettingsView(
              token: 'tok123',
              taskerOn: true,
              onTaskerOn: (_) {},
              onCopy: () => copies++));
      final sw = find.descendant(
          of: find.byKey(const ValueKey('tasker-connection')),
          matching: find.byType(Switch));
      expect(t.widget<Switch>(sw).value, isTrue);
      final copy = find.text('Copy the token');
      expect(copy, findsOneWidget);
      expect(isDimmed(t, copy), isFalse);
      expect(find.text(_hint), findsNothing);
      await t.tap(copy);
      expect(copies, 1);
    });

    testWidgets('off: the token and its Copy button are drawn, dimmed and '
        'inert, with the hint', (t) async {
      var copies = 0;
      await pumpTall(
          t,
          AutomationSettingsView(
              token: 'tok123',
              taskerOn: false,
              onTaskerOn: (_) {},
              onCopy: () => copies++));
      final copy = find.text('Copy the token');
      expect(copy, findsOneWidget, reason: 'never hidden');
      expect(isDimmed(t, copy), isTrue);
      expect(find.text(_hint), findsWidgets);
      await t.tap(copy, warnIfMissed: false);
      await t.pumpAndSettle();
      expect(copies, 0);
    });

    testWidgets('platform gate: on iOS there is no connection switch',
        (t) async {
      // Reset inside the test: the framework checks the variable before any
      // tearDown runs.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpTall(
            t, AutomationSettingsView(taskerOn: false, onTaskerOn: (_) {}));
        expect(find.byKey(const ValueKey('tasker-connection')), findsNothing);
        expect(find.text('Copy the token'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
