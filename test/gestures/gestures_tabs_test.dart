// The Gestures screen in sub-tabs (Oct 4): one tab per gesture, the settings
// that apply to all of them above the tabs, and no bottom sheet anywhere.
//
//   above the tabs   the intro, "Count extra taps with" (and, with extra taps,
//                    the note on what needs a WHOOP MG)
//   tabs             Double tap | x2 | x3 | x4 (More double taps)
//                    Double tap | +1 ECG | +2 ECG | +3 ECG (ECG touches)
//                    only the Double tap content, no tab row, without extra taps
//   in every tab     the gesture's full name and how to do it, the offered
//                    actions as switches, then the links at the bottom:
//                    Haptics, and the Device lab in developer mode directly
//                    below it. The replay-from-history switch is the plain
//                    double tap's alone (a counted tap is always live).
//
// The selected tab is remembered (Prefs `kGesturesTabPref`, the tap count).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart'
    show TapCountMethod;
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart'
    show SwitchRow, SettingsAccordion;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phase8/support/sections.dart' show sectionTitles;

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
  DeviceAction.workoutToggle,
  DeviceAction.torch,
  DeviceAction.ringPhone,
};

const _replayLabel = 'Also run for taps replayed from history';

Finder _tab(int n) => find.byKey(ValueKey('gestures-tab:$n'));
Finder _name = find.byKey(const ValueKey('gestures-tab-name'));
Finder _haptics = find.byKey(const ValueKey('gestures-open-haptics'));
Finder _lab = find.byKey(const ValueKey('gestures-open-device-lab'));
Finder _row(String title) => find.widgetWithText(SwitchRow, title);

String _nameText(WidgetTester t) => t.widget<Text>(_name).data!;

