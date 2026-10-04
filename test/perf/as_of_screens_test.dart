// 8AG-perf P1b: "Show the last calculated data everywhere while new data is
// being calculated, with an 'As of <time>' label."
//
// ASSUMED API (all new; see recalc_state_test.dart / as_of_label_test.dart /
// last_result_cache_test.dart for their shapes):
//   AppState.recalc, AppState.debugSetRecalc(RecalcState), RecalcState,
//   AsOfLabel (key 'as-of-label' on its Text), LastResultCache.instance.
//
// READER SHAPES the screens consume (fixtures in support/perf_fakes.dart):
//   getToday        status.activity_computed_at / status.overnight_computed_at
//   getDaySleepV2   'computed_at' (epoch ms)            -> SleepDetail
//   getDayHrv       'computed_at'                       -> Beats
//   getDayStress    'computed_at'                       -> Wellness (Mind tab)
//   getChart        'computed_at' (max over rows read)  -> MetricDetail
//
// SCREEN RULES pinned here:
//   * label = asOfFor(shownDay, computedAt, recalc); it listens to
//     AppState.recalc (ValueListenableBuilder), no DB re-read to appear.
//   * the old value stays on screen (no spinner) while the label is up.
//   * the label clears when the fresh result has LANDED: day removed from
//     recalc AND the reload committed. (Removing the day alone, with the
//     screen still holding the old row, keeps the label: the old row must not
//     pass as fresh.)
//   * computed-on-open screens (MetricDetail journal insights, Wellness
//     JournalFindings, Beats corrected RR, past Workout detail) cache their
//     last good result in LastResultCache.instance: a re-open renders it at
//     once with AsOfLabel(cachedAt), recomputes in the background, then swaps
//     and clears the label. Errors are never cached.
//   * Workout detail is covered structurally (the harness needs the private
//     history row + sqflite): workout_screen.dart / activity/summary.dart
//     must use LastResultCache and AsOfLabel.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/recalc_state.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/p3_support.dart';
import 'support/p3_warmer_support.dart';

final _label = find.byKey(const ValueKey('as-of-label'));

