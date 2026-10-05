// "Count extra taps with": the per-band choice between ECG sensor touches and
// more double taps (developer mode only, since ECG touches are), the tab names
// that follow it, and the pause adjuster (on Gestures and in the Device lab).
// One mapping store serves both: the 3-tap slot is "Double tap + 1 ECG tap" for ECG and
// "2 double taps" for repeats. ECG is disabled and dimmed (never hidden) on a
// band without the sensor.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;

import 'support/settings_sections.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
  DeviceAction.torch,
};

final _forbidden =
    RegExp(r'one tap|single tap|\b1 tap', caseSensitive: false);

Finder _option(String id) => find.byKey(ValueKey('tap-method:$id'));

void main() {
  testWidgets('the choice is a section with both options', (t) async {
    await pumpTall(
        t,
        const BandGesturesView(
            chosen: {},
            supported: _supported,
            ecgSupported: true,
            devMode: true));
    expect(section('Count extra taps with'), findsOneWidget);
    expect(find.text('ECG sensor touches'), findsOneWidget);
    expect(find.text('More double taps'), findsOneWidget);
  });

  testWidgets('WHOOP MG: both enabled; double taps are the default choice',
      (t) async {
    await pumpTall(
        t,
        const BandGesturesView(
            chosen: {},
            supported: _supported,
            ecgSupported: true,
            devMode: true));
    expect(isDimmed(t, find.text('ECG sensor touches')), isFalse);
    expect(isDimmed(t, find.text('More double taps')), isFalse);
    expect(
        find.descendant(
            of: _option('repeat'), matching: find.byIcon(LucideIcons.check)),
        findsOneWidget);
    expect(
        find.descendant(
            of: _option('ecg'), matching: find.byIcon(LucideIcons.check)),
        findsNothing);
  });

  testWidgets('no ECG sensor: ECG is dimmed, inert and says why; double taps '
      'are chosen', (t) async {
    final picked = <TapCountMethod>[];
    await pumpTall(
        t,
        BandGesturesView(
          chosen: const {},
          supported: _supported,
          ecgSupported: false,
          devMode: true,
          onTapMethod: picked.add,
        ));
    expect(isDimmed(t, find.text('ECG sensor touches')), isTrue);
    expect(isDimmed(t, find.text('More double taps')), isFalse);
    expect(
        find.descendant(
            of: _option('repeat'), matching: find.byIcon(LucideIcons.check)),
        findsOneWidget);
    expect(find.text('This band has no ECG sensor'), findsWidgets);
    await t.tap(find.text('ECG sensor touches'), warnIfMissed: false);
    expect(picked, isEmpty);
  });

  testWidgets('tapping an option reports it', (t) async {
    final picked = <TapCountMethod>[];
    await pumpTall(
        t,
        BandGesturesView(
          chosen: const {},
          supported: _supported,
          ecgSupported: true,
          devMode: true,
          onTapMethod: picked.add,
        ));
    await t.tap(find.text('More double taps'));
    await t.tap(find.text('ECG sensor touches'));
    expect(picked, [TapCountMethod.repeat, TapCountMethod.ecg]);
  });

  group('tab names follow the method', () {
    testWidgets('ECG: Double tap / + 1 / + 2 / + 3 ECG taps',
        (t) async {
      await pumpTall(
          t,
          const BandGesturesView(
            chosen: {},
            supported: _supported,
            ecgSupported: true,
            devMode: true,
            tapMethod: TapCountMethod.ecg,
          ));
      for (final (n, name) in const [
        (2, 'Double tap'),
        (3, 'Double tap + 1 ECG tap'),
        (4, 'Double tap + 2 ECG taps'),
        (5, 'Double tap + 3 ECG taps'),
      ]) {
        await openGesturesTab(t, n);
        expect(gesturesTabName(t), name);
      }
      expect(find.textContaining('double taps'), findsWidgets,
          reason: 'only the option and the note, never as a tab name');
      expect(find.text('2 double taps'), findsNothing);
    });

    testWidgets('double taps: 2 / 3 / 4 double taps, no "N taps" names',
        (t) async {
      await pumpTall(
          t,
          const BandGesturesView(
            chosen: {},
            supported: _supported,
            ecgSupported: true,
            devMode: true,
            tapMethod: TapCountMethod.repeat,
          ));
      for (final (n, label) in const [
        (2, 'Double tap'),
        (3, '2 double taps'),
        (4, '3 double taps'),
        (5, '4 double taps'),
      ]) {
        await openGesturesTab(t, n);
        expect(gesturesTabName(t), label);
        expect(find.textContaining('Draft'), findsNothing);
        for (final k in [3, 4, 5]) {
          expect(find.text('$k taps'), findsNothing, reason: '$k taps');
        }
      }
    });

    testWidgets('double taps tabs are enabled on a band without ECG, and '
        'toggle their own count', (t) async {
      final toggled = <(int, DeviceAction, bool)>[];
      await pumpTall(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            ecgSupported: false,
            devMode: true,
            tapActions: const {
              3: {DeviceAction.logWater}
            },
            onTapToggle: (n, a, on) async => toggled.add((n, a, on)),
          ));
      await openGesturesTab(t, 3);
      final water = find.descendant(
          of: find.widgetWithText(SwitchRow, 'Log water'),
          matching: find.byType(Switch));
      expect(t.widget<Switch>(water).value, isTrue, reason: 'the shared store');
      await t.tap(water);
      await t.pumpAndSettle();
      expect(toggled, [(3, DeviceAction.logWater, false)]);
      expect(find.text('3 taps does'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('the pause between double taps', () {
    testWidgets('adjusts in 250 ms steps and stays inside 1000..5000',
        (t) async {
      final values = <int>[];
      await pumpTall(
          t,
          DeviceLabView(
            ecgSupported: false,
            repeatWindowMs: 1000,
            onRepeatWindowMs: values.add,
          ));
      expect(find.text('1000 ms'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('repeat-window:-')),
          warnIfMissed: false);
      expect(values, isEmpty, reason: '1000 ms is the minimum');
      await t.tap(find.byKey(const ValueKey('repeat-window:+')));
      expect(values, [1250]);
    });

    testWidgets('the maximum cannot be exceeded', (t) async {
      final values = <int>[];
      await pumpTall(
          t,
          DeviceLabView(
            ecgSupported: false,
            repeatWindowMs: 5000,
            onRepeatWindowMs: values.add,
          ));
      await t.tap(find.byKey(const ValueKey('repeat-window:+')),
          warnIfMissed: false);
      expect(values, isEmpty);
    });

    testWidgets('Gestures draws the same adjuster', (t) async {
      await pumpTall(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            ecgSupported: false,
            repeatWindowMs: 2500,
            onRepeatWindowMs: (_) {},
          ));
      expect(find.byKey(const ValueKey('repeat-window:+')), findsOneWidget);
      expect(find.text('Pause between double taps'), findsOneWidget);
    });
  });

  testWidgets('copy: says both methods, names no single tap', (t) async {
    expect(kExtendedGesturesNote, contains('WHOOP MG'));
    expect(kExtendedGesturesNote, contains('WHOOP 4.0 has no ECG sensor'));
    expect(kExtendedGesturesNote, contains('double taps'));
    expect(kExtendedGesturesNote.toLowerCase(), isNot(contains('draft')));
    for (final ecg in [true, false]) {
      await pumpTall(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            ecgSupported: ecg,
            devMode: true,
            repeatWindowMs: 2500,
            onRepeatWindowMs: (_) {},
          ));
      final texts = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '');
      for (final s in texts) {
        expect(_forbidden.hasMatch(s), isFalse, reason: 'text: "$s"');
      }
    }
  });
}
