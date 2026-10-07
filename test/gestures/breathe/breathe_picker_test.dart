// The Breathing exercise picker in the Gestures tab (RED).
//
// BandGesturesView API pinned (all optional, keyed by slot id):
//   slotBreathePatterns    slot -> BreathPattern.key (absent: 'resonance')
//   slotBreatheMinutes     slot -> minutes (absent: 3)
//   onSlotBreathePattern   (slot, patternKey) on a pattern row tap
//   onSlotBreatheMinutes   (slot, minutes) on a length chip tap
// In the tab of every gesture that has Breathing exercise ON, and only there,
// ONE picker (key `breathe-picker`):
//   * a row per kBreathPatterns entry, key `breathe-pattern:<key>`, showing the
//     pattern's label; the selected one carries a check icon;
//   * a chip per kBreatheMinuteChoices (1, 2, 3, 5, 10), key
//     `breathe-minutes:<n>`, text "<n> min"; the selected one carries a check
//     icon.
// The BandGestures wrapper wires them to GestureSettings (per slot).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_slots.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.tellTime,
  DeviceAction.breathe,
};

Finder _picker = find.byKey(const ValueKey('breathe-picker'));
Finder _pattern(String key) => find.byKey(ValueKey('breathe-pattern:$key'));
Finder _minutes(int n) => find.byKey(ValueKey('breathe-minutes:$n'));
Finder _check(Finder row) =>
    find.descendant(of: row, matching: find.byIcon(LucideIcons.check));
Finder _tab(int n) => find.byKey(ValueKey('gestures-tab:$n'));

bool _patternOn(String key) => _check(_pattern(key)).evaluate().isNotEmpty;
bool _minutesOn(int n) => _check(_minutes(n)).evaluate().isNotEmpty;