RecalcState _recalc(Iterable<String> days, {bool crossDay = false}) =>
    RecalcState(
        days: {...days}, passStartedAt: DateTime.now(), crossDay: crossDay);

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(390 * 3, 2600 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

AppState _app(LocalRepository repo) {
  final a = AppState.forTesting();
  a.repo = repo;
  addTearDown(a.dispose);
  return a;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The screens now write their last result through to `last_result`; a private
  // file keeps that away from the default database other test files share.
  const dbName = 'openstrap_perf_as_of_screens_test.db';
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = dbName;
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), dbName));
  });
  tearDownAll(() async {
    await LastResultCache.instance.flush();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), dbName));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LastResultCache.instance.clear();
  });

  // ── Home ──────────────────────────────────────────────────────────────────
  group('Home', () {
    testWidgets('day recalculating with a prior row: label + old value, no '
        'spinner', (t) async {
      _tall(t);
      final app = _app(HomeRepo(homeBundle(
          overnightAt: todayAtMs(7, 10), activityAt: todayAtMs(8, 42))));
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t);
      expect(_label, findsNothing, reason: 'nothing is recalculating yet');
      expect(find.text('70'), findsOneWidget);

      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();

      expect(find.text('70'), findsOneWidget, reason: 'the old value stays');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Recovery / sleep come off the OVERNIGHT row, strain / activity off the
      // ACTIVITY row: each card says when ITS row was computed.
      expect(find.text('As of 07:10'), findsWidgets);
      expect(find.text('As of 08:42'), findsWidgets);
    });

    testWidgets('the label appears without a DB re-read', (t) async {
      _tall(t);
      final repo = HomeRepo(homeBundle(
          overnightAt: todayAtMs(7, 10), activityAt: todayAtMs(8, 42)));
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t);
      final reads = repo.reads;
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();
      await t.pump();
      expect(_label, findsWidgets);
      expect(repo.reads, reads);
    });

    testWidgets('the day finishes: label gone, new value shown', (t) async {
      _tall(t);
      final repo = HomeRepo(homeBundle(
          overnightAt: todayAtMs(7, 10), activityAt: todayAtMs(8, 42)));
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t);
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();
      expect(_label, findsWidgets);

      // The pass commits the day: new row, then the day leaves the set and the
      // revision moves (the order the engine + AppState produce).
      repo.today = homeBundle(
          readiness: 75,
          overnightAt: todayAtMs(9, 15),
          activityAt: todayAtMs(9, 15));
      app.debugSetRecalc(RecalcState.idle);
      app.bumpInsights();
      await settle(t);

      expect(find.text('75'), findsOneWidget);
      expect(find.text('70'), findsNothing);
      expect(_label, findsNothing);
    });

    testWidgets('the day leaves the set BEFORE the reload lands: the old row '
        'must not pass as fresh', (t) async {
      _tall(t);
      final repo = HomeRepo(homeBundle(
          overnightAt: todayAtMs(7, 10), activityAt: todayAtMs(8, 42)));
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t);
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();

      app.debugSetRecalc(RecalcState.idle); // removed, reload not here yet
      await t.pump();
      expect(find.text('70'), findsOneWidget);
      expect(_label, findsWidgets,
          reason: 'still the old row: the label stays until the new one lands');

      repo.today = homeBundle(
          readiness: 75,
          overnightAt: todayAtMs(9, 15),
          activityAt: todayAtMs(9, 15));
      app.bumpInsights();
      await settle(t);
      expect(find.text('75'), findsOneWidget);
      expect(_label, findsNothing);
    });

    testWidgets('no prior row: no label, today\'s existing building state',
        (t) async {
      _tall(t);
      final app = _app(HomeRepo(homeBundle(withDaily: false)));
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t);
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();
      expect(_label, findsNothing,
          reason: 'no computed_at to stand behind: never make a time up');
      expect(find.textContaining('As of'), findsNothing);
    });

    testWidgets('yesterday\'s overnight row is never shown as today\'s',
        (t) async {
      _tall(t);
      final app = _app(HomeRepo(homeBundle(
        heldOver: true,
        overnightDay: yesterdayId,
        overnightAt: daysAgoAtMs(1, 7, 10),
        activityAt: todayAtMs(8, 42),
      )));
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t);
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();

      // The held-over night's numbers are refused in the today slot (existing
      // rule) and the label must not sneak them back in as "As of 07:10".
      expect(find.text('70'), findsNothing);
      expect(find.text('As of 07:10'), findsNothing);
      // Today's own activity row is a different matter.
      expect(find.text('As of 08:42'), findsWidgets);
    });

    testWidgets('only a day that is NOT on screen recalculates: no label',
        (t) async {
      _tall(t);
      final app = _app(HomeRepo(homeBundle(
          overnightAt: todayAtMs(7, 10), activityAt: todayAtMs(8, 42))));
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t);
      app.debugSetRecalc(_recalc([yesterdayId]));
      await t.pump();
      expect(_label, findsNothing);
    });
  });

  // ── SleepDetail ───────────────────────────────────────────────────────────
  group('SleepDetail', () {
    testWidgets('label while its night is recalculating, old night kept',
        (t) async {
      _tall(t);
      final app = _app(SleepRepo(computedAt: todayAtMs(8, 42)));
      await t.pumpWidget(perfApp(app, SleepDetail(day: yesterdayId)));
      await settle(t);
      expect(find.text('Total sleep'), findsOneWidget);
      expect(_label, findsNothing);

      app.debugSetRecalc(_recalc([yesterdayId]));
      await t.pump();
      expect(find.text('As of 08:42'), findsOneWidget);
      expect(find.text('Total sleep'), findsOneWidget);

      app.debugSetRecalc(RecalcState.idle);
      app.bumpInsights();
      await settle(t);
      expect(_label, findsNothing);
    });

    testWidgets('a different day recalculating, or no computed_at: no label',
        (t) async {
      _tall(t);
      final app = _app(SleepRepo(computedAt: todayAtMs(8, 42)));
      await t.pumpWidget(perfApp(app, SleepDetail(day: yesterdayId)));
      await settle(t);
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();
      expect(_label, findsNothing);

      // A fresh screen for the second app: the same tree position would keep
      // the first app's State (and its loaded night) alive under the new one.
      await t.pumpWidget(const SizedBox());
      final bare = _app(SleepRepo());
      await t.pumpWidget(perfApp(bare, SleepDetail(day: yesterdayId)));
      await settle(t);
      bare.debugSetRecalc(_recalc([yesterdayId]));
      await t.pump();
      expect(_label, findsNothing);
    });
  });

  // ── MetricDetail ──────────────────────────────────────────────────────────
  group('MetricDetail', () {
    testWidgets('label while today recalculates (series computed_at)',
        (t) async {
      _tall(t);
      final app = _app(MetricRepo(computedAt: todayAtMs(8, 42)));
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t);
      expect(_label, findsNothing);
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();
      expect(find.text('As of 08:42'), findsOneWidget);
      app.debugSetRecalc(RecalcState.idle);
      app.bumpInsights();
      await settle(t);
      expect(_label, findsNothing);
    });

    testWidgets('journal insights: re-open shows the cached result at once, '
        'then swaps and clears', (t) async {
      _tall(t);
      final repo = MetricRepo();
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t);
      expect(repo.insightsCalls, 1);
      expect(_label, findsNothing, reason: 'first open: nothing cached yet');

      // Leave and come back while the recompute is slow.
      await t.pumpWidget(const SizedBox());
      repo.insightsGate = Completer();
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 2, reason: 'recomputed in the background');
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'the cached result renders instead of a spinner');
      expect(_label, findsWidgets);
      expect(find.textContaining('As of'), findsWidgets);

      repo.insightsGate!.complete(const {'insights': []});
      await settle(t);
      expect(_label, findsNothing, reason: 'fresh result replaces the cache');
    });

    testWidgets('an error is never cached: the next open has no label',
        (t) async {
      _tall(t);
      final repo = MetricRepo()..insightsThrow = true;
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t);

      await t.pumpWidget(const SizedBox());
      repo
        ..insightsThrow = false
        ..insightsGate = Completer();
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t, n: 20);
      expect(_label, findsNothing);
      repo.insightsGate!.complete(const {'insights': []});
      await settle(t);
    });
  });

  // ── Wellness ──────────────────────────────────────────────────────────────
  group('Wellness', () {
    testWidgets('Mind tab: label while today recalculates (stress computed_at)',
        (t) async {
      _tall(t);
      ignoreFrameworkNoise();
      final app = _app(WellnessRepo(computedAt: todayAtMs(8, 42)));
      await t.pumpWidget(perfApp(app, const WellnessScreen()));
      await settle(t);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(_label, findsNothing);
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();
      expect(find.text('As of 08:42'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('insights + weekday effects: cached on re-open, then swapped',
        (t) async {
      _tall(t);
      final repo = WellnessRepo();
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const JournalFindings()));
      await settle(t);
      expect(repo.insightsCalls, 1);
      expect(_label, findsNothing);

      await t.pumpWidget(const SizedBox());
      repo.insightsGate = Completer();
      await t.pumpWidget(perfApp(app, const JournalFindings()));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 2);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(_label, findsWidgets);

      repo.insightsGate!.complete(const {'numeric_insights': []});
      await settle(t);
      expect(_label, findsNothing);
    });

    testWidgets('an error is never cached', (t) async {
      _tall(t);
      final repo = WellnessRepo()..insightsThrow = true;
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const JournalFindings()));
      await settle(t);
      await t.pumpWidget(const SizedBox());
      repo
        ..insightsThrow = false
        ..insightsGate = Completer();
      await t.pumpWidget(perfApp(app, const JournalFindings()));
      await settle(t, n: 20);
      expect(_label, findsNothing);
      repo.insightsGate!.complete(const {'numeric_insights': []});
      await settle(t);
    });
  });

  // ── Beats ─────────────────────────────────────────────────────────────────
  group('Beats', () {
    testWidgets('label while the night is recalculating (getDayHrv '
        'computed_at)', (t) async {
      _tall(t);
      final app = _app(BeatsRepo(computedAt: todayAtMs(8, 42)));
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t);
      expect(_label, findsNothing);
      app.debugSetRecalc(_recalc([todayId]));
      await t.pump();
      expect(find.text('As of 08:42'), findsOneWidget);
      app.debugSetRecalc(RecalcState.idle);
      await t.pump();
    });

    final key = p3Beats(todayId);
    final night = {
      'nn': [for (var i = 0; i < 400; i++) 880 + (i % 37) * 3.0],
      'raw_beats': 412,
      'clean_fraction': .97,
    };

    testWidgets('corrected RR: re-open renders the stored night at once, the '
        'warm is requested in the background, then it swaps', (t) async {
      _tall(t);
      final repo = P3BeatsRepo()..sigs[key] = 'B2';
      LastResultCache.instance.put<Map<String, dynamic>>(key, night, sig: 'B1');
      final src = FakeArtifactSource()
        ..sigs[key] = 'B2'
        ..results[key] = night
        ..gates[key] = Completer<void>();
      final app = _app(repo)..debugArtifactSource = src;
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t, n: 20);
      expect(src.computes(key), 1, reason: 'warmed in the background');
      expect(repo.beatsCalls, 0, reason: 'never computed by the screen');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(_label, findsWidgets);

      src.gates[key]!.complete();
      await settle(t);
      expect(_label, findsNothing);
    });

    testWidgets('a failed warm is never cached: no label on the next open',
        (t) async {
      _tall(t);
      await t.runAsync(LastResultCache.instance.clear);
      final repo = P3BeatsRepo()..sigs[key] = 'B1';
      final src = FakeArtifactSource()
        ..sigs[key] = 'B1'
        ..computeThrows.add(key);
      final app = _app(repo)..debugArtifactSource = src;
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t);
      await t.pumpWidget(const SizedBox());
      src.computeThrows.clear();
      src.gates[key] = Completer<void>();
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t, n: 20);
      expect(_label, findsNothing);
      src.gates[key]!.complete();
      await settle(t);
    });
  });

  // ── Workout (past detail) ─────────────────────────────────────────────────
  group('Workout detail (structural)', () {
    test('opening a past workout uses the cache and shows the label', () {
      final w = File('lib/ui2/screens/workout_screen.dart').readAsStringSync();
      final s = File('lib/ui2/activity/summary.dart').readAsStringSync();
      expect(w, contains('LastResultCache'),
          reason: 'getWorkout is computed on open; re-open must not wait');
      expect('$w\n$s', contains('AsOfLabel'));
      expect(w, contains("keyOf('workout'"));
    });
  });
}
