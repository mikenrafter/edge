// Device lab: a live band-event log and the ECG-on-double-tap switch.
// Includes the note on what the extended gestures say.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
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
          t,
          DeviceLabView(
              ecgSupported: true,
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

    testWidgets('three threshold adjusters, 50 ms steps, within range',
        (t) async {
      final changes = <EcgTapThresholds>[];
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: true,
            thresholds: EcgTapThresholds(startMs: 1000),
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
      expect(find.text('1000 ms'), findsOneWidget);
      expect(find.text('150 ms'), findsOneWidget);
      expect(find.text('750 ms'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('ecg-threshold:gap:+')));
      expect(changes.last, EcgTapThresholds(startMs: 1000, gapMs: 200));
      await t.tap(find.byKey(const ValueKey('ecg-threshold:confirm:-')));
      expect(changes.last, EcgTapThresholds(startMs: 1000, confirmMs: 700));
      final before = changes.length;
      await t.tap(find.byKey(const ValueKey('ecg-threshold:start:+')),
          warnIfMissed: false);
      expect(changes.length, before, reason: 'start is at its 1000 ms max');
      await t.tap(find.byKey(const ValueKey('ecg-threshold:start:-')));
      expect(changes.last, EcgTapThresholds(startMs: 950));
    });

    testWidgets('extra sensitive subsequent tap detection: a switch with its '
        'caveats, on by default', (t) async {
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
          EcgTapThresholds(gapMs: 250, extraSensitive: false),
          reason: 'the other thresholds are kept');
    });

    testWidgets('tolerant startup and the double-tap fallback: two '
        'switches next to the extra sensitive one, on by default',
        (t) async {
      final changes = <EcgTapThresholds>[];
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: true,
            thresholds: EcgTapThresholds(gapMs: 250),
            onThresholds: changes.add,
          ));
      expect(find.text('Tolerant startup'), findsOneWidget);
      expect(
          find.text('On: waits for the sensor to settle (about 2.5 s), so a '
              'finger placed during startup still counts. Off: decides a '
              'plain double tap from the first ECG packet, about 2 s sooner, '
              'but a finger placed after that packet is missed.'),
          findsOneWidget);
      expect(find.text('Fall back to the double-tap action'), findsOneWidget);
      expect(
          find.text('On: if the ECG cannot start or stops before any touch is '
              'counted, the double-tap action runs. Off: the ECG is tried '
              'once more instead. Either way the band gives one long buzz '
              'when the ECG fails.'),
          findsOneWidget);

      final tolerant =
          find.byKey(const ValueKey('ecg-threshold:tolerant-startup'));
      final fallback = find.byKey(const ValueKey('ecg-threshold:fallback'));
      final extra = find.byKey(const ValueKey('ecg-threshold:extra-sensitive'));
      for (final k in [tolerant, fallback, extra]) {
        await t.ensureVisible(k);
        expect(k, findsOneWidget);
      }
      expect(
          t
              .widget<Switch>(
                  find.descendant(of: tolerant, matching: find.byType(Switch)))
              .value,
          isTrue);
      expect(
          t
              .widget<Switch>(
                  find.descendant(of: fallback, matching: find.byType(Switch)))
              .value,
          isTrue);
      // Next to the extra sensitive switch: the same column, in the same block.
      expect(t.getTopLeft(tolerant).dx, t.getTopLeft(extra).dx);
      expect(t.getTopLeft(fallback).dx, t.getTopLeft(extra).dx);
    });

    testWidgets('toggling each switch saves it and keeps the other '
        'settings', (t) async {
      final changes = <EcgTapThresholds>[];
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: true,
            thresholds: EcgTapThresholds(gapMs: 250, extraSensitive: true),
            onThresholds: changes.add,
          ));
      final tolerant =
          find.byKey(const ValueKey('ecg-threshold:tolerant-startup'));
      await t.ensureVisible(tolerant);
      await t.tap(find.descendant(of: tolerant, matching: find.byType(Switch)));
      expect(
          changes.last,
          EcgTapThresholds(
              gapMs: 250, extraSensitive: true, tolerantStartup: false));
      final fallback = find.byKey(const ValueKey('ecg-threshold:fallback'));
      await t.ensureVisible(fallback);
      await t.tap(find.descendant(of: fallback, matching: find.byType(Switch)));
      expect(
          changes.last,
          EcgTapThresholds(
              gapMs: 250, extraSensitive: true, fallbackToDoubleTap: false));
    });

    testWidgets('the switches show the stored state and turn back on',
        (t) async {
      final changes = <EcgTapThresholds>[];
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: true,
            thresholds: EcgTapThresholds(
                tolerantStartup: false, fallbackToDoubleTap: false),
            onThresholds: changes.add,
          ));
      final tolerant =
          find.byKey(const ValueKey('ecg-threshold:tolerant-startup'));
      final fallback = find.byKey(const ValueKey('ecg-threshold:fallback'));
      await t.ensureVisible(tolerant);
      await t.ensureVisible(fallback);
      expect(
          t
              .widget<Switch>(
                  find.descendant(of: tolerant, matching: find.byType(Switch)))
              .value,
          isFalse);
      expect(
          t
              .widget<Switch>(
                  find.descendant(of: fallback, matching: find.byType(Switch)))
              .value,
          isFalse);
      await t.tap(find.descendant(of: tolerant, matching: find.byType(Switch)));
      expect(changes.last,
          EcgTapThresholds(tolerantStartup: true, fallbackToDoubleTap: false));
      await t.tap(find.descendant(of: fallback, matching: find.byType(Switch)));
      expect(changes.last,
          EcgTapThresholds(tolerantStartup: false, fallbackToDoubleTap: true));
    });

    testWidgets('not a WHOOP MG: the new switches are inert too',
        (t) async {
      final changes = <EcgTapThresholds>[];
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: false,
            thresholds: EcgTapThresholds(),
            onThresholds: changes.add,
          ));
      for (final k in const [
        'ecg-threshold:tolerant-startup',
        'ecg-threshold:fallback',
      ]) {
        final key = find.byKey(ValueKey(k));
        await t.ensureVisible(key);
        final sw = t.widget<Switch>(
            find.descendant(of: key, matching: find.byType(Switch)));
        expect(sw.onChanged, isNull, reason: k);
      }
      expect(changes, isEmpty);
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

    testWidgets('the note says what ECG and extended taps need', (t) async {
      await _pump(t, const DeviceLabView(ecgSupported: false));
      expect(find.textContaining('WHOOP MG'), findsWidgets);
      expect(find.textContaining('WHOOP 4.0 has no ECG sensor'), findsWidgets);
      expect(find.textContaining(RegExp('draft', caseSensitive: false)),
          findsNothing);
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
              ecgSupported: true,
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
              ecgSupported: true,
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
            ecgSupported: true,
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
          t, DeviceLabView(initialTab: LabTab.logs, ecgSupported: false, saveLog: fakeSaver));
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
          const DeviceLabView(
              ecgSupported: true,
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