Future<void> _pump(
  WidgetTester t, {
  Set<DeviceAction> chosen = const {},
  Set<DeviceAction> replay = const {},
  bool ecg = false,
  TapCountMethod? method,
  bool extraTaps = true,
  bool devMode = false,
  Map<int, Set<DeviceAction>> tapActions = const {},
  void Function(DeviceAction, bool)? onToggle,
  Future<void> Function(int, DeviceAction, bool)? onTapToggle,
  void Function(DeviceAction, bool)? onReplay,
  ValueChanged<TapCountMethod>? onTapMethod,
  VoidCallback? onHaptics,
  VoidCallback? onDeviceLab,
  double width = 390,
  double scale = 1,
}) async {
  t.view.physicalSize = Size(width * 3, 2800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: BandGesturesView(
        chosen: chosen,
        supported: _supported,
        replay: replay,
        ecgSupported: ecg,
        tapMethod: method,
        extraTaps: extraTaps,
        devMode: devMode,
        tapActions: tapActions,
        onToggle: onToggle,
        onTapToggle: onTapToggle,
        onReplay: onReplay,
        onTapMethod: onTapMethod,
        onHaptics: onHaptics,
        onDeviceLab: onDeviceLab,
      ),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _select(WidgetTester t, int n) async {
  await t.ensureVisible(_tab(n));
  await t.tap(_tab(n));
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

SubTabs _tabs(WidgetTester t) => t.widget<SubTabs>(find.byType(SubTabs));

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() => Prefs.setString(kGesturesTabPref, ''));

  group('settings above the tabs', () {
    testWidgets('the intro and "Count extra taps with" sit above the tab row',
        (t) async {
      await _pump(t, ecg: true);
      final tabsTop = t.getTopLeft(find.byType(SubTabs)).dy;
      expect(find.text('Tap the band twice'), findsOneWidget);
      expect(t.getBottomLeft(find.text('Tap the band twice')).dy,
          lessThan(tabsTop));
      expect(sectionTitles(t), ['Count extra taps with']);
      for (final id in const ['ecg', 'repeat']) {
        final m = find.byKey(ValueKey('tap-method:$id'));
        expect(m, findsOneWidget, reason: id);
        expect(t.getBottomLeft(m).dy, lessThan(tabsTop), reason: id);
      }
      // The MG note is a setting-level explanation, not a tab's.
      expect(find.text('What needs a WHOOP MG'), findsOneWidget);
      expect(t.getBottomLeft(find.text('What needs a WHOOP MG')).dy,
          lessThan(tabsTop));
    });

    testWidgets('the old accordions and the tap-count picker are gone',
        (t) async {
      await _pump(t, ecg: true);
      expect(find.text('It does'), findsNothing);
      expect(find.text('Tap counts'), findsNothing);
      for (final s in sectionTitles(t)) {
        expect(s, isNot(anyOf('It does', 'Tap counts')));
      }
    });

    testWidgets('choosing a method reports it', (t) async {
      final picked = <TapCountMethod>[];
      await _pump(t, ecg: true, onTapMethod: picked.add);
      await t.tap(find.text('ECG sensor touches'));
      await t.tap(find.text('More double taps'));
      expect(picked, [TapCountMethod.ecg, TapCountMethod.repeat]);
    });

    testWidgets('without extra taps: no method choice, no MG note, no tab row, '
        'and the double tap content is still there', (t) async {
      await _pump(t, extraTaps: false, devMode: true);
      expect(find.byType(SubTabs), findsNothing);
      expect(sectionTitles(t), isEmpty);
      expect(find.text('What needs a WHOOP MG'), findsNothing);
      expect(_nameText(t), 'Double tap');
      expect(_row('Mark a moment'), findsOneWidget);
      expect(_haptics, findsOneWidget);
      expect(_lab, findsOneWidget);
    });
  });

  group('one tab per gesture', () {
    testWidgets('More double taps: Double tap, x2, x3, x4, named in full for '
        'a screen reader', (t) async {
      await _pump(t);
      final s = _tabs(t);
      expect(s.items, ['Double tap', '×2', '×3', '×4']);
      expect(s.index, 0);
      expect([for (final k in s.itemKeys!) (k as ValueKey).value],
          [for (var n = 2; n <= 5; n++) 'gestures-tab:$n']);
      expect(s.semanticLabels, [
        'Double tap, gesture',
        '2 double taps, gesture',
        '3 double taps, gesture',
        '4 double taps, gesture',
      ]);
      for (final (n, name) in const [
        (2, 'Double tap'),
        (3, '2 double taps'),
        (4, '3 double taps'),
        (5, '4 double taps'),
      ]) {
        await _select(t, n);
        expect(_nameText(t), name, reason: 'tab $n');
        expect(_tabs(t).index, n - 2);
      }
    });

    testWidgets('ECG touches: Double tap, +1, +2, +3 ECG, named in full',
        (t) async {
      await _pump(t, ecg: true, method: TapCountMethod.ecg);
      final s = _tabs(t);
      expect(s.items, ['Double tap', '+1 ECG', '+2 ECG', '+3 ECG']);
      expect(s.semanticLabels, [
        'Double tap, gesture',
        'Double tap + 1 ECG tap, gesture',
        'Double tap + 2 ECG taps, gesture',
        'Double tap + 3 ECG taps, gesture',
      ]);
      for (final (n, name) in const [
        (2, 'Double tap'),
        (3, 'Double tap + 1 ECG tap'),
        (4, 'Double tap + 2 ECG taps'),
        (5, 'Double tap + 3 ECG taps'),
      ]) {
        await _select(t, n);
        expect(_nameText(t), name, reason: 'tab $n');
      }
    });

    testWidgets('a band without the ECG sensor counts double taps even if '
        'ECG was asked for', (t) async {
      await _pump(t, ecg: false, method: TapCountMethod.ecg);
      expect(_tabs(t).items, ['Double tap', '×2', '×3', '×4']);
    });

    testWidgets('the count tabs are marked Draft inside their tabs; the '
        'double tap is not', (t) async {
      await _pump(t);
      expect(find.text('Draft'), findsNothing);
      for (final n in [3, 4, 5]) {
        await _select(t, n);
        expect(find.text('Draft'), findsOneWidget, reason: 'tab $n');
      }
      await _select(t, 2);
      expect(find.text('Draft'), findsNothing);
    });

    testWidgets('how to do it: the line under the name follows the method',
        (t) async {
      await _pump(t);
      final how = find.byKey(const ValueKey('gestures-tab-how'));
      expect(t.widget<Text>(how).data, contains('Tap the band twice'));
      await _select(t, 4);
      expect(t.widget<Text>(how).data, contains('Double tap 3 times in a row'));
    });

    testWidgets('the ECG how-to names the sensor touches', (t) async {
      await _pump(t, ecg: true, method: TapCountMethod.ecg);
      await _select(t, 4);
      final how =
          t.widget<Text>(find.byKey(const ValueKey('gestures-tab-how'))).data!;
      expect(how, contains('ECG sensor'));
      expect(how, contains('2 times'));
    });
  });

  group('every tab has the same layout', () {
    testWidgets('name, then the action switches, then the links, in that '
        'order', (t) async {
      await _pump(t, ecg: true, devMode: true, onHaptics: () {});
      for (var n = 2; n <= 5; n++) {
        await _select(t, n);
        final name = t.getTopLeft(_name).dy;
        final switches = [
          for (final a in const [
            'Mark a moment',
            'Start / stop workout',
            'Log water',
            'Ring my phone',
            'Flashlight',
          ])
            t.getTopLeft(_row(a)).dy,
        ];
        expect(switches, everyElement(greaterThan(name)), reason: 'tab $n');
        final lastSwitch = [
          for (final e in find.byType(SwitchRow).evaluate())
            t.getBottomLeft(find.byElementPredicate((x) => identical(x, e))).dy,
        ].reduce((a, b) => a > b ? a : b);
        expect(t.getTopLeft(_haptics).dy, greaterThan(lastSwitch),
            reason: 'tab $n: the links are at the bottom');
        expect(t.getTopLeft(_lab).dy, greaterThan(t.getTopLeft(_haptics).dy),
            reason: 'tab $n: Device lab under Haptics');
        // The same actions in every tab.
        for (final a in const [
          'Mark a moment',
          'Start / stop workout',
          'Log water',
          'Ring my phone',
          'Flashlight',
        ]) {
          expect(_row(a), findsOneWidget, reason: 'tab $n: $a');
        }
      }
    });

    testWidgets('the tab content has room under the tab row: the gap Health '
        'and Workout leave under theirs (S.x5), in every tab', (t) async {
      await _pump(t, ecg: true);
      for (var n = 2; n <= 5; n++) {
        await _select(t, n);
        final rowBottom = t.getBottomLeft(find.byType(SubTabs)).dy;
        final body = find.byKey(ValueKey('gestures-tab-body:$n'));
        final first = find.descendant(of: body, matching: find.byType(Surface));
        expect(t.getTopLeft(first.first).dy - rowBottom,
            greaterThanOrEqualTo(S.x5),
            reason: 'tab $n: the first card sits S.x5 under the tab row');
      }
    });

    testWidgets('the replay-from-history switch is the double tap tab\'s alone',
        (t) async {
      await _pump(t,
          chosen: {DeviceAction.markMoment},
          replay: {DeviceAction.markMoment},
          tapActions: {
            3: {DeviceAction.markMoment}
          });
      expect(_row(_replayLabel), findsOneWidget);
      // Directly under Mark a moment, as before.
      expect(t.getTopLeft(_row(_replayLabel)).dy,
          greaterThan(t.getTopLeft(_row('Mark a moment')).dy));
      expect(t.getTopLeft(_row(_replayLabel)).dy,
          lessThan(t.getTopLeft(_row('Start / stop workout')).dy));
      for (final n in [3, 4, 5]) {
        await _select(t, n);
        expect(_row(_replayLabel), findsNothing, reason: 'tab $n');
        expect(find.byType(SwitchRow), findsNWidgets(5), reason: 'tab $n');
      }
    });

    testWidgets('the "Nothing on the phone?" note stays, in each tab, above '
        'the links', (t) async {
      t.view.physicalSize = const Size(390 * 3, 2800 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const BandGesturesView(
          chosen: {},
          supported: {DeviceAction.none, DeviceAction.markMoment},
        ),
      ));
      await t.pumpAndSettle();
      for (var n = 2; n <= 5; n++) {
        await _select(t, n);
        final note = find.textContaining('could not ask the system');
        expect(note, findsOneWidget, reason: 'tab $n');
        expect(t.getTopLeft(note).dy,
            lessThan(t.getTopLeft(_haptics).dy), reason: 'tab $n');
      }
    });
  });

  group('persistence is unchanged', () {
    testWidgets('a switch in the double tap tab reports onToggle', (t) async {
      final calls = <(DeviceAction, bool)>[];
      await _pump(t, onToggle: (a, v) => calls.add((a, v)));
      await t.tap(
          find.descendant(of: _row('Log water'), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(calls, [(DeviceAction.logWater, true)]);
    });

    testWidgets('a switch in the x2 tab (count 3) reports onTapToggle(3, ...) '
        'and shows what is stored for that count', (t) async {
      final calls = <(int, DeviceAction, bool)>[];
      await _pump(t, tapActions: {
        3: {DeviceAction.torch},
        4: {DeviceAction.logWater},
      }, onToggle: (a, v) => fail('the plain double tap was not touched'),
          onTapToggle: (n, a, on) async => calls.add((n, a, on)));
      await _select(t, 3);
      Switch sw(String title) => t.widget<Switch>(
          find.descendant(of: _row(title), matching: find.byType(Switch)));
      expect(sw('Flashlight').value, isTrue);
      expect(sw('Log water').value, isFalse, reason: 'count 4 has water');
      await t.tap(find.descendant(
          of: _row('Log water'), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      await t.tap(find.descendant(
          of: _row('Flashlight'), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(calls, [
        (3, DeviceAction.logWater, true),
        (3, DeviceAction.torch, false),
      ]);
    });

    testWidgets('without onTapToggle the count switches are inert',
        (t) async {
      await _pump(t);
      await _select(t, 4);
      final sw = t.widget<Switch>(
          find.descendant(of: _row('Log water'), matching: find.byType(Switch)));
      expect(sw.onChanged, isNull);
    });

    testWidgets('the replay switch reports onReplay', (t) async {
      final calls = <(DeviceAction, bool)>[];
      await _pump(t,
          chosen: {DeviceAction.markMoment},
          replay: {DeviceAction.markMoment},
          onReplay: (a, v) => calls.add((a, v)));
      await t.tap(find.descendant(
          of: _row(_replayLabel), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(calls, [(DeviceAction.markMoment, false)]);
    });
  });

  group('no bottom sheet', () {
    testWidgets('no tab, no switch and no link opens one', (t) async {
      await _pump(t,
          devMode: true,
          onHaptics: () {},
          onDeviceLab: () {},
          onTapToggle: (n, a, on) async {});
      for (var n = 2; n <= 5; n++) {
        await _select(t, n);
        await t.tap(find.descendant(
            of: _row('Log water'), matching: find.byType(Switch)));
        await t.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing, reason: 'tab $n');
        expect(find.byType(CheckboxListTile), findsNothing, reason: 'tab $n');
        expect(find.text('View all gestures'), findsNothing);
      }
    });

    test('the source has no sheet, picker or view-all callback', () {
      final src = File('lib/ui2/profile/gestures.dart').readAsStringSync();
      for (final gone in const [
        'showModalBottomSheet',
        '_pickActions',
        'onViewAllGestures',
        "'Tap counts'",
        'gestures_tap_counts',
        'gestures_it_does',
      ]) {
        expect(src.contains(gone), isFalse, reason: gone);
      }
    });
  });

  group('links', () {
    testWidgets('Haptics opens from every tab', (t) async {
      var opened = 0;
      await _pump(t, onHaptics: () => opened++);
      for (var n = 2; n <= 5; n++) {
        await _select(t, n);
        await t.ensureVisible(_haptics);
        await t.tap(_haptics);
        await t.pump();
      }
      expect(opened, 4);
    });

    testWidgets('the Device lab link is there in developer mode only',
        (t) async {
      await _pump(t);
      for (var n = 2; n <= 5; n++) {
        await _select(t, n);
        expect(_lab, findsNothing, reason: 'tab $n');
      }
      expect(find.text('Device lab'), findsNothing);
      await t.pumpWidget(const SizedBox());
      var opened = 0;
      await _pump(t, devMode: true, onDeviceLab: () => opened++);
      for (var n = 2; n <= 5; n++) {
        await _select(t, n);
        expect(_lab, findsOneWidget, reason: 'tab $n');
        expect(
            find.descendant(of: _lab, matching: find.text('Device lab')),
            findsOneWidget);
        await t.ensureVisible(_lab);
        await t.tap(_lab);
        await t.pump();
      }
      expect(opened, 4);
    });

    testWidgets('Device lab is directly below Haptics: same width, a section '
        'gap apart, nothing between, no separator', (t) async {
      await _pump(t, devMode: true);
      for (var n = 2; n <= 5; n++) {
        await _select(t, n);
        final h = t.getRect(find
            .ancestor(of: _haptics, matching: find.byType(Surface))
            .first);
        final l = t
            .getRect(find.ancestor(of: _lab, matching: find.byType(Surface)).first);
        expect(l.left, h.left, reason: 'tab $n');
        expect(l.width, h.width, reason: 'tab $n');
        expect(l.top - h.bottom, inInclusiveRange(S.x2, S.x4),
            reason: 'tab $n: right under it');
        // No hairline in or between the link cards.
        for (final card in [_haptics, _lab]) {
          expect(
              find.descendant(
                  of: find.ancestor(of: card, matching: find.byType(Surface)).first,
                  matching: find.byType(Divider)),
              findsNothing,
              reason: 'tab $n');
        }
        for (final e in find.byType(Divider).evaluate()) {
          final d = t.getRect(find.byElementPredicate((x) => identical(x, e)));
          expect(d.top < h.top - 1, isTrue, reason: 'tab $n: a Divider at the links');
        }
      }
    });

    testWidgets('the links are set off from the switches by the section gap',
        (t) async {
      await _pump(t, devMode: true);
      final card = t.getRect(find
          .ancestor(of: _row('Flashlight'), matching: find.byType(Surface))
          .first);
      final h = t.getRect(
          find.ancestor(of: _haptics, matching: find.byType(Surface)).first);
      expect(h.top - card.bottom, greaterThanOrEqualTo(S.x3));
    });
  });

  group('tab memory', () {
    testWidgets('choosing a tab stores the count, and the next visit opens on '
        'it', (t) async {
      await _pump(t);
      await _select(t, 4);
      expect(Prefs.getString(kGesturesTabPref, ''), '4');
      await t.pumpWidget(const SizedBox());
      await _pump(t);
      expect(_tabs(t).index, 2);
      expect(_nameText(t), '3 double taps');
    });

    testWidgets('a first visit, or a stored value that means nothing, opens '
        'on the double tap', (t) async {
      await _pump(t);
      expect(_tabs(t).index, 0);
      expect(Prefs.getString(kGesturesTabPref, ''), '', reason: 'looking is '
          'not a write');
      await t.pumpWidget(const SizedBox());
      Prefs.setString(kGesturesTabPref, 'gone');
      await _pump(t);
      expect(_tabs(t).index, 0);
    });

    testWidgets('a remembered count tab is not offered without extra taps: '
        'the double tap shows, and the memory is left alone', (t) async {
      Prefs.setString(kGesturesTabPref, '5');
      await _pump(t, extraTaps: false);
      expect(_nameText(t), 'Double tap');
      expect(Prefs.getString(kGesturesTabPref, ''), '5');
    });
  });

  group('layout', () {
    for (final method in TapCountMethod.values) {
      testWidgets('360 pt at 1.3x text, every tab, developer mode on, '
          'everything on: no overflow (${method.name})', (t) async {
        await _pump(t,
            width: 360,
            scale: 1.3,
            ecg: true,
            method: method,
            devMode: true,
            chosen: {for (final a in _supported) a}..remove(DeviceAction.none),
            replay: {DeviceAction.markMoment},
            tapActions: {
              for (var n = 3; n <= 5; n++)
                n: {DeviceAction.markMoment, DeviceAction.torch},
            },
            onTapToggle: (n, a, on) async {},
            onHaptics: () {},
            onDeviceLab: () {});
        expect(_faults(), isEmpty);
        for (var n = 2; n <= 5; n++) {
          await _select(t, n);
          await t.ensureVisible(_lab);
          await t.pumpAndSettle();
          expect(_faults(), isEmpty, reason: '${method.name} tab $n');
          expect(find.byType(SwitchRow), findsWidgets);
        }
      });
    }

    testWidgets('the tab row scrolls rather than overflowing at 360 pt, 2x',
        (t) async {
      await _pump(t, width: 360, scale: 2, ecg: true, method: TapCountMethod.ecg);
      expect(_faults(), isEmpty);
      // At 2x the settings above push the row below the fold, and the last
      // tab is off the edge until the row is scrolled to it.
      await t.scrollUntilVisible(find.byType(SubTabs), 200,
          scrollable: find.byType(Scrollable).first);
      await t.drag(find.byType(SubTabs), const Offset(-400, 0));
      await t.pumpAndSettle();
      await _select(t, 5);
      expect(_faults(), isEmpty);
      expect(_tabs(t).index, 3);
    });
  });

  testWidgets('the only accordion above the tabs is the method choice',
      (t) async {
    await _pump(t, ecg: true);
    expect(find.byType(SettingsAccordion), findsOneWidget);
  });
}
