// Device lab: a live band-event log and the ECG-on-double-tap switch.
// Includes the note on what the extended gestures say.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/settings_sections.dart' show isDimmed;

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

    testWidgets('log rows show event time, receipt time, delay, live/late',
        (t) async {
      final live = DeviceLabEntry.fromEvent(_tap());
      final late =
          DeviceLabEntry.fromEvent(_tap(late: const Duration(seconds: 40)));
      await _pump(
          t,
          DeviceLabView(

              initialTab: LabTab.logs,
              entries: [live, late]));
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

  });

  group('Save lab log file', () {
    final saved = <String>[];
    final names = <String>[];

    Future<bool> fakeSaver(String name, String text) async {
      names.add(name);
      saved.add(text);
      return true;
    }

    setUp(() {
      saved.clear();
      names.clear();
    });

    final lines = [
      '09:15:04.460 | tap +1210 ms | last +1200 ms | ECG stream command written.',
      '09:15:03.260 | tap +10 ms | last +10 ms | Double tap received.',
    ];

    testWidgets('the button is at the bottom, below every section', (t) async {
      await _pump(
          t,
          DeviceLabView(
              initialTab: LabTab.logs,

              steps: lines,
              entries: [DeviceLabEntry.fromEvent(_tap())],
              saveLog: fakeSaver));
      final button = find.byKey(const ValueKey('lab-copy-all'));
      expect(button, findsOneWidget);
      expect(find.text('Save lab log file'), findsOneWidget);
      expect(find.text('Copy all logs'), findsNothing);
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
              initialTab: LabTab.logs,

              saveLog: fakeSaver,
              steps: [for (var i = 0; i < 200; i++) 'line $i'])));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('lab-copy-all')).hitTestable(),
          findsOneWidget);
    });

    testWidgets('pressing it saves the whole log as a text file', (t) async {
      await _pump(
          t,
          DeviceLabView(
            initialTab: LabTab.logs,

            steps: lines,
            sessions: const [
              'ECG sensor touches | start 300 ms, gap 200 ms, confirm 200 ms | '
                  '3 taps | 6.4 s in total'
            ],
            entries: [DeviceLabEntry.fromEvent(_tap())],
            saveLog: fakeSaver,
          ));
      await t.tap(find.byKey(const ValueKey('lab-copy-all')));
      await t.pump();
      expect(saved, hasLength(1));
      expect(names.single,
          matches(RegExp(r'^openstrap-device-lab-log-\d{8}-\d{6}\.txt$')));
      final text = saved.single;
      expect(text, contains('OpenStrap Device lab log'));
      expect(text, contains('3 taps | 6.4 s in total'));
      expect(text, contains('Double tap received.'));
      expect(text, contains('ECG stream command written.'));
      expect(text, contains('Event 14 | Live'));
      // Oldest first.
      expect(text.indexOf('Double tap received.'),
          lessThan(text.indexOf('ECG stream command written.')));
    });

    testWidgets('and says it saved', (t) async {
      await _pump(
          t, DeviceLabView(initialTab: LabTab.logs,  saveLog: fakeSaver));
      await t.tap(find.byKey(const ValueKey('lab-copy-all')));
      await t.pump();
      expect(find.text('Log file saved'), findsOneWidget);
      expect(saved.single, contains('No log lines yet'));
    });
  });

  group('the double-tap method in the lab', () {
    testWidgets('a "Try repeated double taps" switch works on any band',
        (t) async {
      final values = <bool>[];
      await _pump(
          t,
          DeviceLabView(
               onRepeatLab: values.add, repeatLab: false));
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
          const DeviceLabView(

              initialTab: LabTab.logs,
              sessions: [
                'More double taps | window 2500 ms | 3 taps | 4.1 s in total'
              ]));
      expect(find.textContaining('window 2500 ms | 3 taps'), findsOneWidget);
    });
  });

  group('Settings > Developer links to the lab (not from Device detail)',
      () {
    final band = HealthSource(
      name: 'Synthetic band',
      kind: 'WHOOP 4',
      tier: SourceTier.wristOptical,
      icon: LucideIcons.watch,
      connected: true,
      isBand: true,
      family: 'gen4',
    );

    testWidgets('a "Device lab" row in Developer opens it, dev mode only',
        (t) async {
      var opened = 0;
      await _pump(t, MoreSettingsView(devMode: true, onDeviceLab: () => opened++));
      await t.tap(find.text('Device lab'));
      expect(opened, 1);
      await _pump(t, MoreSettingsView(onDeviceLab: () => opened++));
      expect(find.text('Device lab'), findsNothing);
    });

    testWidgets('the band page has no Device lab row any more', (t) async {
      await _pump(t, DeviceDetailView(band));
      expect(find.text('Device lab'), findsNothing);
    });
  });
}
