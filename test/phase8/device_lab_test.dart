// 8I — Device lab: a live band-event log and the ECG-on-double-tap switch.
// Includes the 8I note (what the extended gestures say).
// See test/phase8/CONTRACTS.md §8I.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _switchLabel = 'Toggle ECG recording on double tap';

final _strapAt = DateTime(2026, 10, 2, 9, 15, 3, 250);

StrapEvent _tap({Duration late = const Duration(milliseconds: 1200)}) {
  final utc = _strapAt.toUtc();
  return StrapEvent(
    eventId: 14,
    tsEpoch: utc.millisecondsSinceEpoch ~/ 1000,
    tsSubsec: (utc.millisecond * 32768) ~/ 1000,
    receivedAt: utc.add(late),
    hex: '',
    deviceId: 'band',
  );
}

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

Switch _switch(WidgetTester t) => t.widget<Switch>(find.descendant(
    of: find.ancestor(of: find.text(_switchLabel), matching: find.byType(Row))
        .first,
    matching: find.byType(Switch)));

void main() {
  group('DeviceLabEntry', () {
    test('a live tap carries both clocks, the delay and what ran', () {
      final e = _tap();
      final entry = DeviceLabEntry.fromEvent(e, outcomes: const [
        GestureOutcome(
            action: DeviceAction.markMoment,
            status: GestureStatus.ran,
            timeSource: EventTimeSource.strap),
        GestureOutcome(
            action: DeviceAction.torch,
            status: GestureStatus.failed,
            timeSource: EventTimeSource.strap),
      ]);
      expect(entry.eventId, 14);
      expect(entry.eventTime, e.effectiveTime);
      expect(entry.receivedAt, e.receivedAt);
      expect(entry.delay, e.receivedAt.difference(e.effectiveTime));
      expect(entry.live, isTrue);
      expect(entry.actions, ['mark_moment']);
    });

    test('a tap from flash is late', () {
      final entry = DeviceLabEntry.fromEvent(_tap(late: const Duration(hours: 2)));
      expect(entry.live, isFalse);
      expect(entry.delay, const Duration(hours: 2));
    });

    test('formats: clock to the millisecond, delay to a tenth of a second', () {
      expect(labClock(DateTime(2026, 10, 2, 7, 5, 3, 42)), '07:05:03.042');
      final entry = DeviceLabEntry.fromEvent(_tap());
      expect(entry.delayLabel, '1.2 s');
    });
  });

  group('DeviceLabView', () {
    testWidgets('not a WHOOP MG: switch shown, disabled, with the reason',
        (t) async {
      var changed = 0;
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: false,
            onEcgOnDoubleTap: (_) => changed++,
          ));
      expect(find.text(_switchLabel), findsOneWidget);
      expect(find.text('This band has no ECG sensor'), findsOneWidget);
      expect(_switch(t).onChanged, isNull);
      await t.tap(find.text(_switchLabel), warnIfMissed: false);
      expect(changed, 0);
    });

    testWidgets('WHOOP MG: switch enabled, off by default, toggles',
        (t) async {
      final values = <bool>[];
      await _pump(
          t, DeviceLabView(ecgSupported: true, onEcgOnDoubleTap: values.add));
      expect(_switch(t).value, isFalse);
      expect(_switch(t).onChanged, isNotNull);
      expect(find.text('This band has no ECG sensor'), findsNothing);
      await t.tap(find.byType(Switch).first);
      expect(values, [true]);
    });

    testWidgets('log rows show event time, receipt time, delay, live/late',
        (t) async {
      final live = DeviceLabEntry.fromEvent(_tap());
      final late =
          DeviceLabEntry.fromEvent(_tap(late: const Duration(seconds: 40)));
      await _pump(
          t, DeviceLabView(ecgSupported: true, entries: [live, late]));
      for (final e in [live, late]) {
        expect(find.textContaining(labClock(e.eventTime.toLocal())),
            findsWidgets);
        expect(find.textContaining(labClock(e.receivedAt.toLocal())),
            findsWidgets);
      }
      expect(find.textContaining(live.delayLabel), findsWidgets);
      expect(find.textContaining('Live'), findsWidgets);
      expect(find.textContaining('Late'), findsWidgets);
    });

    testWidgets('three threshold adjusters, 50 ms steps, within range',
        (t) async {
      final changes = <EcgTapThresholds>[];
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: true,
            thresholds: EcgTapThresholds(startMs: 1100),
            onThresholds: changes.add,
          ));
      for (final label in [
        'Start threshold',
        'Gap threshold',
        'Confirmation threshold',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // The gap threshold sets BOTH debounces; its caption has to say so.
      expect(
          find.textContaining(RegExp(
              r'touch.*let go|let go.*touch',
              caseSensitive: false)),
          findsWidgets);
      expect(find.text('1100 ms'), findsOneWidget);
      expect(find.text('200 ms'), findsNWidgets(2));

      await t.tap(find.byKey(const ValueKey('ecg-threshold:gap:+')));
      expect(changes.last, EcgTapThresholds(startMs: 1100, gapMs: 250));
      await t.tap(find.byKey(const ValueKey('ecg-threshold:confirm:-')));
      expect(changes.last, EcgTapThresholds(startMs: 1100, confirmMs: 150));
      final before = changes.length;
      await t.tap(find.byKey(const ValueKey('ecg-threshold:start:+')),
          warnIfMissed: false);
      expect(changes.length, before, reason: 'start is at its 1100 ms max');
      await t.tap(find.byKey(const ValueKey('ecg-threshold:start:-')));
      expect(changes.last, EcgTapThresholds(startMs: 1050));
    });

    testWidgets('not a WHOOP MG: the adjusters are shown but inert',
        (t) async {
      final changes = <EcgTapThresholds>[];
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: false,
            thresholds: EcgTapThresholds(),
            onThresholds: changes.add,
          ));
      expect(find.text('Start threshold'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ecg-threshold:start:+')),
          warnIfMissed: false);
      expect(changes, isEmpty);
    });

    testWidgets('8I note: says what ECG and extended taps need', (t) async {
      await _pump(t, const DeviceLabView(ecgSupported: false));
      expect(find.textContaining('WHOOP MG'), findsWidgets);
      expect(find.textContaining('WHOOP 4.0 has no ECG sensor'), findsWidgets);
      expect(
          find.textContaining(
              RegExp(r'3–5 tap rows are a draft', caseSensitive: false)),
          findsWidgets);
    });
  });

  group('Device detail links to the lab', () {
    final band = HealthSource(
      name: 'Synthetic band',
      kind: 'WHOOP 4',
      tier: SourceTier.wristOptical,
      icon: LucideIcons.watch,
      connected: true,
      isBand: true,
      family: 'gen4',
    );

    testWidgets('a "Device lab" row on the band opens it', (t) async {
      var opened = 0;
      await _pump(t, DeviceDetailView(band, onDeviceLab: () => opened++));
      await t.tap(find.text('Device lab'));
      expect(opened, 1);
    });
  });
}
