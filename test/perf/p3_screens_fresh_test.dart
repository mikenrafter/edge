// 8AG-perf P3-A: the screens trust a FRESH stored artifact.
//
// 8AI made every slow screen show its last result under an "As of" label and
// then recompute ON OPEN, every open. P3: a stored result whose input
// signature still equals the current one is fresh, so it is shown as is, with
// no recompute and no label. A stale or missing one behaves exactly as before
// (show stored with "As of" + recompute once), and the recompute is stored with
// the signature the screen read BEFORE it ran.
//
// ASSUMED API:
//   * LastResultCache.loadArtifact / put(sig:) / CachedResult.sig and the
//     `last_result.input_sig` column: see p3_artifact_cache_test.dart.
//   * LocalRepository.artifactSignature(String key) -> Future<String?>
//     (default null => never fresh): see support/p3_support.dart. The fakes
//     here answer it from a map and record what they were asked.
//   * The four screens read their slow data through
//         LastResultCache.instance.loadArtifact(
//           key, () => <the same loader as today>,
//           signature: () => repo.artifactSignature(key), onLast: <as today>)
//     and ONE KEY PER ARTIFACT, shared by every screen that reads it:
//         MetricDetail (journal movers)  'journal_insights|90d'   (was
//                                         'metric_insights|<metric>')
//         Wellness JournalFindings       'journal_insights|90d'   (was
//                                         'wellness_insights') and
//                                        'weekday_effect'         (was
//                                         'wellness_weekday')
//         Beats                          'beats|<day>'            (unchanged)
//         Workout detail                 'workout|<id>'           (unchanged)
//   * A fresh result clears nothing and shows nothing extra: no "As of" label,
//     no spinner, and the loader is not called.
//
// Failure mode today: a stored result is shown under "As of" and recomputed on
// every open (the loader count is 1, the label is up), and the keys are the old
// per-screen ones, so a seeded 'journal_insights|90d' is never read.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../fix8ai/support/g1_db.dart';
import 'support/p3_support.dart';
import 'support/p3_warmer_support.dart';

const _db = 'openstrap_p3_screens_fresh_test.db';
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

/// Store [value] under [key] with [sig], as an earlier open / the warmer would.
Future<void> _seed(WidgetTester t, String key, Map<String, dynamic> value,
    String? sig) async {
  await t.runAsync(() async {
    if (sig == null) {
      LastResultCache.instance.put<Map<String, dynamic>>(key, value);
    } else {
      (LastResultCache.instance as dynamic)
          .put<Map<String, dynamic>>(key, value, sig: sig);
    }
    await LastResultCache.instance.flush();
  });
}

/// A restart: pending writes land, then the memory layer is dropped.
Future<void> _restart(WidgetTester t) async {
  await t.runAsync(() => LastResultCache.instance.flush());
  LastResultCache.instance.clearMemory();
}

Future<Map<String, Object?>?> _row(WidgetTester t, String key) async {
  return t.runAsync<Map<String, Object?>?>(() async {
    await LastResultCache.instance.flush();
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
        'SELECT key, payload_json FROM last_result WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.single;
  });
}

