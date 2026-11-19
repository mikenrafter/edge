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
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

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
      expect(repo.count('getChart'), inInclusiveRange(charts + 1, charts + 2),
          reason: 'the focus-end reload plus at most one trailing');
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
      final loadReads = repo.metricReads;
      startFocus();
      await t.tap(find.text('Save').first);
      await _settle(t);
      expect(find.text(kSavingLine), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      expect(repo.metricReads, loadReads, reason: 'refused up front: nothing read');
      expect(repo.posted, isFalse);

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
