// Import focus, UI side, round 3: the Explorer readout and annotation lane,
// a delayed trailing publish, latched paused flags, an atomic journal save,
// and two screens that waited forever (Body clock, Beats).
import 'dart:async';

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
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/read_paused_fakes.dart';
import 'support/as_of_recalc_fakes.dart' show settle;

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



  group('Home, around the end of focus', () {
    Future<(FocusRepo, AppState)> pausedOnDay2(WidgetTester t) async {
      final repo = FocusRepo();
      final app = await _pump(t, repo, const HomeScreen(hour: 9));
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      await t.tap(find.bySemanticsLabel('Previous day'));
      await _settle(t);
      startFocus();
      await _settle(t);
      return (repo, app);
    }

    testWidgets('a burst of revisions around the end: the focus-end reload '
        'plus at most ONE trailing', (t) async {
      final (repo, app) = await pausedOnDay2(t);
      final before = repo.count('getDayOverview', kDay2);
      endFocus();
      for (var i = 0; i < 6; i++) {
        app.bumpInsights();
      }
      await _settle(t);
      final n = repo.count('getDayOverview', kDay2) - before;
      expect(n, inInclusiveRange(1, 2), reason: 'reads for the burst: $n');
    });

    testWidgets('NEW data published 1.5 s after the end is shown (nothing is '
        'dropped)', (t) async {
      final (repo, app) = await pausedOnDay2(t);
      endFocus();
      await _settle(t);
      expect(find.text('33'), findsOneWidget);

      repo.overview[kDay2] = 44; // a sync / workout save right after the import
      await t.pump(const Duration(milliseconds: 1500));
      app.bumpInsights();
      await _settle(t);
      expect(find.text('44'), findsOneWidget,
          reason: 'the revision carried new data: it must be read');
      expect(find.text('33'), findsNothing);
    });

    testWidgets('idle revisions reload once each', (t) async {
      final (repo, app) = await pausedOnDay2(t);
      endFocus();
      await _settle(t);
      final base = repo.count('getDayOverview', kDay2);
      for (var i = 1; i <= 3; i++) {
        app.bumpInsights();
        await _settle(t);
        expect(repo.count('getDayOverview', kDay2), base + i);
      }
    });
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
      // The real SQLite read must settle; a fixed 400 ms sleep races under
      // the sharded gate. Keep the exact one-reload assertion below.
      await settle(t, until: () => find.text(kPausedLine).evaluate().isEmpty,
          what: 'Naps resumes after import focus');
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
    testWidgets('Body clock outside focus: no artifact yet is pending, '
        'never an empty "0 nights" model', (t) async {
      final repo = FocusRepo();
      await _pump(t, repo, const CircadianDetail());
      await _real(t);
      expect(find.text(kPausedLine), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byWidgetPredicate((w) => w is PendingContent && w.pending), findsWidgets,
          reason: 'still waiting for the warm: a debounced placeholder');
    });

    testWidgets('Beats: beats accepted on a retry of the same night clear '
        'the failed flag, and the Poincare panel shows', (t) async {
      final repo = FocusRepo();
      final app = await _pump(t, repo, const Beats());
      await _real(t);
      const title = 'Every beat against the one before it';
      expect(find.text(title), findsNothing,
          reason: 'sanity: no beats yet, panel left out');

      final day = repo.reads
          .firstWhere((r) => r.startsWith('getDayHrv:'))
          .split(':')[1];
      final key = LastResultCache.keyOf('beats', [day]);
      repo.sig = 's1';
      LastResultCache.instance.put<Map<String, dynamic>>(
          key,
          {
            'nn': [800.0, 810.0, 790.0, 805.0],
            'raw_beats': 4,
            'clean_fraction': 1.0,
          },
          sig: 's1');
      app.bumpInsights(); // the warm landed: the same night is read again
      await _real(t);
      expect(find.text(title), findsOneWidget);
    });

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