/// The signature stored with [key]'s row (throws until the column exists).
Future<String?> _sigOf(WidgetTester t, String key) async {
  return t.runAsync<String?>(() async {
    await LastResultCache.instance.flush();
    final db = await LocalDb.instance;
    final rows = await db
        .rawQuery('SELECT input_sig FROM last_result WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.single['input_sig'] as String?;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() => g1DropDb(_db));

  // ── MetricDetail ──────────────────────────────────────────────────────────
  group('MetricDetail (journal_insights|90d)', () {
    const stored = {'insights': [], 'p3_marker': 'stored'};

    testWidgets('FRESH in memory: shown, loader not called, no label, no '
        'spinner', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3MetricRepo()..sigs[p3Journal] = 'S1';
      await _seed(t, p3Journal, stored, 'S1');
      await t.pumpWidget(perfApp(_app(repo), const MetricDetail('resting_hr')));
      await settle(t);
      expect(repo.sigAsks, contains(p3Journal),
          reason: 'the screen asked for the current signature');
      expect(repo.insightsCalls, 0,
          reason: 'a fresh artifact is not recomputed on open');
      expect(_label, findsNothing);
      expect(_spinner, findsNothing);
    });

    testWidgets('FRESH from the table after a restart: same', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3MetricRepo()..sigs[p3Journal] = 'S1';
      await _seed(t, p3Journal, stored, 'S1');
      await _restart(t);
      await t.pumpWidget(perfApp(_app(repo), const MetricDetail('resting_hr')));
      await settle(t);
      expect(repo.insightsCalls, 0);
      expect(_label, findsNothing);
    });

    testWidgets('STALE: As-of label while it recomputes once, then the label '
        'clears and the row carries the NEW signature', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3MetricRepo()..sigs[p3Journal] = 'S2';
      await _seed(t, p3Journal, stored, 'S1');
      repo.insightsGate = Completer();
      await t.pumpWidget(perfApp(_app(repo), const MetricDetail('resting_hr')));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 1);
      expect(_spinner, findsNothing, reason: 'the stored result renders');
      expect(_label, findsWidgets);

      repo.insightsGate!.complete(const {'insights': [], 'p3_marker': 'new'});
      await settle(t);
      expect(_label, findsNothing);
      expect((await _row(t, p3Journal))!['payload_json'], contains('"new"'));
      expect(await _sigOf(t, p3Journal), 'S2');
    });

    testWidgets('MISSING: loads once, no label, stored with the current '
        'signature', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3MetricRepo()..sigs[p3Journal] = 'S1';
      await t.pumpWidget(perfApp(_app(repo), const MetricDetail('resting_hr')));
      await settle(t);
      expect(repo.insightsCalls, 1);
      expect(_label, findsNothing);
      expect(await _row(t, p3Journal), isNotNull);
      expect(await _sigOf(t, p3Journal), 'S1');
    });

    testWidgets('regression guard (passes today): a repository with no '
        'signature (null) is never fresh: every open recomputes and shows '
        'As-of', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3MetricRepo(); // sigs empty => artifactSignature -> null
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t);
      expect(repo.insightsCalls, 1);

      await t.pumpWidget(const SizedBox());
      repo.insightsGate = Completer();
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 2);
      expect(_label, findsWidgets);
      repo.insightsGate!.complete(const {'insights': []});
      await settle(t);
      expect(_label, findsNothing);
    });
  });

  // ── Wellness ──────────────────────────────────────────────────────────────
  group('Wellness JournalFindings (journal_insights|90d + weekday_effect)', () {
    const insights = {'numeric_insights': [], 'p3_marker': 'w'};
    const weekday = {'present': false, 'note': 'stored'};

    testWidgets('both FRESH: neither read runs, no label, no spinner',
        (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3WellnessRepo()
        ..sigs[p3Journal] = 'S1'
        ..sigs[p3Weekday] = 'W1';
      await _seed(t, p3Journal, insights, 'S1');
      await _seed(t, p3Weekday, weekday, 'W1');
      await t.pumpWidget(perfApp(_app(repo), const JournalFindings()));
      await settle(t);
      expect(repo.insightsCalls, 0);
      expect(repo.weekdayCalls, 0);
      expect(_label, findsNothing);
      expect(_spinner, findsNothing);
    });

    testWidgets('only the weekday effect is stale: insights are not '
        'recomputed, the weekday one is, and the label is up only until it '
        'lands', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3WellnessRepo()
        ..sigs[p3Journal] = 'S1'
        ..sigs[p3Weekday] = 'W2'
        ..weekdayGate = Completer();
      await _seed(t, p3Journal, insights, 'S1');
      await _seed(t, p3Weekday, weekday, 'W1');
      await t.pumpWidget(perfApp(_app(repo), const JournalFindings()));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 0);
      expect(repo.weekdayCalls, 1);
      expect(_label, findsWidgets, reason: 'the weekday card is stale');

      repo.weekdayGate!.complete(const {'present': false, 'note': 'new'});
      await settle(t);
      expect(_label, findsNothing);
      expect(await _sigOf(t, p3Weekday), 'W2');
    });

    testWidgets('ONE SOURCE: the artifact MetricDetail stored is the one '
        'Wellness finds fresh', (t) async {
      _tall(t);
      await _fresh(t);
      final metric = P3MetricRepo()..sigs[p3Journal] = 'S1';
      await t.pumpWidget(perfApp(_app(metric), const MetricDetail('resting_hr')));
      await settle(t);
      expect(metric.insightsCalls, 1);
      await t.pumpWidget(const SizedBox());

      final wellness = P3WellnessRepo()
        ..sigs[p3Journal] = 'S1'
        ..sigs[p3Weekday] = 'W1';
      await t.pumpWidget(perfApp(_app(wellness), const JournalFindings()));
      await settle(t);
      expect(wellness.insightsCalls, 0,
          reason: 'same key, same signature: computed once for both screens');
      expect(wellness.weekdayCalls, 1, reason: 'its own artifact was missing');
    });
  });

  // ── Beats ─────────────────────────────────────────────────────────────────
  group('Beats (beats|<day>)', () {
    final key = p3Beats(todayId);
    final stored = {
      'nn': [for (var i = 0; i < 300; i++) 900.0 + (i % 11)],
      'raw_beats': 312,
      'clean_fraction': 0.96,
    };

    testWidgets('FRESH: the stored night is shown with no recompute, no label',
        (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3BeatsRepo()..sigs[key] = 'B1';
      await _seed(t, key, stored, 'B1');
      await t.pumpWidget(perfApp(_app(repo), const Beats()));
      await settle(t);
      expect(repo.sigAsks, contains(key));
      expect(repo.beatsCalls, 0);
      expect(_label, findsNothing);
      expect(_spinner, findsNothing);
    });

    testWidgets('STALE: As-of + one warm request (never an inline compute), '
        'then the label clears and the row carries the new signature',
        (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3BeatsRepo()..sigs[key] = 'B2';
      await _seed(t, key, stored, 'B1');
      final src = FakeArtifactSource()
        ..sigs[key] = 'B2'
        ..results[key] = stored
        ..gates[key] = Completer<void>();
      final app = _app(repo)..debugArtifactSource = src;
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t, n: 20);
      expect(src.computes(key), 1, reason: 'the warm was requested once');
      expect(repo.beatsCalls, 0, reason: 'the screen never computes it');
      expect(_label, findsWidgets);
      src.gates[key]!.complete();
      await settle(t);
      expect(_label, findsNothing);
      expect(await _sigOf(t, key), 'B2');
    });

    testWidgets('regression guard (passes today): an error is still never '
        'stored (no row, nothing fresh next time)', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = P3BeatsRepo()
        ..sigs[key] = 'B1'
        ..beatsThrow = true;
      await t.pumpWidget(perfApp(_app(repo), const Beats()));
      await settle(t);
      expect(await _row(t, key), isNull);
    });
  });

  // ── Structural: the screens that cannot be driven with a fake ─────────────
  group('structure', () {
    String src(String f) => File('lib/ui2/screens/$f').readAsStringSync();

    test('workout detail reads through loadArtifact with the repository '
        'signature, keyed workout|<id>', () {
      final w = src('workout_screen.dart');
      expect(w, contains('loadArtifact'));
      expect(w, contains('artifactSignature'));
      expect(w, contains("keyOf('workout'"));
    });

    test('MetricDetail and Wellness read through loadArtifact', () {
      for (final f in ['metric_detail.dart', 'wellness_screen.dart']) {
        expect(src(f), contains('loadArtifact'), reason: f);
        expect(src(f), contains('artifactSignature'), reason: f);
      }
    });

    test('Beats and Circadian read the stored artifact and ask the warmer '
        'on a miss (loadWarmed), never computing in the build path', () {
      for (final f in ['beats.dart', 'circadian_detail.dart']) {
        expect(src(f), contains('loadWarmed'), reason: f);
        expect(src(f), contains('artifactSignature'), reason: f);
        expect(src(f), contains('warmRequesterOf'), reason: f);
      }
    });

    test('one key per artifact: the per-screen insight keys are gone', () {
      final m = src('metric_detail.dart'), w = src('wellness_screen.dart');
      expect(m, contains('journal_insights'));
      expect(w, contains('journal_insights'));
      expect(w, contains('weekday_effect'));
      expect(m, isNot(contains('metric_insights')));
      expect(w, isNot(contains('wellness_insights')));
      expect(w, isNot(contains('wellness_weekday')));
    });
  });
}
