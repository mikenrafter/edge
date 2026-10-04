// 8AI G1 (red first): the last good result of each slow read SURVIVES A
// RESTART and renders under the "As of" label on the next open.
//
// "Restart" here is `LastResultCache.instance.clearMemory()`: the in-memory
// LRU (all the 8AG-P1b cache was) is gone, the sqflite file is not.
//
// ASSUMED API: LastResultCache.clearMemory(), flush() and the table as in
// g1_last_result_cache_persist_test.dart. What each screen persists is the
// REPOSITORY-level JSON it builds from, not a widget object:
//   MetricDetail      key 'journal_insights|90d'      getJournalInsights('90d')
//   Wellness findings key 'journal_insights|90d'      getJournalInsights('90d')
//                     + 'weekday_effect'              + getWeekdayEffect()
// (8AG-perf P3: one key per artifact, shared by the screens that read it; was
// 'metric_insights|<metric>', 'wellness_insights' and 'wellness_weekday'.)
//   Beats             key 'beats|<day>...'            the corrected-RR read
//                                                     (nn, rawBeats, cleanFraction)
// The exact key suffixes and whether Wellness uses one row or two are the
// implementer's; tests find rows by their key PREFIX and by a marker value
// carried inside the repository map.
//
// Per screen:
//   1. first open, nothing stored: loads and persists (a row exists, computed_at
//      is when it was computed);
//   2. simulated restart + reopen with the slow read pending: the persisted
//      result is on screen with the As-of label, no spinner, the read is
//      started again in the background;
//   3. the fresh result replaces it on screen, clears the label, and replaces
//      the row (the new payload, a later-or-equal computed_at);
//   4. an error is never persisted: after a failed read there is no row, and
//      the next (restarted) open shows no label.
//
// Today every test fails: there is no table, and the restarted open shows a
// spinner instead of a result.
//
// Workout detail is structural in g1_calc_screens_shell_test.dart.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../perf/support/perf_fakes.dart';
import 'support/g1_db.dart';

const _db = 'openstrap_fix8ai_g1_persisted.db';
final _label = find.byKey(const ValueKey('as-of-label'));
final _spinner = find.byType(CircularProgressIndicator);

