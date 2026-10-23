// Import focus, UI side, part 3: what happens to screens that are ALREADY
// loaded when focus starts, revisions that arrive while paused, the Explorer's
// layout and import-only list, and the screens that read outside the main
// surfaces (naps, journal, wellness, nutrition, AI briefing).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/ai/briefing.dart' show BriefingPeriod;
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/read_paused.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/import_focus.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/ai_briefing.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/screens/naps.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/explorer_harness.dart' as ex;
import 'support/read_paused_fakes.dart';

Future<void> _settle(WidgetTester t, {int n = 40}) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<AppState> _pump(WidgetTester t, dynamic repo, Widget home,
    {CoachConfig? coach}) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo;
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<ThemeController>.value(
          value: ThemeController.seed(AppThemeChoice.light, Brightness.light)),
      ChangeNotifierProvider<LocaleController>.value(
          value: LocaleController.seed(null)),
      ChangeNotifierProvider<CoachConfig>.value(value: coach ?? CoachConfig()),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: home),
    ),
  ));
  await _settle(t);
  return app;
}

/// The Explorer's fake, paused the way the real repository pauses a series.
class _PausedExplorerRepo extends ex.ExplorerRepo {
  _PausedExplorerRepo({super.counts = const {}})
      : super(charts: {
          specOf('resting_hr').chartKey: [
            for (final d in ex.kWeek) ex.pt(d, 55),
          ],
        });
  final List<String> countCalls = [];

  @override
  Future<Map<String, int>> getSeriesCounts(List<String> keys) async {
    countCalls.add(keys.join(','));
    if (ImportFocus.active.value) throw const ReadPaused('import');
    return super.getSeriesCounts(keys);
  }

  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    if (ImportFocus.active.value) {
      chartCalls.add(metric);
      throw const ReadPaused('import');
    }
    return super.getChart(metric, from: from, to: to, signals: signals);
  }
}

