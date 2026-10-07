// The Tell the time mode picker on the Gestures screen (BandGesturesView).
//
// New API pinned on BandGesturesView: `timeBuzzMode` (default count),
// `onTimeBuzzMode`, `timeBuzzNow` (a DateTime Function(); null is the real
// local time).
//
//   shown      only in the tab of a gesture that has DeviceAction.tellTime on:
//              `time-buzz-picker`. Not drawn when tellTime is off anywhere.
//   examples   one row per mode, keys `time-buzz-example:count|binary|morse`,
//              each showing "3:08 PM" and the glyphs of
//              renderTimeBuzz(encodeTime(3:08 PM, mode)): the SAME encoder the
//              band uses, so an example can never drift from what is played.
//   now        a `time-buzz-now` row: the time `timeBuzzNow` answers, as
//              "9:45 AM" style text, with its glyphs in the mode in force.
//   choice     the row of the mode in force has a check mark; a tap on a row
//              calls onTimeBuzzMode with that row's mode.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
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

final _example = DateTime(2026, 1, 1, 15, 8); // 3:08 PM, the fixed example

Finder _picker = find.byKey(const ValueKey('time-buzz-picker'));
Finder _row(TimeBuzzMode m) => find.byKey(ValueKey('time-buzz-example:${m.name}'));
Finder _now = find.byKey(const ValueKey('time-buzz-now'));
Finder _in(Finder row, String text) =>
    find.descendant(of: row, matching: find.textContaining(text));
Finder _tab(int n) => find.byKey(ValueKey('gestures-tab:$n'));

String _glyphs(TimeBuzzMode m, [DateTime? at]) =>
    renderTimeBuzz(encodeTime(at ?? _example, m));

