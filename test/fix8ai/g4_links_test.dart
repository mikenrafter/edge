// 8AI G4 (red): the Gestures screen and the Alerts screen each link to Haptics.
//
// Spec: "Links: Gestures screen and Alerts screen each get a row linking to
// Haptics."
//
// ASSUMED API (both new parameters are passed through Function.apply with a
// plain-view fallback, so a missing name fails on the assertion):
//   * BandGesturesView (lib/ui2/profile/gestures.dart) takes
//     `VoidCallback? onHaptics`. It draws a SetRow keyed `gestures-open-haptics`
//     titled "Haptics" (chevron: it opens a screen), always, even with a null
//     callback (the row is then inert, not absent, like the other links). The
//     stateful BandGestures wires it to `goto(c, const HapticsSettings())`.
//   * NotificationSettingsView (lib/ui2/profile/settings.dart) takes
//     `VoidCallback? onOpenHaptics`, with a SetRow keyed `alerts-open-haptics`
//     titled "Haptics", drawn when the alerts are loaded. The stateful
//     NotificationSettings wires it to `goto(c, const HapticsSettings())`.
//   * The row is a link, not a switch and not an accordion section.
//
// Failure mode today: neither screen has the row, neither wrapper opens the
// Haptics screen.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

import '../phase8/support/dart_source.dart';
import '../phase8/support/sections.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
};

Widget _gestures({VoidCallback? onHaptics}) {
  try {
    return Function.apply(BandGesturesView.new, const [], {
      #chosen: <DeviceAction>{},
      #supported: _supported,
      #ecgSupported: true,
      #onHaptics: onHaptics,
    }) as Widget;
  } on NoSuchMethodError {
    return const BandGesturesView(chosen: {}, supported: _supported);
  }
}

Widget _alerts({VoidCallback? onOpenHaptics}) {
  try {
    return Function.apply(NotificationSettingsView.new, const [], {
      #onOpenHaptics: onOpenHaptics,
    }) as Widget;
  } on NoSuchMethodError {
    return const NotificationSettingsView();
  }
}

void main() {
  group('Gestures links to Haptics', () {
    testWidgets('a "Haptics" row, and tapping it calls onHaptics', (t) async {
      var opened = 0;
      await pumpTall(t, _gestures(onHaptics: () => opened++));
      final row = find.byKey(const ValueKey('gestures-open-haptics'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Haptics')),
          findsOneWidget);
      await t.tap(row);
      await t.pump();
      expect(opened, 1);
    });

    testWidgets('it is a link row: not inside the "It does" switches',
        (t) async {
      await pumpTall(t, _gestures(onHaptics: () {}));
      final row = find.byKey(const ValueKey('gestures-open-haptics'));
      expect(row, findsOneWidget);
      expect(
          find.descendant(of: row, matching: find.byType(Switch)), findsNothing);
      expect(find.descendant(of: section('It does'), matching: row),
          findsNothing);
    });

    test('the stateful screen opens the real Haptics screen', () {
      final src = File('lib/ui2/profile/gestures.dart').readAsStringSync();
      final body = codeOnly(bodyOf(src, 'class BandGestures extends'));
      expect(body, contains('onHaptics:'));
      expect(body, contains('HapticsSettings()'));
    });
  });

  group('Alerts links to Haptics', () {
    testWidgets('a "Haptics" row, and tapping it calls onOpenHaptics',
        (t) async {
      var opened = 0;
      await pumpTall(t, _alerts(onOpenHaptics: () => opened++));
      final row = find.byKey(const ValueKey('alerts-open-haptics'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Haptics')),
          findsOneWidget);
      await t.tap(row);
      await t.pump();
      expect(opened, 1);
    });

    testWidgets('it is a link row, not one of the alert switches', (t) async {
      await pumpTall(t, _alerts(onOpenHaptics: () {}));
      final row = find.byKey(const ValueKey('alerts-open-haptics'));
      expect(row, findsOneWidget);
      expect(
          find.descendant(of: row, matching: find.byType(Switch)), findsNothing);
    });

    test('the stateful screen opens the real Haptics screen', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final body =
          codeOnly(bodyOf(src, 'class _NotificationSettingsState extends'));
      expect(body, contains('onOpenHaptics:'));
      expect(body, contains('HapticsSettings()'));
    });
  });
}
