// P4c: Circadian opens from the warmed `circadian` artifact.
//
// Today CircadianData.load runs on EVERY open: getInsights, then
// getDaySleepV2 for each of 42 nights and getDayHeart for 7, ~49 day_result
// bundle decodes on the main isolate, while the ArtifactWarmer warms a
// `circadian` key (computeArtifact('circadian') == getInsights()) that nothing
// reads.
//
// ASSUMED (spec: "prefer reading it"):
//   * CircadianDetail reads its data through
//       LastResultCache.instance.loadArtifact('circadian', <today's load>,
//           signature: () => repo.artifactSignature('circadian'), onLast: ..)
//     so a stored entry whose signature equals the current one is FRESH: shown
//     as is, the loader never runs, so NO day_result bundle is decoded.
//   * What the warmer stores for 'circadian' (LocalRepositoryImpl
//     .computeArtifact('circadian')) carries everything the screen draws
//     (the actogram, the hourly row, the rollup), not only getInsights(). The
//     test seeds the cache with that very producer's output, so it holds
//     whatever shape the implementation chooses.
//   * Cold (no entry): the screen never computes on open. It shows the shell
//     and an InlineLoading, ENQUEUES the warm (AppState.requestWarm, observed
//     through the artifact the warmer stores), and draws the warmed result
//     when it lands.
//   * Stale (signature moved): the stored entry is drawn at once under an
//     "As of" label, the warm is enqueued, and the fresh result replaces it.
//   * Decodes are counted by LocalRepositoryImpl.debugBundleDecodes (see
//     bundle_memo_test.dart).
//
// Failure mode today: the new static does not exist (compile error); once it
// does, a warm open decodes ~49 bundles.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show InlineLoading;

import '../fix8ai/support/g1_db.dart';
import '../perf/support/perf_fakes.dart' show perfApp, settle;

const _db = 'p4c_circadian_cache_first_test.db';
const _key = 'circadian';

String _back(int n) {
  final t = DateTime.now();
  return dayLabelOf(DateTime(t.year, t.month, t.day - n));
}

/// A night ending on [day]'s morning: asleep 23:00 -> 06:00 local.
String _payload(String day) {
  final d = DateTime.parse(day);
  final onset = DateTime(d.year, d.month, d.day - 1, 23).millisecondsSinceEpoch;
  final wake = DateTime(d.year, d.month, d.day, 6).millisecondsSinceEpoch;
  return jsonEncode({
    'date': day,
    'scalars': {'rmssd': 55.0},
    'sleep': {
      'accounting': {
        'value': {'tst_sec': 25200, 'waso_sec': 600, 'efficiency_pct': 91.0}
      },
      'window': {
        'value': {'onset_ms': onset, 'offset_ms': wake, 'spt_sec': 25200}
      },
    },
  });
}

