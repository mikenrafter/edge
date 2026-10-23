// First-launch consistency: a screen with NO data shows the SAME cards in the
// SAME places as the loaded screen, drawn empty - never different cards.
// Settled empty frame vs settled loaded frame, restricted to the card-level
// ids; content inside a card may differ.
//
// Contract for the green phase: every top-level section of Home and Health
// carries a key 'card:<name>' (the same name in both states).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/lab_catalogue.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/sleep_tab.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show S;

import '../../support/as_of_recalc_fakes.dart';
import '../../support/bundled_fonts.dart';
import '../../support/tabs_consistency_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Real type, not the test font: with Ahem every glyph is a full em wide, so
    // captions wrap at counts no real screen reaches and card heights would
    // differ for reasons that are not the layout's.
    await loadFonts();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The community asks are optional cards (they come and go with eligibility
    // and cooldown), so they are dismissed here: this test is about the cards
    // that must be there either way. `DetectedActivitiesCard` is likewise held
    // at zero pending by the fake repos.
    await Prefs.ensureLoaded();
    for (final k in ['nudge.discord.dismissed', 'nudge.donate.dismissed']) {
      Prefs.setBool(k, true);
      addTearDown(() => Prefs.setBool(k, false));
    }
  });

  // Tall enough that the whole Home list is on screen: a card below the fold
  // would be "missing" from one state's frame for the wrong reason.
  const tall = ShiftRect(0, 0, 390, 3000);

  const p = ShiftPolicy.standard;

  Future<Frame> settled(WidgetTester t, Widget screen, AppState app,
      Future<void> Function(WidgetTester)? drive) async {
    await t.pumpWidget(perfApp(app, screen));
    await settleShell(t);
    if (drive != null) {
      await drive(t);
      await settleShell(t);
    }
    final f = captureFrame(t, viewport: tall);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 5));
    return f;
  }

  Future<void> check(WidgetTester t, String name, Widget Function() screen,
      {AppState Function()? emptyApp,
      AppState Function()? loadedApp0,
      Widget Function()? emptyScreen,
      Future<void> Function(WidgetTester)? drive}) async {
    t.view.physicalSize = const Size(390 * 3, 3000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final loadedApp = loadedApp0 != null
        ? loadedApp0()
        : (AppState.forTesting()
          ..repo = TabsRepo(homeBundle(
              readiness: 70,
              overnightAt: todayAtMs(8, 42),
              activityAt: todayAtMs(8, 42))));
    final emptyAppState = emptyApp != null
        ? emptyApp()
        : (AppState.forTesting()..repo = EmptyTabsRepo());
    addTearDown(loadedApp.dispose);
    addTearDown(emptyAppState.dispose);
    final empty = await settled(t, (emptyScreen ?? screen)(), emptyAppState, drive);
    final loaded = await settled(t, screen(), loadedApp, drive);

    // Informational on failure: how the two states compare on EVERY id.
    final all = compareLayouts(empty, loaded, p, viewport: tall);
    printOnFailure(top('$name empty vs loaded, all ids', all, n: 12));
    printOnFailure('$name empty: ${empty.elements.length} elements, '
        'loaded: ${loaded.elements.length}');

    String rects(Frame f) => [
          for (final e in f.elements)
            if (e.id.startsWith('card:'))
              '${e.id} ${e.rect.top.toStringAsFixed(1)}+${e.rect.height.toStringAsFixed(1)}'
        ].join('\n  ');
    printOnFailure('$name empty rects:\n  ${rects(empty)}');
    printOnFailure('$name loaded rects:\n  ${rects(loaded)}');
    final a = cardIds(empty), b = cardIds(loaded);
    expect(b, isNotEmpty, reason: '$name: no top-level section is keyed card:*');
    expect(a, isNotEmpty, reason: '$name: first launch shows no card:* section');
    expect(a, b,
        reason: '$name: first launch and loaded must show the same cards; '
            'only-empty: ${a.difference(b)}, only-loaded: ${b.difference(a)}');
    final r = compareLayouts(empty, loaded, p,
        viewport: tall, only: cardOrShared);
    printOnFailure(top('$name empty vs loaded, card/shared', r));
    expect(r.findings.where((f) => f.score >= p.warnAt), isEmpty,
        reason: worst(name, r, p));
  }

  // HOME RINGS. Owner decision 3 (ui-feedback-2026-10-22.md, DECIDED, 2026-10-22;
  // applied 2026-10-23): "CLS cost of varying count accepted". The ring card ends
  // in 0, 1 or 2 why panels / an older row when loaded, and in the help strip
  // (first-week guidance, status, gap reasons) when empty. That is the same kind
  // of varying panel, so the card's HEIGHT may differ between the two states,
  // and the cards below follow it, by exactly that strip and nothing else.
  // Everything above it is held to zero tolerance: the card's top, the three
  // dials and their labels sit at identical positions, and the cards below move
  // by the strip's height (plus whatever their own heights differ by).
  const labels = ['RECOVERY', 'STRAIN', 'SLEEP'];

  // What the ring card shows, read off the live tree (frame capture has no
  // private widget types): the dials, their labels and the help strip.
  ({List<Rect> dials, List<Rect> labels, Rect? strip}) ringsNow(WidgetTester t) {
    final ringsCard = find.byKey(const ValueKey('card:rings'));
    final dials = find.descendant(
        of: ringsCard,
        matching: find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_Dial'));
    final strip = find.descendant(
        of: ringsCard,
        matching: find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_HelpStrip'));
    return (
      dials: [for (var i = 0; i < dials.evaluate().length; i++) t.getRect(dials.at(i))],
      labels: [
        for (final l in labels)
          t.getRect(find.descendant(of: ringsCard, matching: find.text(l)).first)
      ],
      strip: strip.evaluate().isEmpty ? null : t.getRect(strip.first),
    );
  }

  Future<void> checkHomeRings(WidgetTester t, String name, AppState empty) async {
    t.view.physicalSize = const Size(390 * 3, 3000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final loadedApp = AppState.forTesting()
      ..repo = TabsRepo(homeBundle(
          readiness: 70, overnightAt: todayAtMs(8, 42), activityAt: todayAtMs(8, 42)));
    addTearDown(loadedApp.dispose);
    addTearDown(empty.dispose);
    late ({List<Rect> dials, List<Rect> labels, Rect? strip}) e, l;
    final ef = await settled(t, const HomeScreen(hour: 9), empty, (t) async => e = ringsNow(t));
    final lf = await settled(t, const HomeScreen(hour: 9), loadedApp, (t) async => l = ringsNow(t));

    expect(cardIds(ef), cardIds(lf), reason: '$name: same cards in both states');
    expect(e.dials.length, 3, reason: '$name: three dials');
    expect(l.dials, e.dials, reason: '$name: the dials sit at identical positions');
    expect(l.labels, e.labels, reason: '$name: the labels sit at identical positions');
    ShiftRect rect(Frame f, String id) =>
        f.elements.firstWhere((x) => x.id == id).rect;
    final re = rect(ef, 'card:rings'), rl = rect(lf, 'card:rings');
    expect(rl.top, re.top, reason: '$name: the ring card top is identical');
    expect(rl.left, re.left);
    expect(rl.width, re.width, reason: '$name: the ring card width is identical');

    // The ONE exemption: the rings card's panel slot. Empty shows the help
    // strip (and the gap above it); a healthy loaded day shows nothing.
    expect(e.strip, isNotNull, reason: '$name: the empty state explains itself');
    expect(l.strip, isNull, reason: '$name: a healthy loaded day has no strip');
    final delta = e.strip!.height + S.x3;
    expect(re.height - rl.height, closeTo(delta, 0.01),
        reason: '$name: the card height differs by the strip (+ its gap) only');

    // EVERYTHING else is held to the original test: take the rings delta out of
    // the empty frame (the rings card shrinks by it, whatever sits below moves
    // up by it) and compare under the standard policy, shared elements and
    // widths included. Then exactly: every other card has identical width and
    // height and sits `delta` lower.
    Frame minusDelta(Frame f) => Frame(f.atMs, [
          for (final x in f.elements)
            if (x.id == 'card:rings')
              ElementSnapshot(
                  id: x.id,
                  rect: ShiftRect(x.rect.left, x.rect.top, x.rect.width,
                      x.rect.height - delta),
                  role: x.role,
                  colorArgb: x.colorArgb)
            else if (x.rect.top >= re.top + re.height - 0.01)
              ElementSnapshot(
                  id: x.id,
                  rect: ShiftRect(x.rect.left, x.rect.top - delta,
                      x.rect.width, x.rect.height),
                  role: x.role,
                  colorArgb: x.colorArgb)
            else
              x
        ]);
    final r = compareLayouts(minusDelta(ef), lf, p,
        viewport: tall, only: cardOrShared);
    printOnFailure(top('$name empty (rings delta removed) vs loaded', r));
    expect(r.findings.where((f) => f.score >= p.warnAt), isEmpty,
        reason: worst(name, r, p));
    for (final id in cardIds(ef).where((x) => x != 'card:rings')) {
      final a = rect(ef, id), b = rect(lf, id);
      expect(a.width, b.width, reason: '$name: $id width');
      expect(a.height, closeTo(b.height, 0.01), reason: '$name: $id height');
      final below = a.top > re.top;
      expect(a.top - b.top, closeTo(below ? delta : 0, 0.01),
          reason: '$name: $id ${below ? 'moves down by the rings delta' : 'does not move'}');
    }
  }

  testWidgets('Home: empty database vs loaded - rings fixed, card height follows the panel count',
      (t) => checkHomeRings(t, 'home', AppState.forTesting()..repo = EmptyTabsRepo()));

  // No repo at all (the database is not open yet): the screen's _d == null
  // path, which draws its own header and its own cards.
  testWidgets('Home: no repo yet vs loaded - rings fixed, card height follows the panel count',
      (t) => checkHomeRings(t, 'home(no repo)', AppState.forTesting()));

  testWidgets('Health: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health', () => const HealthScreen()));

  // Sub-tabs read their own data; each is handed the loaded or the first-launch
  // shape through the constructor's seams - the same objects the loaders build
  // from a populated / an empty database.
  testWidgets('Health Explore: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health Explore',
          () => HealthScreen(tab: 1, data: const HealthData(), explore: _exploreLoaded),
          emptyScreen: () => const HealthScreen(
              tab: 1, data: HealthData(), explore: ExploreData())));

  testWidgets('Health Trends: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health Trends',
          () => HealthScreen(tab: 2, data: _trendsLoaded()),
          emptyScreen: () => const HealthScreen(tab: 2, data: HealthData())));

  testWidgets('Health Vitals: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health Vitals',
          () => HealthScreen(tab: 3, data: _vitalsToday, vitals: _vitalsLoaded()),
          emptyScreen: () => const HealthScreen(
              tab: 3, data: HealthData(), vitals: VitalsData())));

  testWidgets('Health Labs: empty database vs loaded - same cards, same places',
      (t) => check(t, 'health Labs',
          () => const HealthScreen(tab: 4, data: HealthData(), labs: _labsLoaded),
          emptyScreen: () => const HealthScreen(
              tab: 4, data: HealthData(), labs: LabsData(markers: kLabMarkers))));

  testWidgets('Sleep: empty database vs loaded - same cards, same places',
      (t) => check(t, 'sleep', () => const SleepTab()));


  // The Activity tab keeps its sub-tab in state; the case opens each by its
  // label, the way a user does.
  for (final (i, label) in [(0, 'For you'), (1, 'Activities'), (2, 'History')]) {
    testWidgets('Activity $label: empty database vs loaded - same cards, same places',
        (t) => check(t, 'activity $label', () => ChangeNotifierProvider(
                create: (_) => UnitsController.seed(UnitSystem.metric),
                child: const WorkoutScreen()),
            loadedApp0: () => AppState.forTesting()..repo = _ActivityRepo(),
            drive: i == 0
                ? null
                : (t) async {
                    final tab = find.widgetWithText(Pressable, label).first;
                    await t.ensureVisible(tab);
                    await t.pump();
                    await t.tap(tab);
                    await t.pump();
                    // ensureVisible may have scrolled the page; both states
                    // are compared from the top.
                    await t.fling(
                        find.byWidgetPredicate((w) =>
                            w is Scrollable && w.axis == Axis.vertical).first,
                        const Offset(0, 2000),
                        4000);
                  }));
  }
}

