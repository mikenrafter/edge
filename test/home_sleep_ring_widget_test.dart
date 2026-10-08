// The Home sleep ring as rendered: stage arcs, the grey estimate arc, the
// words under them, and the data HomeData hands it.
//
// Every instant is injected (`RingTrio.now`, fixed dates). Nothing here reads
// the system clock.
//
// ROOT-CAUSE REGRESSIONS (owner saw "of 8h 10m" only BEFORE sleeping and an
// EMPTY bar AFTER sleeping):
//   * the arc and the "of ..." text were both gated on `sleepNeedMin` alone, so
//     a scored night with no learned need drew duration + "No target yet" + an
//     empty bar, and
//   * `HomeData.loadForDay` never loaded `sleepNeedMin` at all, so any dated
//     view of a slept night did the same even when a need existed.
// Both are pinned below: a slept night is never an empty bar, and the need
// reaches the ring from both loaders.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

// ── fixtures ───────────────────────────────────────────────────────────────

final _evening = DateTime(2026, 10, 8, 22, 0);
const _schedule = ExpectedSleepSchedule(onsetMinute: 1380, wakeMinute: 420);

const _stages = SleepStageMin(deep: 70, rem: 95, light: 277, awake: 30);

Metric _min(num v) => Metric(
      value: v,
      unit: 'min',
      confidence: .8,
      tier: MetricTier.estimate,
    );

HomeData _slept({
  Metric? need,
  SleepStageMin? stages = _stages,
  num duration = 442,
}) =>
    HomeData(
      dayId: '2026-10-09',
      readiness: const Metric(value: 82, confidence: .8, tier: MetricTier.high),
      strain: const Metric(value: 9.0, confidence: .6, tier: MetricTier.estimate),
      sleepMin: _min(duration),
      sleepNeedMin: need ?? Metric.empty,
      sleepStages: stages,
    );

HomeData _unslept({
  ExpectedSleepSchedule? schedule,
  DateTime? alarm,
  Metric need = Metric.empty,
  Metric bedtime = Metric.empty,
  int? learnedOnset,
  int? learnedWake,
  Metric sleepMin = Metric.empty,
}) =>
    HomeData(
      dayId: '2026-10-08',
      readiness: const Metric(value: 82, confidence: .8, tier: MetricTier.high),
      strain: const Metric(value: 9.0, confidence: .6, tier: MetricTier.estimate),
      sleepMin: sleepMin,
      sleepNeedMin: need,
      bedtime: bedtime,
      sleepSchedule: schedule,
      nextAlarm: alarm,
      learnedOnsetMin: learnedOnset,
      learnedWakeMin: learnedWake,
    );

