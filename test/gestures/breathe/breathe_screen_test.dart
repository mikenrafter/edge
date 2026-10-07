// CalmBreathing and the screen-free pacer (RED): the screen and the pacer must
// never cue the same phase twice.
//
// AppState.breathingPacedByBand is the flag (BreathingController.pacedByBand):
// set while the pacer owns the running session's cues. The screen
//   * makes NO buzzBreathPhase / buzzSessionComplete call while it is set, and
//     checks it at the moment a cue would fire (it can flip mid-run);
//   * SHOWS a session that is running (started by the gesture) instead of the
//     setup page: mounted on one, or open when one starts, it is in the running
//     view ("End session") at the session's own pattern and elapsed time, and
//     its End session stops the session through AppState;
//   * never stops that session itself (not at the target, not on leaving the
//     screen): only the pacer ends it;
//   * leaves the running view when that session ends under it;
//   * is unchanged for a session of its own: the inhale cue at the first tick,
//     the next phase's cue at its boundary, one cue per boundary.
//
// The fake is an AppState subclass (the pattern the home-header tests use)
// whose breathing members are recorders.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/calm_breathing.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Spy extends AppState {
  _Spy() : super.forTesting();

  bool active = false;
  bool paced = false;
  BreathPattern pattern = kBreathPatterns.first;
  Duration? target;
  DateTime? startedAt;

  final phases = <BreathPhaseKind>[];
  int completes = 0;
  int starts = 0;
  int stops = 0;

  /// A session the gesture started: running, paced by the band, [ago] in.
  void gestureSession(BreathPattern p, Duration length,
      {Duration ago = Duration.zero}) {
    active = true;
    paced = true;
    pattern = p;
    target = length;
    startedAt = DateTime.now().subtract(ago);
    notifyListeners();
  }

  /// The session ended without the screen (the pacer finished, the gesture
  /// stopped it, the Live Activity did).
  void endedElsewhere() {
    active = false;
    paced = false;
    notifyListeners();
  }

  void setPaced(bool v) {
    paced = v;
    notifyListeners();
  }

  @override
  bool get breathingActive => active;
  @override
  bool get breathingPacedByBand => paced;
  @override
  BreathPattern get breathingPattern => pattern;
  @override
  Duration? get breathingTarget => target;
  @override
  DateTime? get breathingStartedAt => startedAt;
  @override
  bool get breathingWindowOpen => false;
  @override
  Future<void> openBreathingWindow() async {}
  @override
  Future<void> closeBreathingWindow() async {}
  @override
  Future<List<Map<String, dynamic>>> breathingHistory({int limit = 30}) async =>
      const [];

  @override
  Future<void> startBreathingSession(
      {BreathPattern? pattern, Duration? target}) async {
    starts++;
    active = true;
    this.pattern = pattern ?? this.pattern;
    this.target = target;
    startedAt = DateTime.now();
    notifyListeners();
  }

  @override
  Future<void> stopBreathingSession() async {
    stops++;
    active = false;
    paced = false;
    notifyListeners();
  }

  @override
  void buzzBreathPhase(BreathPhaseKind kind) => phases.add(kind);
  @override
  void buzzSessionComplete() => completes++;
}

Future<_Spy> _pump(WidgetTester t,
    {void Function(_Spy)? before, bool viaRoute = false}) async {
  final app = _Spy();
  addTearDown(app.dispose);
  before?.call(app);
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(
          create: (_) => UnitsController.seed(UnitSystem.metric)),
      ChangeNotifierProvider(
          create: (_) =>
              ThemeController.seed(AppThemeChoice.light, Brightness.light)),
      ChangeNotifierProvider(create: (_) => LocaleController.seed(null)),
      Provider<Capabilities>.value(
          value: Capabilities(const CapabilityInputs())),
    ],
    child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: viaRoute
            ? Builder(
                builder: (c) => TextButton(
                    onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(
                        builder: (_) => const CalmBreathing())),
                    child: const Text('open')))
            : const CalmBreathing()),
  ));
  if (viaRoute) {
    await t.tap(find.text('open'));
    await t.pump(const Duration(seconds: 1));
  }
  await t.pump(const Duration(milliseconds: 50));
  // Leave the tree so the screen's ticker and timers are disposed before the
  // test ends.
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
  });
  return app;
}

