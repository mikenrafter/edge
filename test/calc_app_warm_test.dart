// 8AG-perf P3-B: AppState wires the warmer into `_afterDrain`.
//
// ASSUMED API (lib/state/app_state.dart; the warmer itself is pinned in
// p3_warmer_test.dart, lib/state/artifact_warmer.dart):
//
//   @visibleForTesting ArtifactSource? debugArtifactSource;
//       The source the warmer uses. Read when a pass finishes and the warmer
//       is first needed. Null in production => `RepoArtifactSource(repo)`;
//       with neither a debug source nor a repo there is no warming.
//
//   AppState owns ONE ArtifactWarmer (built on first use, `hold:` =
//   `_liveSessionActive` (workout, breathing, ECG capture) or the derive
//   scheduler holding, `log:` = `_log`). In `_afterDrain`, on the SUCCESS path,
//   AFTER the existing publish (`LocalDb.refreshComputeFreshness(); bumpInsights();
//   notifyListeners();`), when the pass computed at least one day
//   (`outcome.computed >= 1`), it starts, unawaited:
//
//       _artifactWarmer.warmAfterPass(changedDays: <the days this pass reported
//                                      through onDayDone, in report order>)
//
//   NOT started: computed == 0; the `changedOnly` "nothing changed" early
//   return; a pass that failed (the hook threw). `dispose()` disposes the
//   warmer.
//
// Failure mode today: `debugArtifactSource` does not exist (NoSuchMethodError
// through `dynamic`, and the file needs ArtifactSource to compile at all).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import 'support/last_result_db.dart';
import 'support/scripted_artifact_source.dart';

const _db = 'openstrap_p3_app_warm_test.db';

