// 8I — Device lab: a live band-event log and the ECG-on-double-tap switch.
// Includes the 8I note (what the extended gestures say).
// See test/phase8/CONTRACTS.md §8I.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/sections.dart' show isDimmed;

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

    testWidgets('extra sensitive subsequent tap detection: a switch with its '
        'caveats, off by default', (t) async {
      final changes = <EcgTapThresholds>[];
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: true,
            thresholds: EcgTapThresholds(gapMs: 250),
            onThresholds: changes.add,
          ));
      expect(find.text('Extra sensitive subsequent tap detection'),
          findsOneWidget);
      // The caveat: what each setting merges or misses.
      expect(find.textContaining('same second counts as one tap'),
          findsOneWidget);
      expect(find.textContaining('missed, counted late, or split in two'),
          findsOneWidget);
      final key = find.byKey(const ValueKey('ecg-threshold:extra-sensitive'));
      await t.ensureVisible(key);
      await t.tap(find.descendant(of: key, matching: find.byType(Switch)));
      expect(changes.last,
          EcgTapThresholds(gapMs: 250, extraSensitive: true),
          reason: 'the other thresholds are kept');
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

  group('Copy all logs', () {
    final copied = <String>[];

    void mockClipboard(WidgetTester t) {
      copied.clear();
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
    }

    final lines = [
      '09:15:04.460 | tap +1210 ms | last +1200 ms | ECG stream command written.',
      '09:15:03.260 | tap +10 ms | last +10 ms | Double tap received.',
    ];

    testWidgets('the button is at the bottom, below every section', (t) async {
      await _pump(
          t,
          DeviceLabView(
              ecgSupported: true,
              steps: lines,
              entries: [DeviceLabEntry.fromEvent(_tap())]));
      final button = find.byKey(const ValueKey('lab-copy-all'));
      expect(button, findsOneWidget);
      expect(find.text('Copy all logs'), findsOneWidget);
      final y = t.getTopLeft(button).dy;
      for (final heading in ['Band events', 'Step by step']) {
        expect(y, greaterThan(t.getTopLeft(find.text(heading)).dy),
            reason: 'below $heading');
      }
      final screen = t.getSize(find.byType(Scaffold)).height;
      expect(y, greaterThan(screen * 0.8), reason: 'near the bottom edge');
    });

    testWidgets('it stays reachable when the log is long', (t) async {
      t.view.physicalSize = const Size(1170, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: DeviceLabView(
              ecgSupported: true,
              steps: [for (var i = 0; i < 200; i++) 'line $i'])));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('lab-copy-all')).hitTestable(),
          findsOneWidget);
    });

    testWidgets('pressing it puts the whole log on the clipboard as text',
        (t) async {
      mockClipboard(t);
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: true,
            steps: lines,
            sessions: const [
              'ECG sensor touches | start 300 ms, gap 200 ms, confirm 200 ms | '
                  '3 taps | 6.4 s in total'
            ],
            entries: [DeviceLabEntry.fromEvent(_tap())],
          ));
      await t.tap(find.byKey(const ValueKey('lab-copy-all')));
      await t.pump();
      expect(copied, hasLength(1));
      final text = copied.single;
      expect(text, contains('OpenStrap Device lab log'));
      expect(text, contains('3 taps | 6.4 s in total'));
      expect(text, contains('Double tap received.'));
      expect(text, contains('ECG stream command written.'));
      expect(text, contains('Event 14 | Live'));
      // Oldest first.
      expect(text.indexOf('Double tap received.'),
          lessThan(text.indexOf('ECG stream command written.')));
    });

    testWidgets('and says it copied', (t) async {
      mockClipboard(t);
      await _pump(t, const DeviceLabView(ecgSupported: false));
      await t.tap(find.byKey(const ValueKey('lab-copy-all')));
      await t.pump();
      expect(find.text('Log copied'), findsOneWidget);
      expect(copied.single, contains('No log lines yet'));
    });
  });

  group('the double-tap method in the lab', () {
    testWidgets('a "Try repeated double taps" switch works on any band',
        (t) async {
      final values = <bool>[];
      await _pump(
          t,
          DeviceLabView(
              ecgSupported: false, onRepeatLab: values.add, repeatLab: false));
      expect(find.text('Try repeated double taps'), findsOneWidget);
      expect(isDimmed(t, find.text('Try repeated double taps')), isFalse);
      await t.tap(find.byType(Switch).last);
      expect(values, [true]);
    });

    testWidgets('the pause between double taps adjusts in 250 ms steps',
        (t) async {
      final values = <int>[];
      await _pump(
          t,
          DeviceLabView(
              ecgSupported: false,
              repeatWindowMs: 2500,
              onRepeatWindowMs: values.add));
      expect(find.text('2500 ms'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('repeat-window:+')));
      await t.tap(find.byKey(const ValueKey('repeat-window:-')));
      expect(values, [2750, 2250]);
    });

    testWidgets('session summaries are shown', (t) async {
      await _pump(
          t,
          const DeviceLabView(ecgSupported: true, sessions: [
            'More double taps | window 2500 ms | 3 taps | 4.1 s in total'
          ]));
      expect(find.textContaining('window 2500 ms | 3 taps'), findsOneWidget);
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