/// Loaded Activity: a load, a week of heart effort and two sessions.
class _ActivityRepo extends TabsRepo {
  _ActivityRepo()
      : super(homeBundle(
            readiness: 70,
            overnightAt: todayAtMs(8, 42),
            activityAt: todayAtMs(8, 42)));

  @override
  Future<Map<String, dynamic>> getProfile() async => {'weight_kg': 70.0};
  @override
  Future<Map<String, dynamic>> getInsights() async => {
        'load': {
          'value': {'ctl': 42.0, 'atl': 38.0, 'tsb': 4.0},
        },
      };
  @override
  Future<Map<String, dynamic>> getRecords() async => {'workouts_tracked': 2};
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    if (metric != 'trimp') return const {'points': []};
    final noon = todayAtMs(12, 0) ~/ 1000;
    return {
      'points': [
        for (var i = 0; i < 7; i++) {'t': noon - i * 86400, 'v': 40.0 + i},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async => {
        'workouts': [
          for (var i = 0; i < 2; i++)
            {
              'id': 'w$i',
              'type': 'Running',
              'start_ts': todayAtMs(7, 0) ~/ 1000 - i * 3600,
              'duration_min': 30,
              'strain': 8.0,
            },
        ],
      };
}

final _exploreLoaded = ExploreData(counts: {
  for (final f in kMetricCatalogue.take(3))
    for (final r in f.rows.take(2)) r.series: 12,
});

HealthData _trendsLoaded() {
  final now = todayAtMs(8, 42) ~/ 1000;
  List<ChartPoint> series(double base) => [
        for (var i = 20; i >= 0; i--)
          ChartPoint(t: now - i * 86400, v: base + (i % 5).toDouble()),
      ];
  return HealthData(charts: {
    'resting_hr': series(55),
    'hrv': series(48),
    'sleep': series(420),
  });
}

const _vitalsToday = HealthData(today: {
  'skin_temp': {'value': 0.3, 'dev_c': 0.3},
});

VitalsData _vitalsLoaded() => VitalsData(
      day: todayId,
      days: [todayId, yesterdayId],
      timeline: {
        'date': todayId,
        'highs': {
          'low_hr': {'v': 52},
          'peak_hr': {'v': 141},
        },
      },
      lungs: const {
        'resp': {'value': 14.5},
      },
      wear: const {'worn_min': 900, 'coverage_pct': 80},
      hrv: const {'rmssd': 55},
    );

const _labsLoaded = LabsData(markers: kLabMarkers, results: [
  {'marker': 'ferritin', 'taken_on': '2026-03-04', 'value': 42, 'unit': 'ng/mL'},
  {'marker': 'hba1c', 'taken_on': '2026-03-04', 'value': 5.2, 'unit': '%'},
]);
