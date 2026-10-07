// The snooze UI: Home's "Snoozed until HH:MM" card with "I'm up", and the alarm
// settings rows ("n double taps to dismiss — fewer is a snooze", with the live
// n). RED: SnoozeCard, snoozeCardFor, SnoozeSettingsRows and the alarm screen's
// rows are stubs.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/snooze_settings_rows.dart';
import 'package:openstrap_edge/ui2/screens/snooze_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/dart_source_lexical.dart';
import '../support/settings_sections.dart';

Widget _app(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

final _until = DateTime(2026, 10, 7, 6, 35);

/// Snooze switched ON (round 3, design A: it is opt-in; off, every row below
/// the switch is inert, pinned in snooze_r3_settings_ui_test.dart).
SnoozeSettings _on([Map<String, Object?> over = const {}]) =>
    SnoozeSettings.fromJson({'enabled': true, ...over});

void main() {
  group('SnoozeCard', () {
    late ValueNotifier<SnoozeStatus> status;
    late int imUps;

    setUp(() {
      status = ValueNotifier(SnoozeStatus.idle);
      imUps = 0;
    });
    tearDown(() => status.dispose());

    Widget card() => _app(SnoozeCard(
          status: status,
          onImUp: () async => imUps++,
        ));

    testWidgets('absent when there is no snooze', (t) async {
      await t.pumpWidget(card());
      expect(find.textContaining('Snoozed until'), findsNothing);
      expect(find.text("I'm up"), findsNothing);
      expect(find.byType(Surface), findsNothing);
    });

    testWidgets('a snooze shows "Snoozed until HH:MM" and "I\'m up", which '
        'dismisses', (t) async {
      status.value =
          SnoozeStatus(SnoozePhase.snoozed, until: _until, snoozeCount: 1);
      await t.pumpWidget(card());
      expect(find.text('Snoozed until 06:35'), findsOneWidget);
      expect(find.byKey(const ValueKey('snooze-im-up')), findsOneWidget);
      expect(find.text("I'm up"), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('snooze-im-up')));
      await t.pump();
      expect(imUps, 1);
    });

    testWidgets('the time is zero-padded 24 h', (t) async {
      status.value = SnoozeStatus(SnoozePhase.snoozed,
          until: DateTime(2026, 10, 7, 5, 5), snoozeCount: 2);
      await t.pumpWidget(card());
      expect(find.text('Snoozed until 05:05'), findsOneWidget);
    });

    testWidgets('while the re-alarm buzzes it still offers "I\'m up", with no '
        'stale "Snoozed until"', (t) async {
      status.value =
          SnoozeStatus(SnoozePhase.reAlarming, until: _until, snoozeCount: 1);
      await t.pumpWidget(card());
      expect(find.text("I'm up"), findsOneWidget);
      expect(find.textContaining('Snoozed until'), findsNothing);
    });

    testWidgets('the 4 s dismiss window is not a snooze: no card', (t) async {
      status.value = const SnoozeStatus(SnoozePhase.window);
      await t.pumpWidget(card());
      expect(find.text("I'm up"), findsNothing);
    });

    testWidgets('follows the status live, and is gone the moment it ends',
        (t) async {
      await t.pumpWidget(card());
      expect(find.text("I'm up"), findsNothing);
      status.value =
          SnoozeStatus(SnoozePhase.snoozed, until: _until, snoozeCount: 1);
      await t.pump();
      expect(find.text('Snoozed until 06:35'), findsOneWidget);
      status.value = SnoozeStatus.idle;
      await t.pump();
      expect(find.textContaining('Snoozed until'), findsNothing);
    });
  });

  group('Home insertion', () {
    testWidgets('snoozeCardFor is null with no AppState above (a golden)',
        (t) async {
      Widget? got = const SizedBox();
      await t.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          got = snoozeCardFor(c);
          return const SizedBox();
        }),
      ));
      expect(got, isNull);
    });

    test('both of Home\'s list sites insert it, next to the Natural Wake card',
        () {
      final code =
          codeOnly(File('lib/ui2/screens/home_screen.dart').readAsStringSync());
      expect('?snoozeCardFor('.allMatches(code), hasLength(2));
      expect('?_naturalWakeCard('.allMatches(code), hasLength(2));
    });
  });

  group('SnoozeSettingsRows', () {
    SnoozeSettings? changed;
    setUp(() => changed = null);

    Future<void> pump(WidgetTester t, SnoozeSettings s) => t.pumpWidget(_app(
        SnoozeSettingsRows(settings: s, onChanged: (v) => changed = v)));

    test('the copy says what n does, with the live n', () {
      expect(snoozeDismissCopy(2), '2 double taps to dismiss — fewer is a snooze');
      expect(snoozeDismissCopy(5), '5 double taps to dismiss — fewer is a snooze');
      expect(snoozeDismissCopy(1), '1 double tap to dismiss — fewer is a snooze');
    });

    testWidgets('shows the copy and the four settings with their values',
        (t) async {
      await pump(t, _on());
      expect(find.text('2 double taps to dismiss — fewer is a snooze'),
          findsOneWidget);
      for (final label in [
        'Double taps to dismiss',
        'Dismiss window',
        'Snooze for',
        'Stop escalating after',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('2 double taps'), findsOneWidget);
      expect(find.text('4 s'), findsOneWidget);
      expect(find.text('5 min'), findsOneWidget);
      expect(find.text('6 snoozes'), findsOneWidget);
    });

    testWidgets('the copy follows n live', (t) async {
      final n = ValueNotifier(_on());
      addTearDown(n.dispose);
      await t.pumpWidget(_app(ValueListenableBuilder<SnoozeSettings>(
        valueListenable: n,
        builder: (c, s, _) =>
            SnoozeSettingsRows(settings: s, onChanged: (v) => n.value = v),
      )));
      expect(find.textContaining('2 double taps to dismiss'), findsOneWidget);
      n.value = _on({'requiredTaps': 4});
      await t.pump();
      expect(find.text('4 double taps to dismiss — fewer is a snooze'),
          findsOneWidget);
      expect(find.textContaining('2 double taps to dismiss'), findsNothing);
    });

    testWidgets('n: offers 1 to 5 and applies the choice', (t) async {
      await pump(t, _on());
      await t.tap(find.text('Double taps to dismiss'));
      await t.pumpAndSettle();
      final opts = [
        for (final o in t.widgetList<SimpleDialogOption>(
            find.byType(SimpleDialogOption)))
          (o.child as Text).data!,
      ];
      expect(opts, [
        '1 double tap',
        '2 double taps',
        '3 double taps',
        '4 double taps',
        '5 double taps',
      ]);
      await t.tap(find.text('3 double taps').last);
      await t.pumpAndSettle();
      expect(changed, _on({'requiredTaps': 3}));
    });

    testWidgets('window: its own setting, every option in range', (t) async {
      await pump(t, _on());
      await t.tap(find.text('Dismiss window'));
      await t.pumpAndSettle();
      final opts = [
        for (final o in t.widgetList<SimpleDialogOption>(
            find.byType(SimpleDialogOption)))
          (o.child as Text).data!,
      ];
      expect(opts, containsAll(['2 s', '4 s', '6 s']));
      for (final o in opts) {
        final secs = int.parse(o.replaceAll(' s', ''));
        expect(secs * 1000, inInclusiveRange(kSnoozeWindowMsMin, kSnoozeWindowMsMax),
            reason: o);
      }
      await t.tap(find.text('6 s').last);
      await t.pumpAndSettle();
      expect(changed, _on({'windowMs': 6000}));
    });

    testWidgets('snooze length: 1 to 30 minutes', (t) async {
      await pump(t, _on());
      await t.tap(find.text('Snooze for'));
      await t.pumpAndSettle();
      final opts = [
        for (final o in t.widgetList<SimpleDialogOption>(
            find.byType(SimpleDialogOption)))
          (o.child as Text).data!,
      ];
      expect(opts, containsAll(['1 min', '5 min', '10 min', '15 min', '30 min']));
      for (final o in opts) {
        final m = int.parse(o.replaceAll(' min', ''));
        expect(m, inInclusiveRange(kSnoozeMinutesMin, kSnoozeMinutesMax),
            reason: o);
      }
      await t.tap(find.text('10 min').last);
      await t.pumpAndSettle();
      expect(changed, _on({'minutes': 10}));
    });

    testWidgets('escalation cap: a choice is applied', (t) async {
      await pump(t, _on());
      await t.tap(find.text('Stop escalating after'));
      await t.pumpAndSettle();
      await t.tap(find.text('3 snoozes').last);
      await t.pumpAndSettle();
      expect(changed, _on({'cap': 3}));
    });

    testWidgets('a choice keeps the other settings', (t) async {
      await pump(t, _on({'requiredTaps': 4, 'minutes': 9, 'cap': 3}));
      await t.tap(find.text('Dismiss window'));
      await t.pumpAndSettle();
      await t.tap(find.text('6 s').last);
      await t.pumpAndSettle();
      expect(changed,
          _on({'requiredTaps': 4, 'windowMs': 6000, 'minutes': 9, 'cap': 3}));
    });
  });

  group('the alarm screen', () {
    final week = fillDefaultAlarmSchedule(const []);

    testWidgets('shows the dismiss copy with the live n when given settings '
        'and applies a choice at once; without settings no rows', (t) async {
      SnoozeSettings? changed;
      await pumpTall(
          t,
          AlarmScreenView(
            connected: true,
            schedule: week,
            snoozeSettings: _on({'requiredTaps': 3}),
            onSnoozeSettings: (s) => changed = s,
          ));
      expect(find.text('3 double taps to dismiss — fewer is a snooze'),
          findsOneWidget);
      await t.tap(find.text('Snooze for'));
      await t.pumpAndSettle();
      await t.tap(find.text('15 min').last);
      await t.pumpAndSettle();
      expect(changed, _on({'requiredTaps': 3, 'minutes': 15}));

      await pumpTall(t, AlarmScreenView(connected: true, schedule: week));
      expect(find.textContaining('double taps to dismiss'), findsNothing);
      expect(find.text('Snooze for'), findsNothing);
    });
  });
}