Future<void> _until(bool Function() ok,
    {Duration within = const Duration(seconds: 4)}) async {
  final end = DateTime.now().add(within);
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settleMs([int ms = 250]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Future<List<Map<String, Object?>>> _rows() async {
  // The warmer stores right after a compute returns; give it the microtasks.
  await _settleMs(100);
  await LastResultCache.instance.flush();
  final db = await LocalDb.instance;
  return db.rawQuery(
      'SELECT key, input_sig FROM last_result ORDER BY key ASC');
}

/// A derive hook that reports [days] through onDayDone and returns their count.
DeriveRunHook _computing(List<String> days) => ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScope?.call(days.length);
      onScopeDays?.call(days);
      for (var i = 0; i < days.length; i++) {
        onDayDone?.call(days[i], i + 1, days.length);
      }
      return days.length;
    };

AppState _app(FakeArtifactSource src, {bool teardown = true}) {
  final a = AppState.forTesting();
  (a as dynamic).debugArtifactSource = src;
  if (teardown) addTearDown(a.dispose);
  return a;
}

FakeArtifactSource _source() {
  final s = FakeArtifactSource()
    ..keys = ['journal_insights|90d', 'weekday_effect', 'circadian']
    ..sigs.addAll({
      'journal_insights|90d': 'j1',
      'weekday_effect': 'w1',
      'circadian': 'c1',
    });
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await g1FreshDb(_db);
    LastResultCache.instance.clear();
  });
  tearDownAll(() async {
    await LastResultCache.instance.flush();
    await g1DropDb(_db);
  });

  test('a pass that computed days warms the changed artifacts, once, '
      'serially, AFTER the publish, and stores them', () async {
    final src = _source();
    var revisionAtFirstAsk = -1;
    final app = _app(src);
    final start = app.insightsRevision.value;
    // The publish state at the moment the warmer first asks.
    src.onAsk = () {
      if (revisionAtFirstAsk < 0) revisionAtFirstAsk = app.insightsRevision.value;
    };

    app.debugDeriveRun = _computing(['2026-10-03', '2026-10-02']);
    await app.debugAfterDrain();
    await _until(() => src.computeFinished.length >= 3);

    expect(src.candidateCalls, [
      ['2026-10-03', '2026-10-02']
    ], reason: 'the days the pass reported, in report order');
    expect(src.computeStarted,
        ['journal_insights|90d', 'weekday_effect', 'circadian']);
    expect(src.maxRunning, 1, reason: 'one bounded serial warmer');
    expect(revisionAtFirstAsk, greaterThan(start),
        reason: 'the publish (bumpInsights) came first');

    final rows = await _rows();
    expect({for (final r in rows) r['key']: r['input_sig']}, {
      'circadian': 'c1',
      'journal_insights|90d': 'j1',
      'weekday_effect': 'w1',
    }, reason: 'the same last_result rows the screens read, with signatures');
  });

  test('a second pass with unchanged signatures recomputes nothing', () async {
    final src = _source();
    final app = _app(src);
    app.debugDeriveRun = _computing(['2026-10-03']);
    await app.debugAfterDrain();
    await _until(() => src.computeFinished.length >= 3);
    src.computeStarted.clear();

    await app.debugAfterDrain();
    await _settleMs();
    expect(src.candidateCalls.length, 2, reason: 'asked again');
    expect(src.computeStarted, isEmpty, reason: 'nothing changed: all fresh');
  });

  test('a pass that computed 0 days warms nothing', () async {
    final src = _source();
    final app = _app(src);
    app.debugDeriveRun = _computing(const []);
    await app.debugAfterDrain();
    await _settleMs();
    expect(src.candidateCalls, isEmpty);
    expect(src.computeStarted, isEmpty);
  });

  test('a changedOnly pass with nothing in scope warms nothing', () async {
    final src = _source();
    final app = _app(src);
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScope?.call(0); // the engine found no day whose input moved
      return 0;
    };
    await app.debugAfterDrain(changedOnly: true);
    await _settleMs();
    expect(src.candidateCalls, isEmpty);
  });

  test('a pass that failed warms nothing', () async {
    final src = _source();
    final app = _app(src);
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async =>
        throw StateError('derive blew up');
    await app.debugAfterDrain();
    await _settleMs();
    expect(src.candidateCalls, isEmpty);
    expect(src.computeStarted, isEmpty);
  });

  test('an active workout holds the warmer; the next pass after it ends '
      'warms', () async {
    final src = _source();
    final app = _app(src);
    app.activeWorkout = LiveWorkoutState(
      startTime: DateTime.now(),
      targetKcal: 300,
      workoutId: 'p3-live',
      type: 'run',
    );
    app.debugDeriveRun = _computing(['2026-10-03']);
    await app.debugAfterDrain();
    await _settleMs();
    expect(src.computeStarted, isEmpty, reason: 'never during a workout');

    app.activeWorkout = null;
    await app.debugAfterDrain();
    await _until(() => src.computeFinished.length >= 3);
    expect(src.computeStarted.length, 3);
  });

  test('a breathing session holds it too', () async {
    final src = _source();
    final app = _app(src);
    app.breathingActive = true;
    app.debugDeriveRun = _computing(['2026-10-03']);
    await app.debugAfterDrain();
    await _settleMs();
    expect(src.computeStarted, isEmpty);
    app.breathingActive = false;
  });

  test('two quick passes never run two computes at once', () async {
    final src = _source()..gates['journal_insights|90d'] = Completer<void>();
    final app = _app(src);
    app.debugDeriveRun = _computing(['2026-10-03']);
    await app.debugAfterDrain();
    await _until(() => src.computeStarted.isNotEmpty);
    await app.debugAfterDrain(); // while the first warm is still computing
    await _settleMs(100);
    expect(src.maxRunning, 1);
    src.gates['journal_insights|90d']!.complete();
    await _until(() => src.computeFinished.length >= 3);
    await _settleMs(100);
    for (final k in src.keys) {
      expect(src.computes(k), 1, reason: '$k computed once');
    }
    expect(src.maxRunning, 1);
  });

  test('dispose cancels: the in-flight warm stores nothing', () async {
    final src = _source()..gates['journal_insights|90d'] = Completer<void>();
    final app = _app(src, teardown: false);
    app.debugDeriveRun = _computing(['2026-10-03']);
    await app.debugAfterDrain();
    await _until(() => src.computeStarted.isNotEmpty);
    app.dispose();
    src.gates['journal_insights|90d']!.complete();
    await _settleMs();
    expect(src.computeStarted, ['journal_insights|90d'],
        reason: 'no further key starts after dispose');
    expect(await _rows(), isEmpty, reason: 'the cancelled warm is discarded');
  });

  test('an error in a producer is not stored and does not fail the pass',
      () async {
    final src = _source()..computeThrows.add('weekday_effect');
    final app = _app(src);
    app.debugDeriveRun = _computing(['2026-10-03']);
    await app.debugAfterDrain(); // completes normally
    await _until(() => src.computeFinished.length >= 3);
    final keys = [for (final r in await _rows()) r['key']];
    expect(keys, ['circadian', 'journal_insights|90d']);
  });
}