void main() {
  setUp(resetFocus);
  tearDown(resetFocus);

  group('focus STARTS under an already-loaded screen', () {
    testWidgets('What changed: the history and the month grid go, the line '
        'takes their place', (t) async {
      final repo = FocusRepo();
      await _pump(t, repo, const WhatChangedScreen());
      expect(find.text('Usual for you'), findsOneWidget,
          reason: 'sanity: the month grid is on screen');

      startFocus();
      await _settle(t);

      expect(find.text('Usual for you'), findsNothing);
      expect(find.text(kPausedLine), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('metric detail, 30 days: the series goes, the line stays '
        'until focus ends, then ONE reload', (t) async {
      final repo = FocusRepo();
      final app =
          await _pump(t, repo, const MetricDetail('strain', initialRange: 30));
      expect(find.text(kPausedLine), findsNothing);

      startFocus();
      await _settle(t);
      expect(find.text(kPausedLine), findsOneWidget);

      final before = repo.reads.length;
      for (var i = 0; i < 5; i++) {
        app.bumpInsights();
        await _settle(t, n: 20);
      }
      expect(repo.reads.skip(before), isEmpty,
          reason: 'revisions while paused read nothing');

      final charts = repo.count('getChart');
      endFocus();
      app.bumpInsights();
      app.bumpInsights();
      await _settle(t);
      expect(find.text(kPausedLine), findsNothing);
      expect(repo.count('getChart'), charts + 1);
    });

    testWidgets('Explorer: the plot goes, revisions while paused read '
        'nothing, one reload after', (t) async {
      await ex.initPrefs();
      Prefs.setString(kExploreMetricsPref, 'resting_hr');
      addTearDown(ex.clearPrefs);
      final repo = _PausedExplorerRepo();
      final app = await _pump(
          t,
          repo,
          ExplorerView(
              today: ex.kToday, annotationLoader: (_, _) async => const []));
      expect(find.byKey(ExplorerView.plotKey), findsOneWidget);

      startFocus();
      await _settle(t);
      expect(find.byKey(ExplorerView.plotKey), findsNothing);
      expect(find.text(kPausedLine), findsOneWidget);
      expect(find.byKey(const ValueKey('explore-retry')), findsNothing);

      final calls = repo.chartCalls.length;
      for (var i = 0; i < 5; i++) {
        app.bumpInsights();
        await _settle(t, n: 20);
      }
      expect(repo.chartCalls.length, calls, reason: 'no reads while paused');

      endFocus();
      app.bumpInsights();
      app.bumpInsights();
      await _settle(t);
      expect(repo.chartCalls.length, calls + 1,
          reason: 'one reload, trailing revisions coalesced');
      expect(find.byKey(ExplorerView.plotKey), findsOneWidget);
    });
  });

  group('Explorer', () {
    Future<void> prime() async {
      await ex.initPrefs();
      Prefs.setString(kExploreMetricsPref, 'resting_hr');
      addTearDown(ex.clearPrefs);
    }

    testWidgets('import-only metrics are looked up again after focus ends',
        (t) async {
      await prime();
      startFocus();
      final repo = _PausedExplorerRepo(counts: {'spo2': 12});
      await ex.pumpExplorer(t, repo);
      expect(ex.pick('spo2'), findsNothing);

      endFocus();
      await ex.settle(t, done: () => false);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(ex.pick('spo2'), findsOneWidget,
          reason: 'the paused count read is retried once focus is over');
    });

    testWidgets('the paused chart keeps the chart\'s height: nothing below '
        'it moves', (t) async {
      await prime();
      final loaded = _PausedExplorerRepo();
      await ex.pumpExplorer(t, loaded);
      expect(find.byKey(ExplorerView.plotKey), findsOneWidget);
      final below = ex.pick('hrv');
      final loadedTop = t.getTopLeft(below);
      final rangeTop = t.getTopLeft(find.byKey(const ValueKey('explore-range:d30')));

      await t.pumpWidget(const SizedBox());
      startFocus();
      await ex.pumpExplorer(t, _PausedExplorerRepo());
      expect(find.text(kPausedLine), findsOneWidget);
      expect(t.getTopLeft(find.byKey(const ValueKey('explore-range:d30'))),
          rangeTop);
      expect(t.getTopLeft(ex.pick('hrv')), loadedTop,
          reason: 'the line sits in a slot as tall as the chart');
    });
  });

  group('screens outside the main surfaces', () {
    testWidgets('naps (an older day): quiet line, no uncaught ReadPaused',
        (t) async {
      startFocus();
      final repo = PausedRepo();
      await _pump(t, repo, NapsScreen(day: kDay2));
      expect(find.text(kPausedLine), findsOneWidget);
      expect(find.textContaining('ReadPaused'), findsNothing);
      final n = repo.reads.length;
      await _settle(t, n: 300);
      expect(repo.reads.length, n);
    });

    testWidgets('AI briefing: a paused read is not shown as raw text',
        (t) async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      final cfg = CoachConfig();
      await cfg.save(baseUrl: 'http://localhost:11434/v1', apiKey: null, model: 'm');
      startFocus();
      final repo = PausedRepo();
      await _pump(t, repo,
          const AiBriefingScreen(period: BriefingPeriod.morning), coach: cfg);
      await t.tap(find.text('Write one now'));
      await _settle(t);
      expect(find.textContaining('ReadPaused'), findsNothing);
      expect(find.textContaining('Could not write the briefing'), findsNothing);
      expect(find.text(kPendingLine), findsOneWidget);
    });

    testWidgets('journal compose (older day): loading paused is a quiet line',
        (t) async {
      SharedPreferences.setMockInitialValues({});
      startFocus();
      await _pump(t, PausedRepo(), JournalCompose(date: kDay2));
      expect(find.text(kPausedLine), findsOneWidget);
      expect(find.textContaining('ReadPaused'), findsNothing);
    });

    testWidgets('journal compose: Save while paused says so, and Save works '
        'again afterwards (_saving is reset)', (t) async {
      SharedPreferences.setMockInitialValues({});
      final repo = _SavingRepo();
      await _pump(t, repo, JournalCompose(date: kToday));
      startFocus();
      await t.tap(find.text('Save').first);
      await _settle(t);
      expect(find.text(kSavingLine), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      final tries = repo.metricReads;
      await t.tap(find.text('Save').first);
      await _settle(t);
      expect(repo.metricReads, tries + 1,
          reason: 'the button is live again, not stuck on _saving');

      endFocus();
      await t.tap(find.text('Save').first);
      await _settle(t);
      expect(repo.posted, isTrue);
    });
  });

  group('DB-backed tabs', () {
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_read_paused_entry_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> until(WidgetTester t, Finder f) async {
      for (var i = 0; i < 80 && f.evaluate().isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
    }

    for (final (name, screen) in <(String, Widget)>[
      ('nutrition', const NutritionScreen()),
      ('wellness', const WellnessScreen()),
    ]) {
      testWidgets('$name: a paused read is a quiet "today appears soon" line, '
          'not an uncaught exception', (t) async {
        startFocus(const {});
        await _pump(t, PausedRepo(), screen);
        await until(t, find.text(kPendingLine));
        expect(find.text(kPendingLine), findsOneWidget);
        expect(find.textContaining('ReadPaused'), findsNothing);
      });
    }
  });
}

class _SavingRepo extends LocalRepository {
  int metricReads = 0;
  bool posted = false;

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async {
    metricReads++;
    if (ImportFocus.active.value) throw const ReadPaused('import');
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      const [];
  @override
  Future<void> postJournalMetrics(
          String date, Map<String, JournalMetricValue> values) async =>
      posted = true;
  @override
  Future<void> postJournal(String date, List<String> t, String note) async =>
      posted = true;
}