Future<void> _pump(
  WidgetTester t,
  HomeData d, {
  DateTime? now,
  double textScale = 1,
}) async {
  t.view.physicalSize = const Size(390 * 3, 800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: SingleChildScrollView(
          child: RingTrio(d: d, now: now ?? _evening),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

/// Every ring painter on screen, in tree order: recovery, strain, sleep.
List<CustomPainter> _ringPainters(WidgetTester t) => [
      for (final e in find.byType(CustomPaint).evaluate())
        if ((e.widget as CustomPaint).painter case final CustomPainter p
            when p is Ring || p is StageRing || p is DashedRing)
          p,
    ];

CustomPainter _sleepPainter(WidgetTester t) => _ringPainters(t).last;

P _p(WidgetTester t) => P.of(t.element(find.byType(RingTrio)));

// ── a fake repository, for the loaders ─────────────────────────────────────

class _Repo extends LocalRepository {
  _Repo({
    this.today = const {},
    this.insights = const {},
    this.night = const {},
    this.windows = const [],
  });

  final Map<String, dynamic> today, insights, night;
  final List<Map<String, dynamic>> windows;

  @override
  Future<Map<String, dynamic>> getToday() async => today;
  @override
  Future<Map<String, dynamic>> getInsights() async => insights;
  @override
  Future<Map<String, dynamic>> getProfile() async => const {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => night;
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => const {};
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60}) async =>
      windows;
}

Map<String, dynamic> _env(num v) => {
      'value': v,
      'confidence': .8,
      'tier': 'ESTIMATE',
      'unit': 'min',
    };

const _needInsights = {
  'sleep_coach': {
    'need': {
      'value': {'need_sec': 27720}, // 462 min
      'confidence': .7,
      'tier': 'ESTIMATE',
    },
  },
};

Map<String, dynamic> get _sleptToday => {
      'daily': const {},
      'sleep': {'duration_min': _env(442)},
      'status': {
        'today_day': '2026-10-09',
        'overnight_state': 'ready',
        'overnight_day': '2026-10-09',
        'showing_prior_overnight': false,
      },
    };

const _nightMap = {
  'has_sleep': true,
  'duration_min': 442,
  'deep_min': 70,
  'rem_min': 95,
  'light_min': 277,
  'awake_min': 30,
};

/// Five nights, onset 23:00 the evening before and wake 07:00, as
/// `sleepWindows` returns them (epoch seconds).
List<Map<String, dynamic>> _windows() => [
      for (var day = 1; day <= 5; day++)
        {
          'date': '2026-10-0$day',
          'onset_ts':
              DateTime(2026, 10, day - 1, 23, 0).millisecondsSinceEpoch ~/ 1000,
          'wake_ts':
              DateTime(2026, 10, day, 7, 0).millisecondsSinceEpoch ~/ 1000,
        },
    ];

void main() {
  group('slept: stage arcs', () {
    testWidgets('Deep, REM, Light, Awake in the hypnogram colours, '
        'contiguous, on the track', (t) async {
      await _pump(t, _slept());
      final painter = _sleepPainter(t);
      expect(painter, isA<StageRing>());
      final ring = painter as StageRing;
      final cols = Hypnogram.cols(_p(t));
      expect([for (final a in ring.arcs) a.color], [
        cols[SleepStage.deep],
        cols[SleepStage.rem],
        cols[SleepStage.light],
        cols[SleepStage.awake],
      ]);
      expect([for (final a in ring.arcs) a.fraction], [
        closeTo(70 / 480, 1e-9),
        closeTo(95 / 480, 1e-9),
        closeTo(277 / 480, 1e-9),
        closeTo(30 / 480, 1e-9),
      ]);
      expect(ring.track, _p(t).track);
    });

    testWidgets('value is the duration; sub is "92% of 8h 00m (default)" when '
        'the target is the default', (t) async {
      await _pump(t, _slept());
      expect(find.text('7h 22m'), findsOneWidget);
      expect(find.text('92% of 8h 00m (default)'), findsOneWidget);
    });

    testWidgets('a learned need is the target and is NOT labelled default',
        (t) async {
      await _pump(t, _slept(need: _min(462)));
      expect(find.text('96% of 7h 42m'), findsOneWidget);
      expect(find.textContaining('default'), findsNothing);
      final ring = _sleepPainter(t) as StageRing;
      expect(ring.arcs.first.fraction, closeTo(70 / 462, 1e-9));
    });

    testWidgets('no stage totals => ONE solid arc in the sleep colour, never '
        'a split', (t) async {
      await _pump(t, _slept(stages: null));
      final painter = _sleepPainter(t);
      expect(painter, isNot(isA<StageRing>()));
      expect(painter, isA<Ring>());
      final ring = painter as Ring;
      expect(ring.color, _p(t).on(C.blue));
      expect(ring.v, closeTo(442 / 480, 1e-9));
      expect(ring.solid, isTrue);
    });

    testWidgets('a night longer than the target caps at a full circle',
        (t) async {
      await _pump(
        t,
        _slept(
          duration: 540,
          stages: const SleepStageMin(deep: 90, rem: 120, light: 330, awake: 20),
        ),
      );
      final ring = _sleepPainter(t) as StageRing;
      final sweep = ring.arcs.fold<double>(0, (s, a) => s + a.fraction);
      expect(sweep, closeTo(1.0, 1e-9));
      expect(find.text('113% of 8h 00m (default)'), findsOneWidget);
    });

    testWidgets('stages still draw at the accessibility text size',
        (t) async {
      await _pump(t, _slept(), textScale: 2);
      expect(_sleepPainter(t), isA<StageRing>());
      expect(find.text('92% of 8h 00m (default)'), findsOneWidget);
    });

    testWidgets('spoken text carries the percentage and the default label',
        (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _slept());
      expect(
        find.bySemanticsLabel(
            RegExp(r'Sleep\. 7h 22m\. 92% of 8h 00m \(default\)')),
        findsOneWidget,
      );
      h.dispose();
    });
  });

  group('regression: a slept night is never an empty bar', () {
    testWidgets('scored night + NO learned need: arc is drawn against the '
        'labelled default, not "No target yet" and an empty bar', (t) async {
      await _pump(t, _slept(need: Metric.empty, stages: null));
      expect(find.text('No target yet'), findsNothing);
      final ring = _sleepPainter(t) as Ring;
      expect(ring.v, greaterThan(0));
      expect(find.text('92% of 8h 00m (default)'), findsOneWidget);
    });

    testWidgets('scored night + learned need present: the "of" target is '
        'there AND the bar is filled', (t) async {
      await _pump(t, _slept(need: _min(462), stages: null));
      expect(find.text('96% of 7h 42m'), findsOneWidget);
      expect((_sleepPainter(t) as Ring).v, closeTo(442 / 462, 1e-9));
    });

    test('HomeData.load carries the learned need and the stage totals of a '
        'night that scored', () async {
      final repo = _Repo(
        today: _sleptToday,
        insights: _needInsights,
        night: _nightMap,
      );
      final d = await HomeData.load(repo);
      expect(d.sleepMin.value, 442);
      expect(d.sleepNeedMin.value, 462);
      expect(d.sleepStages?.deep, 70);
      expect(d.sleepStages?.rem, 95);
      expect(d.sleepStages?.light, 277);
      expect(d.sleepStages?.awake, 30);
    });

    test('HomeData.loadForDay (a dated view of a slept night) carries the '
        'learned need — it used to drop it and draw an empty bar', () async {
      final repo = _Repo(
        insights: _needInsights,
        night: _nightMap,
      );
      final d = await HomeData.loadForDay(repo, '2026-10-08');
      expect(d.sleepMin.value, 442);
      expect(d.sleepNeedMin.value, 462);
      expect(d.sleepStages?.deep, 70);
    });

    test('HomeData.loadForDay with no learned need leaves it absent (the ring '
        'then shows the labelled default, never a made-up need)', () async {
      final repo = _Repo(night: _nightMap);
      final d = await HomeData.loadForDay(repo, '2026-10-08');
      expect(d.sleepNeedMin.value, isNull);
      expect(d.sleepMin.value, 442);
    });

    testWidgets('a dated slept night with no need renders a filled bar and the '
        'default label', (t) async {
      final d = await t.runAsync(() => HomeData.loadForDay(
          _Repo(night: _nightMap), '2026-10-08'));
      await _pump(t, d!);
      expect(find.text('No target yet'), findsNothing);
      expect(find.text('92% of 8h 00m (default)'), findsOneWidget);
      expect(_sleepPainter(t), isA<StageRing>());
    });
  });

  group('loaders: learned times, no stale stages', () {
    test('HomeData.load learns the typical onset and wake from recent nights',
        () async {
      final d = await HomeData.load(_Repo(
        today: _sleptToday,
        insights: _needInsights,
        night: _nightMap,
        windows: _windows(),
      ));
      expect(d.learnedOnsetMin, 23 * 60);
      expect(d.learnedWakeMin, 7 * 60);
    });

    test('a night that is NOT today\'s never lends its stages to today',
        () async {
      final repo = _Repo(
        today: {
          'daily': const {},
          'sleep': const {},
          'status': {
            'today_day': '2026-10-09',
            'overnight_state': 'building',
            'overnight_day': '2026-10-08',
            'showing_prior_overnight': true,
          },
        },
        insights: _needInsights,
        night: _nightMap, // last night's, which the ring must not borrow
      );
      final d = await HomeData.load(repo);
      expect(d.sleepMin.value, isNull);
      expect(d.sleepStages, isNull);
      expect(d.sleepNeedMin.value, 462);
    });
  });

  group('HomeScreen lays AppState\'s schedule and alarm over the loaded data',
      () {
    Future<void> pumpHome(WidgetTester t, AppState app) async {
      t.view.physicalSize = const Size(390 * 3, 1600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: Scaffold(
            body: HomeScreen(
              hour: 22,
              now: _evening,
              data: _unslept(),
            ),
          ),
        ),
      ));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('the saved schedule gives the estimate', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.sleepOperations.schedule = _schedule;
      await pumpHome(t, app);
      expect(find.text('on track for 5 cycles, 8h 00m'), findsOneWidget);
    });

    testWidgets('an armed alarm beats the schedule wake', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.sleepOperations.schedule = _schedule;
      app.device.alarmEpoch =
          DateTime(2026, 10, 9, 6, 30).millisecondsSinceEpoch ~/ 1000;
      await pumpHome(t, app);
      expect(find.text('on track for 5 cycles, 7h 30m'), findsOneWidget);
    });

    testWidgets('an alarm already past is ignored', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.sleepOperations.schedule = _schedule;
      app.device.alarmEpoch =
          DateTime(2026, 10, 8, 21, 0).millisecondsSinceEpoch ~/ 1000;
      await pumpHome(t, app);
      expect(find.text('on track for 5 cycles, 8h 00m'), findsOneWidget);
    });

    testWidgets('with nothing saved and nothing armed there is no estimate',
        (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await pumpHome(t, app);
      expect(find.text('No estimate'), findsOneWidget);
    });
  });

  group('unslept: the grey estimate', () {
    testWidgets('ring is ONE grey arc (track ink, no stage colours) filled to '
        'estimate / target', (t) async {
      await _pump(
        t,
        _unslept(schedule: _schedule, need: _min(540)),
      );
      final painter = _sleepPainter(t);
      expect(painter, isNot(isA<StageRing>()));
      final ring = painter as Ring;
      expect(ring.color, _p(t).ink3);
      expect(ring.v, closeTo(480 / 540, 1e-9));
      final stageColours = Hypnogram.cols(_p(t)).values;
      expect(stageColours.contains(ring.color), isFalse);
    });

    testWidgets('value is the estimate; sub is "on track for n cycles, xxh '
        'yym"', (t) async {
      await _pump(t, _unslept(schedule: _schedule));
      expect(find.text('8h 00m'), findsNWidgets(1));
      expect(find.text('on track for 5 cycles, 8h 00m'), findsOneWidget);
    });

    testWidgets('one cycle is singular', (t) async {
      await _pump(
        t,
        _unslept(schedule: _schedule),
        now: DateTime(2026, 10, 9, 5, 20),
      );
      expect(find.text('on track for 1 cycle, 1h 40m'), findsOneWidget);
    });

    testWidgets('an estimate has no percentage and no "(default)" label '
        'on screen', (t) async {
      await _pump(t, _unslept(schedule: _schedule));
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('next armed alarm sets the wake', (t) async {
      await _pump(
        t,
        _unslept(
          schedule: _schedule,
          alarm: DateTime(2026, 10, 9, 6, 30),
        ),
      );
      expect(find.text('on track for 5 cycles, 7h 30m'), findsOneWidget);
    });

    testWidgets('coach bedtime beats the schedule onset', (t) async {
      await _pump(
        t,
        _unslept(
          schedule: _schedule,
          bedtime: const Metric(
              value: 22 * 60 + 30, confidence: .7, tier: MetricTier.estimate),
        ),
      );
      expect(find.text('on track for 5 cycles, 8h 30m'), findsOneWidget);
    });

    testWidgets('schedule onset beats learned onset; learned alone still '
        'works', (t) async {
      await _pump(
        t,
        _unslept(schedule: _schedule, learnedOnset: 23 * 60 + 30),
      );
      expect(find.text('on track for 5 cycles, 8h 00m'), findsOneWidget);
      await _pump(
        t,
        _unslept(learnedOnset: 23 * 60 + 30, learnedWake: 7 * 60 + 30),
      );
      expect(find.text('on track for 5 cycles, 8h 00m'), findsOneWidget);
    });

    testWidgets('a user cycle length (hook) changes the cycle count',
        (t) async {
      final d = HomeData(
        sleepSchedule: _schedule,
        cycleLenMin: 100,
      );
      await _pump(t, d);
      expect(find.text('on track for 4 cycles, 8h 00m'), findsOneWidget);
    });

    testWidgets('the estimate depends only on the injected now — time passing '
        'in the test changes nothing', (t) async {
      await _pump(t, _unslept(schedule: _schedule));
      await t.pump(const Duration(hours: 3));
      expect(find.text('on track for 5 cycles, 8h 00m'), findsOneWidget);
    });

    testWidgets('spoken text carries the estimate sentence', (t) async {
      final h = t.ensureSemantics();
      await _pump(t, _unslept(schedule: _schedule));
      expect(
        find.bySemanticsLabel(
            RegExp(r'Sleep\. 8h 00m\. on track for 5 cycles, 8h 00m')),
        findsOneWidget,
      );
      h.dispose();
    });
  });

  group('unslept: no wake, no estimate', () {
    testWidgets('an honest absence and an empty ring — never a guessed time',
        (t) async {
      await _pump(
        t,
        _unslept(
          bedtime: const Metric(
              value: 1350, confidence: .7, tier: MetricTier.estimate),
          learnedOnset: 1380,
        ),
      );
      expect(find.text('No estimate'), findsOneWidget);
      expect(find.textContaining('on track'), findsNothing);
      final ring = _sleepPainter(t) as Ring;
      expect(ring.v, 0);
      expect(
        find.textContaining('no alarm or typical wake time',
            findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('the pipeline\'s own reason comes first', (t) async {
      await _pump(
        t,
        _unslept(
          sleepMin: const Metric(note: 'Last night is still being processed.'),
        ),
      );
      expect(
        find.textContaining('Last night is still being processed.',
            findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('RingTrio.has: an estimate is something to draw; nothing is '
        'not', (t) async {
      expect(
        RingTrio.has(
          HomeData(sleepSchedule: _schedule),
          now: _evening,
        ),
        isTrue,
      );
      expect(RingTrio.has(const HomeData(), now: _evening), isFalse);
    });
  });

  group('calibrating is unchanged', () {
    testWidgets('a baseline note still draws the dashed ring, even when an '
        'estimate could be made', (t) async {
      await _pump(
        t,
        _unslept(
          schedule: _schedule,
          sleepMin: const Metric(note: 'need_baseline:have=3,need=14'),
        ),
      );
      final p = _sleepPainter(t);
      expect(p, isA<DashedRing>());
      expect((p as DashedRing).segments, 14);
      expect(find.textContaining('on track'), findsNothing);
    });
  });
}