Future<void> _seedNights(int n) async {
  final db = await LocalDb.instance;
  for (var i = 1; i <= n; i++) {
    final day = _back(i);
    await db.insert(
        'day_result',
        {
          'day_id': day,
          'algo_version': kAlgoVersion,
          'payload_json': _payload(day),
          'window_json': '{}',
          'computed_at': 1000 + i,
          'finalized': 1,
          'skipped': 0,
          'partial': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

AppState _app(LocalRepositoryImpl repo) {
  final a = AppState.forTesting();
  a.repo = repo;
  addTearDown(a.dispose);
  return a;
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(390 * 3, 3000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() => g1DropDb(_db));

  Future<LocalRepositoryImpl> arrange(WidgetTester t) async {
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    await t.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await g1FreshDb(_db);
      await LocalDb.instance;
      await _seedNights(10);
    });
    LastResultCache.instance.clear();
    LocalRepositoryImpl.debugResetBundleMemo();
    return repo;
  }

  testWidgets('warm artifact (fresh signature): no bundle is decoded on open, '
      'and the page is drawn', (t) async {
    _tall(t);
    final repo = await arrange(t);
    await t.runAsync(() async {
      // What the warmer does after a pass.
      final value = await repo.computeArtifact(_key);
      final sig = await repo.artifactSignature(_key);
      expect(value, isNotNull, reason: 'the producer has a value to store');
      expect(sig, isNotNull);
      LastResultCache.instance
          .put<Map<String, dynamic>>(_key, value!, sig: sig);
      await LastResultCache.instance.flush();
    });
    // The warm itself may decode; the OPEN must not.
    LocalRepositoryImpl.debugResetBundleMemo();

    await t.pumpWidget(perfApp(_app(repo), const CircadianDetail()));
    await settle(t, n: 25);

    expect(LocalRepositoryImpl.debugBundleDecodes, 0,
        reason: 'a fresh stored artifact is shown as is: no getDaySleepV2 x42 '
            'and no getDayHeart x7 on the main isolate');
    expect(find.text('Body clock'), findsOneWidget);
    expect(find.text('No nights to plot yet'), findsNothing,
        reason: 'the ten seeded nights are drawn from the artifact');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('warm artifact from the restart-surviving table (memory '
      'dropped): still no bundle decode', (t) async {
    _tall(t);
    final repo = await arrange(t);
    await t.runAsync(() async {
      final value = await repo.computeArtifact(_key);
      LastResultCache.instance.put<Map<String, dynamic>>(_key, value!,
          sig: await repo.artifactSignature(_key));
      await LastResultCache.instance.flush();
    });
    LastResultCache.instance.clearMemory();
    LocalRepositoryImpl.debugResetBundleMemo();

    await t.pumpWidget(perfApp(_app(repo), const CircadianDetail()));
    await settle(t, n: 25);

    expect(LocalRepositoryImpl.debugBundleDecodes, 0);
    expect(find.text('No nights to plot yet'), findsNothing);
  });

  /// The warm the screen asked for has landed in the store, under the current
  /// signature.
  Future<bool> warmedFresh(WidgetTester t, LocalRepositoryImpl repo) => t
          .runAsync(() async {
        final hit = await LastResultCache.instance.read<Map>(_key);
        return hit != null &&
            hit.sig == await repo.artifactSignature(_key);
      }).then((v) => v ?? false);

  /// Pumps (real time, bounded) until the warm has landed.
  Future<void> settleWarm(WidgetTester t, LocalRepositoryImpl repo) async {
    for (var i = 0; i < 300 && !await warmedFresh(t, repo); i++) {
      await settle(t, n: 1);
    }
  }

  testWidgets('cold (nothing stored): the shell and an InlineLoading, the '
      'warm is requested, and its result is drawn', (t) async {
    _tall(t);
    final repo = await arrange(t);

    await t.pumpWidget(perfApp(_app(repo), const CircadianDetail()));
    // First frames: nothing stored, the warm not landed yet.
    await t.pump();
    expect(find.text('Body clock'), findsOneWidget);
    expect(find.byType(InlineLoading), findsOneWidget);
    expect(find.text('No nights to plot yet'), findsNothing,
        reason: 'waiting is not an empty state');

    await settleWarm(t, repo);
    expect(await warmedFresh(t, repo), isTrue,
        reason: 'the screen enqueued the warm; the warmer stored it');
    await settle(t, n: 10);
    expect(find.byType(InlineLoading), findsNothing);
    expect(find.text('Body clock'), findsOneWidget);
    expect(find.text('No nights to plot yet'), findsNothing,
        reason: 'the ten seeded nights are drawn from the warmed artifact');
    expect(t.takeException(), isNull);

    // A later open of the same page is warm: no decode of its own.
    LocalRepositoryImpl.debugResetBundleMemo();
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(perfApp(_app(repo), const CircadianDetail()));
    await settle(t, n: 25);
    expect(LocalRepositoryImpl.debugBundleDecodes, 0);
  });

  testWidgets('a STALE stored artifact is not trusted: it is drawn labelled, '
      'the warm is requested, and the fresh result replaces it', (t) async {
    _tall(t);
    final repo = await arrange(t);
    await t.runAsync(() async {
      final value = await repo.computeArtifact(_key);
      LastResultCache.instance
          .put<Map<String, dynamic>>(_key, value!, sig: 'not-the-current-one');
      await LastResultCache.instance.flush();
    });
    LocalRepositoryImpl.debugResetBundleMemo();

    await t.pumpWidget(perfApp(_app(repo), const CircadianDetail()));
    await settleWarm(t, repo);
    await settle(t, n: 10);

    expect(await warmedFresh(t, repo), isTrue,
        reason: 'a signature that no longer matches means the inputs moved: '
            'the warm was requested and replaced it');
    expect(find.byType(InlineLoading), findsNothing);
    expect(find.text('No nights to plot yet'), findsNothing);
    expect(find.byKey(const ValueKey('as-of-label')), findsNothing,
        reason: 'the fresh result carries no stale label');
  });
}