AppState _app(LocalRepository repo) {
  final a = AppState.forTesting();
  a.repo = repo;
  addTearDown(a.dispose);
  return a;
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(390 * 3, 2600 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _fresh(WidgetTester t) async {
  await t.runAsync(() => g1FreshDb(_db));
  LastResultCache.instance.clear();
}

/// Land every pending write-through, then forget the in-memory cache.
Future<void> _restart(WidgetTester t) async {
  await t.runAsync(() => LastResultCache.instance.flush());
  LastResultCache.instance.clearMemory();
}

Future<List<Map<String, Object?>>> _rows(WidgetTester t, String prefix) async {
  final all = await t.runAsync(g1LastResultRows) ?? const [];
  return [
    for (final r in all)
      if ((r['key'] as String).startsWith(prefix)) r,
  ];
}

bool _anyPayloadHas(List<Map<String, Object?>> rows, String needle) =>
    rows.any((r) => (r['payload_json'] as String).contains(needle));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() => g1DropDb(_db));

  // ── MetricDetail ──────────────────────────────────────────────────────────
  group('MetricDetail journal insights', () {
    const first = {'insights': [], 'fix8ai_marker': 'first-run'};
    const second = {'insights': [], 'fix8ai_marker': 'second-run'};

    testWidgets('persisted, shown after a restart under As-of, then replaced',
        (t) async {
      _tall(t);
      await _fresh(t);
      final repo = MetricRepo();
      final app = _app(repo);
      // Make the first run's insights carry the marker.
      repo.insightsGate = Completer()..complete(first);
      final before = DateTime.now().millisecondsSinceEpoch;
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t);
      await _restart(t);

      final rows = await _rows(t, 'journal_insights');
      expect(rows, hasLength(1), reason: 'one row for this metric');
      expect(_anyPayloadHas(rows, 'first-run'), isTrue,
          reason: 'the repository map itself is what is stored');
      expect(rows.single['computed_at'] as int,
          inInclusiveRange(before - 1000, DateTime.now().millisecondsSinceEpoch),
          reason: 'computed_at is when it was computed');

      await t.pumpWidget(const SizedBox());
      repo.insightsGate = Completer();
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 2, reason: 'recomputed in the background');
      expect(_spinner, findsNothing,
          reason: 'the stored result renders instead of a spinner');
      expect(_label, findsWidgets);
      expect(find.textContaining('As of'), findsWidgets);

      repo.insightsGate!.complete(second);
      await settle(t);
      expect(_label, findsNothing, reason: 'fresh result clears the label');
      await t.runAsync(() => LastResultCache.instance.flush());
      final after = await _rows(t, 'journal_insights');
      expect(_anyPayloadHas(after, 'second-run'), isTrue);
      expect(_anyPayloadHas(after, 'first-run'), isFalse,
          reason: 'the fresh result replaced the row');
    });

    testWidgets('an error is never persisted', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = MetricRepo()..insightsThrow = true;
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t);
      await _restart(t);
      expect(await _rows(t, 'journal_insights'), isEmpty);

      await t.pumpWidget(const SizedBox());
      repo
        ..insightsThrow = false
        ..insightsGate = Completer();
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t, n: 20);
      expect(_label, findsNothing, reason: 'nothing stored, so no As-of');
      repo.insightsGate!.complete(const {'insights': []});
      await settle(t);
    });
  });

  // ── Wellness: What you log ────────────────────────────────────────────────
  group('Wellness insights + weekday effects', () {
    testWidgets('persisted, shown after a restart under As-of, then replaced',
        (t) async {
      _tall(t);
      await _fresh(t);
      final repo = WellnessRepo()
        ..insights = const {'numeric_insights': [], 'fix8ai_marker': 'w-first'};
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const JournalFindings()));
      await settle(t);
      await _restart(t);
      final rows = await _rows(t, 'journal_insights');
      expect(rows, isNotEmpty);
      expect(_anyPayloadHas(rows, 'w-first'), isTrue);

      await t.pumpWidget(const SizedBox());
      repo.insightsGate = Completer();
      await t.pumpWidget(perfApp(app, const JournalFindings()));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 2);
      expect(_spinner, findsNothing);
      expect(_label, findsWidgets);

      repo.insightsGate!
          .complete(const {'numeric_insights': [], 'fix8ai_marker': 'w-second'});
      await settle(t);
      expect(_label, findsNothing);
      await t.runAsync(() => LastResultCache.instance.flush());
      final after = await _rows(t, 'journal_insights');
      expect(_anyPayloadHas(after, 'w-second'), isTrue);
      expect(_anyPayloadHas(after, 'w-first'), isFalse);
    });

    testWidgets('an error is never persisted', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = WellnessRepo()..insightsThrow = true;
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const JournalFindings()));
      await settle(t);
      await _restart(t);
      expect(await _rows(t, 'journal_insights'), isEmpty);

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
  group('Beats corrected RR', () {
    testWidgets('persisted, shown after a restart under As-of, then replaced',
        (t) async {
      _tall(t);
      await _fresh(t);
      final repo = BeatsRepo()
        ..nn = [for (var i = 0; i < 400; i++) 913.25 + (i % 11)];
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t);
      await _restart(t);
      final rows = await _rows(t, 'beats');
      expect(rows, isNotEmpty);
      expect(_anyPayloadHas(rows, '913.25'), isTrue,
          reason: 'the corrected-RR read (the nn series) is what is stored');
      for (final r in rows) {
        expect(() => jsonDecode(r['payload_json'] as String), returnsNormally);
      }

      await t.pumpWidget(const SizedBox());
      repo
        ..nn = [for (var i = 0; i < 400; i++) 777.5 + (i % 13)]
        ..beatsGate = Completer();
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t, n: 20);
      expect(repo.beatsCalls, 2);
      expect(_spinner, findsNothing,
          reason: 'the persisted night renders instead of a spinner');
      expect(_label, findsWidgets);

      repo.beatsGate!.complete();
      await settle(t);
      expect(_label, findsNothing);
      await t.runAsync(() => LastResultCache.instance.flush());
      final after = await _rows(t, 'beats');
      expect(_anyPayloadHas(after, '777.5'), isTrue);
      expect(_anyPayloadHas(after, '913.25'), isFalse);
    });

    testWidgets('an error is never persisted', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = BeatsRepo()..beatsThrow = true;
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t);
      await _restart(t);
      expect(await _rows(t, 'beats'), isEmpty);

      await t.pumpWidget(const SizedBox());
      repo
        ..beatsThrow = false
        ..beatsGate = Completer();
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t, n: 20);
      expect(_label, findsNothing);
      repo.beatsGate!.complete();
      await settle(t);
    });
  });
}