Future<void> _pump(
  WidgetTester t, {
  Set<DeviceAction> chosen = const {DeviceAction.breathe},
  Map<int, Set<DeviceAction>> tapActions = const {},
  Map<String, String> patterns = const {},
  Map<String, int> minutes = const {},
  void Function(String, String)? onPattern,
  void Function(String, int)? onMinutes,
  double width = 390,
  double scale = 1,
}) async {
  t.view.physicalSize = Size(width * 3, 3600 * 3);
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
        slotBreathePatterns: patterns,
        slotBreatheMinutes: minutes,
        onSlotBreathePattern: onPattern,
        onSlotBreatheMinutes: onMinutes,
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

Future<void> _tapKey(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() => Prefs.setString(kGesturesTabPref, ''));

  group('when it is shown', () {
    testWidgets('Breathing exercise is an offered action row', (t) async {
      await _pump(t, chosen: const {});
      expect(find.widgetWithText(SwitchRow, 'Breathing exercise'),
          findsOneWidget);
    });

    testWidgets('not when it is off, not with nothing chosen', (t) async {
      await _pump(t, chosen: const {DeviceAction.markMoment});
      expect(_picker, findsNothing);
      for (final p in kBreathPatterns) {
        expect(_pattern(p.key), findsNothing);
      }
      await _pump(t, chosen: const {});
      expect(_picker, findsNothing);
    });

    testWidgets('on in the double tap\'s tab: drawn once', (t) async {
      await _pump(t);
      expect(_picker, findsOneWidget);
    });

    testWidgets('in the tab of the gesture that has it on, and only there',
        (t) async {
      await _pump(t,
          chosen: const {},
          tapActions: const {4: {DeviceAction.breathe}});
      expect(_picker, findsNothing, reason: 'the double tap has none on');
      await _select(t, 4);
      expect(_picker, findsOneWidget);
      await _select(t, 3);
      expect(_picker, findsNothing);
      await _select(t, 2);
      expect(_picker, findsNothing);
    });

    testWidgets('beside the Tell the time picker when both are on',
        (t) async {
      await _pump(t,
          chosen: const {DeviceAction.breathe, DeviceAction.tellTime});
      expect(_picker, findsOneWidget);
      expect(find.byKey(const ValueKey('time-buzz-picker')), findsOneWidget);
    });
  });

  group('what it offers', () {
    testWidgets('a row per pattern, with its label', (t) async {
      await _pump(t);
      for (final p in kBreathPatterns) {
        expect(_pattern(p.key), findsOneWidget, reason: p.key);
        expect(find.descendant(of: _pattern(p.key), matching: find.text(p.label)),
            findsOneWidget,
            reason: p.key);
      }
    });

    testWidgets('a chip per length: 1, 2, 3, 5 and 10 min', (t) async {
      await _pump(t);
      for (final n in kBreatheMinuteChoices) {
        expect(_minutes(n), findsOneWidget, reason: '$n');
        expect(find.descendant(of: _minutes(n), matching: find.text('$n min')),
            findsOneWidget,
            reason: '$n');
      }
      expect(_minutes(4), findsNothing);
    });

    testWidgets('with nothing chosen yet the defaults are marked: Resonance '
        'and 3 min, one each', (t) async {
      await _pump(t);
      for (final p in kBreathPatterns) {
        expect(_patternOn(p.key), p.key == 'resonance', reason: p.key);
      }
      for (final n in kBreatheMinuteChoices) {
        expect(_minutesOn(n), n == 3, reason: '$n');
      }
    });

    testWidgets('each tab shows its OWN slot\'s choice', (t) async {
      await _pump(t,
          chosen: const {DeviceAction.breathe},
          tapActions: const {
            3: {DeviceAction.breathe},
          },
          patterns: const {'double': 'box', 'triple': 'four_seven_eight'},
          minutes: const {'double': 1, 'triple': 10});
      expect(_patternOn('box'), isTrue);
      expect(_patternOn('resonance'), isFalse);
      expect(_minutesOn(1), isTrue);
      expect(_minutesOn(3), isFalse);
      await _select(t, 3);
      expect(_patternOn('four_seven_eight'), isTrue);
      expect(_patternOn('box'), isFalse);
      expect(_minutesOn(10), isTrue);
      expect(_minutesOn(1), isFalse);
    });

    testWidgets('a slot absent from the maps shows the defaults even when '
        'another slot has a choice', (t) async {
      await _pump(t,
          chosen: const {DeviceAction.breathe},
          patterns: const {'quint': 'box'},
          minutes: const {'quint': 10});
      expect(_patternOn('resonance'), isTrue);
      expect(_minutesOn(3), isTrue);
    });
  });

  group('picking', () {
    testWidgets('a pattern row reports (slot, pattern key) of ITS tab',
        (t) async {
      final calls = <(String, String)>[];
      await _pump(t,
          chosen: const {},
          tapActions: const {5: {DeviceAction.breathe}},
          onPattern: (s, k) => calls.add((s, k)));
      await _select(t, 5);
      await _tapKey(t, _pattern('box'));
      await _tapKey(t, _pattern('extended_exhale'));
      expect(calls, [('quint', 'box'), ('quint', 'extended_exhale')]);
    });

    testWidgets('a length chip reports (slot, minutes) of ITS tab', (t) async {
      final calls = <(String, int)>[];
      await _pump(t, onMinutes: (s, m) => calls.add((s, m)));
      await _tapKey(t, _minutes(10));
      await _tapKey(t, _minutes(1));
      expect(calls, [('double', 10), ('double', 1)]);
    });

    testWidgets('the mark follows the caller\'s state, not the tap '
        '(the screen is driven by settings)', (t) async {
      await _pump(t, onPattern: (_, _) {});
      await _tapKey(t, _pattern('box'));
      expect(_patternOn('resonance'), isTrue);
      expect(_patternOn('box'), isFalse);
    });

    testWidgets('with no callbacks the rows are inert, not a crash',
        (t) async {
      await _pump(t);
      await _tapKey(t, _pattern('box'));
      await _tapKey(t, _minutes(5));
      expect(t.takeException(), isNull);
    });
  });

  group('layout', () {
    for (final (w, s) in [(320.0, 1.0), (390.0, 2.0), (360.0, 3.1)]) {
      testWidgets('no overflow at ${w.toInt()} pt wide, text x$s', (t) async {
        await _pump(t, width: w, scale: s);
        final faults = <Object>[];
        while (true) {
          final e = t.takeException();
          if (e == null) break;
          faults.add(e);
        }
        expect(faults, isEmpty);
        expect(_picker, findsOneWidget);
      });
    }
  });

  group('the Gestures screen wires it to the per-slot settings', () {
    testWidgets('a pick in a tab is stored for THAT slot only, and the mark '
        'follows', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final g = app.gestureSettings;
      g.supported = {..._supported};
      await g.setDoubleTapActions({DeviceAction.breathe});
      await g.setActionsForTaps(3, {DeviceAction.breathe});
      t.view.physicalSize = const Size(390 * 3, 3600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          Provider<Capabilities>.value(
              value: Capabilities(const CapabilityInputs())),
        ],
        child: MaterialApp(
            theme: buildTheme(Brightness.light), home: const BandGestures()),
      ));
      await t.pumpAndSettle();

      await _tapKey(t, _pattern('box'));
      await _tapKey(t, _minutes(5));
      expect(g.breathePatternFor('double'), 'box');
      expect(g.breatheMinutesFor('double'), 5);
      expect(g.breathePatternFor('triple'), 'resonance');
      expect(_patternOn('box'), isTrue);
      expect(_minutesOn(5), isTrue);

      await _select(t, 3);
      expect(_patternOn('resonance'), isTrue, reason: 'triple has its own');
      await _tapKey(t, _pattern('four_seven_eight'));
      expect(g.breathePatternFor('triple'), 'four_seven_eight');
      expect(g.breathePatternFor('double'), 'box');
    });
  });
}