final _end = find.text('End session');
final _begin = find.text('Begin');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  group('a session of its own is cued by the screen, as before', () {
    testWidgets('Begin starts it; the inhale cue at the first tick, the exhale '
        'cue at the first boundary, one cue per boundary', (t) async {
      final app = await _pump(t);
      await t.tap(_begin);
      await t.pump(const Duration(milliseconds: 100));
      expect(app.starts, 1);
      expect(app.breathingPacedByBand, isFalse);
      await t.pump(const Duration(milliseconds: 100));
      expect(app.phases, [BreathPhaseKind.inhale]);
      await t.pump(const Duration(seconds: 6)); // past 5.45 s
      expect(app.phases, [BreathPhaseKind.inhale, BreathPhaseKind.exhale]);
      await t.pump(const Duration(seconds: 1));
      expect(app.phases, hasLength(2), reason: 'not again inside the phase');
    });
  });

  group('while the band paces the session, the screen stays quiet', () {
    testWidgets('mounted on a gesture-started session: the running view, no '
        'setup page, and not one cue over a minute of ticks', (t) async {
      final app = await _pump(t, before: (a) {
        a.gestureSession(kBreathPatternsByKey['box']!,
            const Duration(minutes: 3),
            ago: const Duration(seconds: 20));
      });
      expect(_end, findsOneWidget);
      expect(_begin, findsNothing);
      expect(find.text('Take a breath.'), findsNothing);
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(app.phases, isEmpty);
      expect(app.completes, 0);
      expect(app.starts, 0, reason: 'it joined the session, it did not start '
          'another');
    });

    testWidgets('open and idle when the gesture starts one: the screen picks '
        'it up and stays quiet', (t) async {
      final app = await _pump(t);
      expect(_begin, findsOneWidget);
      app.gestureSession(kBreathPatternsByKey['resonance']!,
          const Duration(minutes: 3));
      await t.pump(const Duration(milliseconds: 100));
      expect(_end, findsOneWidget);
      expect(_begin, findsNothing);
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(app.phases, isEmpty);
      expect(app.starts, 0);
    });

    testWidgets('the flag is checked when a cue would fire: set mid-run, the '
        'screen\'s own session cues no further', (t) async {
      final app = await _pump(t);
      await t.tap(_begin);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(app.phases, [BreathPhaseKind.inhale]);
      app.setPaced(true);
      await t.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(app.phases, [BreathPhaseKind.inhale]);
    });

    testWidgets('End session on it stops the session through AppState '
        '(banking), with no complete cue, and lands on the result',
        (t) async {
      final app = await _pump(t, before: (a) {
        a.gestureSession(
            kBreathPatternsByKey['box']!, const Duration(minutes: 3));
      });
      await t.tap(_end);
      await t.pump(const Duration(milliseconds: 100));
      expect(app.stops, 1);
      expect(app.completes, 0);
      expect(app.phases, isEmpty);
      expect(app.breathingActive, isFalse);
      expect(_end, findsNothing);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('the session ending under the screen (the pacer finished, '
        'the gesture stopped it) leaves the running view, still no cue',
        (t) async {
      final app = await _pump(t, before: (a) {
        a.gestureSession(
            kBreathPatternsByKey['box']!, const Duration(minutes: 3));
      });
      expect(_end, findsOneWidget);
      app.endedElsewhere();
      await t.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(_end, findsNothing);
      expect(app.phases, isEmpty);
      expect(app.completes, 0);
    });

    testWidgets('the screen does not stop it at the target: only the pacer '
        'ends a band-paced session (it plays the complete cue first)',
        (t) async {
      final app = await _pump(t, before: (a) {
        a.gestureSession(
            kBreathPatternsByKey['box']!, const Duration(minutes: 3),
            ago: const Duration(minutes: 4)); // already past its target
      });
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(seconds: 1));
      }
      expect(app.stops, 0);
      expect(app.breathingActive, isTrue);
      expect(_end, findsOneWidget);
    });

    testWidgets('leaving the screen leaves the session running on the band',
        (t) async {
      final app = await _pump(t, viaRoute: true, before: (a) {
        a.gestureSession(
            kBreathPatternsByKey['box']!, const Duration(minutes: 3));
      });
      expect(_end, findsOneWidget);
      await t.tap(find.byIcon(LucideIcons.x));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      expect(_end, findsNothing);
      expect(find.text('open'), findsOneWidget, reason: 'the screen was left');
      expect(app.stops, 0);
      expect(app.breathingActive, isTrue);
    });
  });
}
