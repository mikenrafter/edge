// Import focus, UI side, round 3: the Explorer readout and annotation lane,
// a delayed trailing publish, latched paused flags, an atomic journal save,
// and two screens that waited forever (Body clock, Beats).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/read_paused.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/import_focus.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/screens/beats.dart';
import 'package:openstrap_edge/ui2/screens/circadian_detail.dart';
import 'package:openstrap_edge/ui2/screens/explorer.dart';
import 'package:openstrap_edge/ui2/screens/explorer_annotations.dart';
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

Future<AppState> _pump(WidgetTester t, LocalRepository repo, Widget home) async {
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
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: home),
    ),
  ));
  await _settle(t);
  return app;
}

class _ExRepo extends ex.ExplorerRepo {
  _ExRepo()
      : super(charts: {
          specOf('resting_hr').chartKey: [
            for (final d in ex.kWeek) ex.pt(d, 55),
          ],
        });

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

class _JournalRepo extends LocalRepository {
  int metricReads = 0;
  bool metricsPosted = false, journalPosted = false;
  void Function()? onJournalRead;

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async {
    metricReads++;
    if (ImportFocus.active.value) throw const ReadPaused('import');
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async {
    onJournalRead?.call();
    if (ImportFocus.active.value) throw const ReadPaused('import');
    return const [];
  }

  @override
  Future<void> postJournalMetrics(
      String date, Map<String, JournalMetricValue> values) async {
    // The real one reads the field specs first: paused while focus is on.
    if (ImportFocus.active.value) throw const ReadPaused('import');
    metricsPosted = true;
  }

  @override
  Future<void> postJournal(String date, List<String> t, String note) async =>
      journalPosted = true;
}

/// Real-time waits: the stored-result read goes to sqflite on another isolate.
Future<void> _real(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetFocus();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  tearDown(resetFocus);

  group('Explorer, paused', () {
    Future<(_ExRepo, AppState)> warm(WidgetTester t,
        {List<ChartAnnotation> items = const []}) async {
      await ex.initPrefs();
      Prefs.setString(kExploreMetricsPref, 'resting_hr');
      addTearDown(ex.clearPrefs);
      final repo = _ExRepo();
      final app = await _pump(
          t,
          repo,
          ExplorerView(
              today: ex.kToday, annotationLoader: (_, _) async => items));
      return (repo, app);
    }

    testWidgets('the readout shows no numbers and the plot cannot be '
        'scrubbed', (t) async {
      await warm(t);
      await ex.scrubAt(t, .97);
      expect(ex.readoutText(t, 'Resting heart rate'), contains('55'),
          reason: 'sanity: scrubbing reads a value');

      startFocus();
      await _settle(t);

      final cell = ex.readoutValue('Resting heart rate');
      final text = cell.evaluate().isEmpty ? '' : ex.readoutText(t, 'Resting heart rate');
      expect(text, isNot(matches(RegExp(r'\d'))),
          reason: 'cached numbers must not survive the pause: "$text"');
      final plot = find.text(kPausedLine);
      await t.tapAt(t.getCenter(plot));
      await t.pump();
      final after = ex.readoutValue('Resting heart rate').evaluate().isEmpty
          ? ''
          : ex.readoutText(t, 'Resting heart rate');
      expect(after, isNot(matches(RegExp(r'\d'))));
    });

    testWidgets("with annotations, the lane's height is kept", (t) async {
      final noon = localDayStartSec('2026-10-03')! + 12 * 3600;
      final items = [
        ChartAnnotation(
            id: 'w',
            kind: AnnotationKind.water,
            at: noon.toDouble(),
            label: 'Drank water'),
      ];
      await warm(t, items: items);
      expect(find.byKey(ChartAnnotationLane.laneKey), findsOneWidget,
          reason: 'sanity: the lane is there');
      double slot() =>
          t.getTopLeft(ex.pick('hrv')).dy -
          t.getTopLeft(find.text('Normalised')).dy;
      final loaded = slot();

      startFocus();
      await _settle(t);
      expect(find.text(kPausedLine), findsOneWidget);
      expect(slot(), loaded,
          reason: 'the annotation lane keeps its reserved height');
    });

    testWidgets('a publish 1.5 s after focus ends does not reload twice',
        (t) async {
      final (repo, app) = await warm(t);
      startFocus();
      await _settle(t);
      final calls = repo.chartCalls.length;

      endFocus();
      await _settle(t, n: 5);
      await t.pump(const Duration(milliseconds: 1500));
      app.bumpInsights(); // the coalescer's trailing publish
      await _settle(t);
      expect(repo.chartCalls.length, calls + 1,
          reason: 'one reload; the delayed publish announces what it read');
    });
  });

  testWidgets('Home: a publish 1.5 s after focus ends does not reload twice',
      (t) async {
    final repo = FocusRepo();
    final app = await _pump(t, repo, const HomeScreen(hour: 9));
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    startFocus();
    await _settle(t);
    final before = repo.count('getDayOverview', kDay2);

    endFocus();
    await _settle(t, n: 5);
    await t.pump(const Duration(milliseconds: 1500));
    app.bumpInsights();
    await _settle(t);
    expect(repo.count('getDayOverview', kDay2), before + 1);
  });

  group('journal compose', () {
    testWidgets('a paused load reloads once when focus ends', (t) async {
      startFocus();
      final repo = _JournalRepo();
      await _pump(t, repo, JournalCompose(date: kDay2));
      expect(find.text(kPausedLine), findsOneWidget);
      final reads = repo.metricReads;

      endFocus();
      await _settle(t);
      expect(find.text(kPausedLine), findsNothing);
      expect(repo.metricReads, reads + 1);
    });

    testWidgets('Save while paused is refused up front: nothing read, '
        'nothing written', (t) async {
      final repo = _JournalRepo();
      await _pump(t, repo, JournalCompose(date: kToday));
      final reads = repo.metricReads;
      startFocus();
      await t.tap(find.text('Save').first);
      await _settle(t);
      expect(find.text(kSavingLine), findsOneWidget);
      expect(repo.metricReads, reads);
      expect(repo.metricsPosted || repo.journalPosted, isFalse);
    });

    testWidgets('focus starting between the reads and the write writes '
        'NOTHING (no half-saved day)', (t) async {
      final repo = _JournalRepo();
      await _pump(t, repo, JournalCompose(date: kToday));
      // The tags read comes after the metrics read: focus starts there.
      repo.onJournalRead = startFocus;
      await t.tap(find.text('Save').first);
      await _settle(t);
      expect(repo.metricsPosted, isFalse);
      expect(repo.journalPosted, isFalse,
          reason: 'both merges are prepared before either write');
      expect(find.text(kSavingLine), findsOneWidget);
    });
  });

  group('screens on the real database', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_read_paused_round3_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });
    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    testWidgets('a paused day reloads once when focus ends', (t) async {
      startFocus();
      final repo = FocusRepo();
      await _pump(t, repo, NapsScreen(day: kDay2));
      expect(find.text(kPausedLine), findsOneWidget);
      final days = repo.count('availableDays');

      endFocus();
      for (var i = 0; i < 40; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
      expect(find.text(kPausedLine), findsNothing);
      expect(repo.count('availableDays'), days + 1);
    });

    testWidgets('Body clock: a null artifact during focus is the paused '
        'line, not a spinner; one reload after', (t) async {
      startFocus();
      final repo = FocusRepo();
      await _pump(t, repo, const CircadianDetail());
      await _real(t);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'no endless spinner');
      expect(find.text(kPausedLine), findsOneWidget);

      final sigs = repo.count('artifactSignature');
      endFocus();
      await _real(t);
      expect(find.text(kPausedLine), findsNothing);
      expect(repo.count('artifactSignature'), sigs + 1,
          reason: 'read once when focus ends');
    });

  });

  group('screens that waited forever', () {
    testWidgets("Beats: an interrupted shell read is the paused line, not "
        "\"Reading the night's beats\" forever; one reload after", (t) async {
      final repo = FocusRepo();
      repo.onRead = (m) {
        if (m == 'getDayHrv') startFocus(); // focus begins mid-load
      };
      await _pump(t, repo, const Beats());
      await _settle(t, n: 100);
      expect(find.textContaining("Reading the night's beats"), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(kPausedLine), findsOneWidget);

      repo.onRead = null;
      final reads = repo.count('getDayHrv');
      endFocus();
      await _settle(t, n: 100);
      expect(find.text(kPausedLine), findsNothing);
      expect(repo.count('getDayHrv'), reads + 1);
    });
  });
}