Future<void> _pump(
  WidgetTester t, {
  Set<DeviceAction> chosen = const {DeviceAction.tellTime},
  Map<int, Set<DeviceAction>> tapActions = const {},
  TimeBuzzMode mode = TimeBuzzMode.count,
  ValueChanged<TimeBuzzMode>? onMode,
  DateTime Function()? now,
  double width = 390,
  double scale = 1,
}) async {
  t.view.physicalSize = Size(width * 3, 3200 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: BandGesturesView(
        chosen: chosen,
        supported: _supported,
        tapActions: tapActions,
        timeBuzzMode: mode,
        onTimeBuzzMode: onMode,
        timeBuzzNow: now ?? () => DateTime(2026, 10, 7, 9, 45),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

List<Object> _faults() {
  final out = <Object>[];
  while (true) {
    final e = TestWidgetsFlutterBinding.instance.takeException();
    if (e == null) break;
    out.add(e as Object);
  }
  return out;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() => Prefs.setString(kGesturesTabPref, ''));

  group('when it is shown', () {
    testWidgets('not when Tell the time is off', (t) async {
      await _pump(t, chosen: const {DeviceAction.markMoment});
      expect(_picker, findsNothing);
      for (final m in TimeBuzzMode.values) {
        expect(_row(m), findsNothing);
      }
      expect(_now, findsNothing);
    });

    testWidgets('not with nothing chosen', (t) async {
      await _pump(t, chosen: const {});
      expect(_picker, findsNothing);
    });

    testWidgets('when Tell the time is on for the double tap', (t) async {
      await _pump(t);
      expect(_picker, findsOneWidget);
    });

    testWidgets('Tell the time is an offered action row, and the picker is '
        'drawn once, not once per row', (t) async {
      await _pump(t);
      expect(find.widgetWithText(SwitchRow, 'Tell the time'), findsOneWidget);
      expect(_picker, findsOneWidget);
    });

    testWidgets('in the tab of the gesture that has it on, and only there',
        (t) async {
      await _pump(t,
          chosen: const {},
          tapActions: const {3: {DeviceAction.tellTime}});
      expect(_picker, findsNothing, reason: 'the double tap tab has none on');
      await t.ensureVisible(_tab(3));
      await t.tap(_tab(3));
      await t.pumpAndSettle();
      expect(_picker, findsOneWidget);
      await t.ensureVisible(_tab(2));
      await t.tap(_tab(2));
      await t.pumpAndSettle();
      expect(_picker, findsNothing);
    });
  });

  group('the three worked examples', () {
    testWidgets('one row per mode, each for 3:08 PM', (t) async {
      await _pump(t);
      for (final m in TimeBuzzMode.values) {
        expect(_row(m), findsOneWidget, reason: '$m');
        expect(_in(_row(m), '3:08 PM'), findsOneWidget, reason: '$m');
      }
    });

    testWidgets('each shows exactly the glyphs of the encoder the band uses',
        (t) async {
      await _pump(t);
      for (final m in TimeBuzzMode.values) {
        expect(_in(_row(m), _glyphs(m)), findsOneWidget,
            reason: '$m must show ${_glyphs(m)}');
      }
    });

    testWidgets('and those glyphs are the documented ones', (t) async {
      await _pump(t);
      expect(_in(_row(TimeBuzzMode.count), '▬ ▬ ▬ │ •'), findsOneWidget);
      expect(_in(_row(TimeBuzzMode.binary), '· · ▬ ▬ │ ▬ │ •'), findsOneWidget);
      expect(_in(_row(TimeBuzzMode.morse), '· · · ▬ ▬ │ · ▬ ▬ · │ •'),
          findsOneWidget);
    });

    testWidgets('the examples do not depend on the mode in force or on the '
        'time now', (t) async {
      await _pump(t,
          mode: TimeBuzzMode.morse, now: () => DateTime(2026, 5, 5, 23, 59));
      for (final m in TimeBuzzMode.values) {
        expect(_in(_row(m), _glyphs(m)), findsOneWidget, reason: '$m');
      }
    });
  });

  group('the now row', () {
    testWidgets('shows the injected time and its glyphs in the mode in force',
        (t) async {
      final at = DateTime(2026, 10, 7, 9, 45);
      await _pump(t, mode: TimeBuzzMode.count, now: () => at);
      expect(_now, findsOneWidget);
      expect(_in(_now, '9:45 AM'), findsOneWidget);
      // 9 short, a pause, 3 quarter clicks.
      expect(_in(_now, '· · · · · · · · · │ • • •'), findsOneWidget);
      expect(_in(_now, _glyphs(TimeBuzzMode.count, at)), findsOneWidget);
    });

    testWidgets('follows the mode', (t) async {
      final at = DateTime(2026, 10, 7, 9, 45);
      for (final m in TimeBuzzMode.values) {
        await _pump(t, mode: m, now: () => at);
        expect(_in(_now, _glyphs(m, at)), findsOneWidget, reason: '$m');
      }
    });

    testWidgets('12-hour text with the real clock hour: midnight is 12:05 AM, '
        'noon 12:00 PM', (t) async {
      await _pump(t, now: () => DateTime(2026, 10, 7, 0, 5));
      expect(_in(_now, '12:05 AM'), findsOneWidget);
      await _pump(t, now: () => DateTime(2026, 10, 7, 12, 0));
      expect(_in(_now, '12:00 PM'), findsOneWidget);
    });

    testWidgets('with no clock given it shows some time (the real one)',
        (t) async {
      t.view.physicalSize = const Size(390 * 3, 3200 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const BandGesturesView(
          chosen: {DeviceAction.tellTime},
          supported: _supported,
        ),
      ));
      await t.pumpAndSettle();
      expect(_now, findsOneWidget);
      expect(find.descendant(
          of: _now, matching: find.textContaining(RegExp(r'\d{1,2}:\d\d [AP]M'))),
          findsOneWidget);
    });
  });

  group('choosing', () {
    Finder check(TimeBuzzMode m) =>
        find.descendant(of: _row(m), matching: find.byIcon(LucideIcons.check));

    testWidgets('the mode in force has the check mark, the others do not',
        (t) async {
      for (final mode in TimeBuzzMode.values) {
        await _pump(t, mode: mode);
        for (final m in TimeBuzzMode.values) {
          expect(check(m), m == mode ? findsOneWidget : findsNothing,
              reason: 'mode $mode, row $m');
        }
      }
    });

    testWidgets('a tap on a row asks for that mode', (t) async {
      final asked = <TimeBuzzMode>[];
      await _pump(t, onMode: asked.add);
      await t.ensureVisible(_row(TimeBuzzMode.morse));
      await t.tap(_row(TimeBuzzMode.morse));
      await t.pumpAndSettle();
      await t.ensureVisible(_row(TimeBuzzMode.binary));
      await t.tap(_row(TimeBuzzMode.binary));
      await t.pumpAndSettle();
      expect(asked, [TimeBuzzMode.morse, TimeBuzzMode.binary]);
    });

    testWidgets('with no callback the rows are inert and nothing throws',
        (t) async {
      await _pump(t);
      await t.ensureVisible(_row(TimeBuzzMode.binary));
      await t.tap(_row(TimeBuzzMode.binary));
      await t.pumpAndSettle();
      expect(_faults(), isEmpty);
    });
  });

  group('layout', () {
    testWidgets('a narrow screen at a large text scale draws the longest '
        'example and the now row with no overflow', (t) async {
      await _pump(t,
          width: 320,
          scale: 2,
          mode: TimeBuzzMode.morse,
          now: () => DateTime(2026, 10, 7, 22, 53));
      expect(_picker, findsOneWidget);
      expect(_faults(), isEmpty);
    });
  });
}
