// "Count extra taps with": the per-band choice between ECG sensor touches and
// more double taps, the row labels that follow it, and the pause adjuster.
// One mapping store serves both: the 3-tap slot is "3 taps" for ECG and
// "2 double taps" for repeats. ECG is disabled and dimmed (never hidden) on a
// band without the sensor (8K).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';

import 'support/sections.dart';

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
            chosen: {}, supported: _supported, ecgSupported: true));
    expect(section('Count extra taps with'), findsOneWidget);
    expect(find.text('ECG sensor touches'), findsOneWidget);
    expect(find.text('More double taps'), findsOneWidget);
  });

  testWidgets('WHOOP MG: both enabled; ECG is the default choice', (t) async {
    await pumpTall(
        t,
        const BandGesturesView(
            chosen: {}, supported: _supported, ecgSupported: true));
    expect(isDimmed(t, find.text('ECG sensor touches')), isFalse);
    expect(isDimmed(t, find.text('More double taps')), isFalse);
    expect(
        find.descendant(
            of: _option('ecg'), matching: find.byIcon(LucideIcons.check)),
        findsOneWidget);
    expect(
        find.descendant(
            of: _option('repeat'), matching: find.byIcon(LucideIcons.check)),
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
          onTapMethod: picked.add,
        ));
    await t.tap(find.text('More double taps'));
    await t.tap(find.text('ECG sensor touches'));
    expect(picked, [TapCountMethod.repeat, TapCountMethod.ecg]);
  });

  group('row labels follow the method', () {
    testWidgets('ECG: 3 taps / 4 taps / 5 taps', (t) async {
      await pumpTall(
          t,
          const BandGesturesView(
              chosen: {}, supported: _supported, ecgSupported: true));
      for (final n in [2, 3, 4, 5]) {
        expect(find.text('$n taps'), findsOneWidget);
      }
      expect(find.textContaining('double taps'), findsWidgets,
          reason: 'only the option and the note, never as a row title');
      expect(find.text('2 double taps'), findsNothing);
    });

    testWidgets('double taps: 2 / 3 / 4 double taps, no "N taps" rows',
        (t) async {
      await pumpTall(
          t,
          const BandGesturesView(
            chosen: {},
            supported: _supported,
            ecgSupported: true,
            tapMethod: TapCountMethod.repeat,
          ));
      for (final label in ['2 double taps', '3 double taps', '4 double taps']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final n in [3, 4, 5]) {
        expect(find.text('$n taps'), findsNothing, reason: '$n taps');
      }
      expect(find.text('Double tap'), findsOneWidget);
      expect(find.textContaining('Draft'), findsNWidgets(3));
    });

    testWidgets('double taps rows are enabled on a band without ECG',
        (t) async {
      final opened = <int>[];
      await pumpTall(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            ecgSupported: false,
            tapActions: const {
              3: {DeviceAction.logWater}
            },
            onTapToggle: (n, a, on) async => opened.add(n),
          ));
      for (final label in ['2 double taps', '3 double taps', '4 double taps']) {
        expect(isDimmed(t, find.text(label)), isFalse, reason: label);
      }
      expect(find.text('1 on'), findsOneWidget, reason: 'the shared store');
      await t.tap(find.text('2 double taps'));
      await t.pumpAndSettle();
      expect(find.text('3 taps does'), findsNothing);
      expect(find.text('2 double taps does'), findsOneWidget);
    });
  });

  group('the pause between double taps', () {
    testWidgets('adjusts in 250 ms steps and stays inside 1000..5000',
        (t) async {
      final values = <int>[];
      await pumpTall(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
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
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            ecgSupported: false,
            repeatWindowMs: 5000,
            onRepeatWindowMs: values.add,
          ));
      await t.tap(find.byKey(const ValueKey('repeat-window:+')),
          warnIfMissed: false);
      expect(values, isEmpty);
    });
  });

  testWidgets('copy: says both methods, names no single tap', (t) async {
    expect(kExtendedGesturesNote, contains('WHOOP MG'));
    expect(kExtendedGesturesNote, contains('WHOOP 4.0 has no ECG sensor'));
    expect(kExtendedGesturesNote, contains('double taps'));
    expect(kExtendedGesturesNote, contains('3–5 tap rows are a draft'));
    for (final ecg in [true, false]) {
      await pumpTall(
          t,
          BandGesturesView(
            chosen: const {},
            supported: _supported,
            ecgSupported: ecg,
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
