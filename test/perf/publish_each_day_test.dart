// 8AG-perf P1-B: publish each day as it commits.
//
// The bug: `_afterDrain` advanced insightsRevision only after `run()` returned,
// so Home/Health (which reload on that revision, not on notifyListeners) showed
// nothing of a multi-day pass until the whole pass finished.
//
// ASSUMED API: the AppState test seams listed in recalc_state_test.dart
// (`debugDeriveRun`, `debugAfterDrain`), plus lib/state/revision_coalescer.dart
// (see revision_coalescer_test.dart). In `onDayDone`, AFTER the day's row is
// committed: `await LocalDb.refreshComputeFreshness(); bumpInsights()`, through
// a RevisionCoalescer (<= 1 bump per 1500 ms, trailing flush). The end-of-pass
// bump stays; the "notifyListeners every 3rd day" stays.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

import 'support/perf_fakes.dart';

Future<void> _until(bool Function() ok,
    {Duration within = const Duration(seconds: 4)}) async {
  final end = DateTime.now().add(within);
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_publish_each_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() => LocalDb.close());

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('day 1 commits while day 2 blocks: the revision moves BEFORE the pass '
      'returns', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final block = Completer<void>();
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScope?.call(3);
      onScopeDays?.call(['d3', 'd2', 'd1']);
      onDayDone?.call('d3', 1, 3); // today commits
      await block.future; // d2 is still computing
      onDayDone?.call('d2', 2, 3);
      onDayDone?.call('d1', 3, 3);
      return 3;
    };

    final start = app.insightsRevision.value;
    var returned = false;
    final pass = app.debugAfterDrain().whenComplete(() => returned = true);
    await _until(() => app.insightsRevision.value > start);

    expect(app.insightsRevision.value, greaterThan(start),
        reason: 'Home reloads on this; it must not wait for the whole pass');
    expect(returned, isFalse, reason: 'the pass is still running');

    final midPass = app.insightsRevision.value;
    block.complete();
    await pass;
    expect(app.insightsRevision.value, greaterThan(midPass),
        reason: 'the end-of-pass bump stays');
  });

  test('a burst of days is coalesced: one immediate bump, one trailing flush',
      () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final end = Completer<void>();
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScopeDays?.call([for (var i = 10; i >= 1; i--) 'd$i']);
      for (var i = 1; i <= 10; i++) {
        onDayDone?.call('d${11 - i}', i, 10);
      }
      await end.future;
      return 10;
    };
    final start = app.insightsRevision.value;
    final pass = app.debugAfterDrain();

    await _until(() => app.insightsRevision.value >= start + 1);
    expect(app.insightsRevision.value, start + 1,
        reason: 'the first commit publishes at once; the other nine wait');

    // The trailing flush publishes the LAST committed day, ~1.5 s later.
    await _until(() => app.insightsRevision.value >= start + 2,
        within: const Duration(seconds: 4));
    expect(app.insightsRevision.value, start + 2,
        reason: 'ten commits, two bumps: <= 1 per 1500 ms');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(app.insightsRevision.value, start + 2, reason: 'no further bumps');

    end.complete();
    await pass;
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('the every-3rd-day notifyListeners that drives progress UI stays',
      () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final end = Completer<void>();
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScopeDays?.call(['d3', 'd2', 'd1']);
      onDayDone?.call('d3', 1, 3);
      onDayDone?.call('d2', 2, 3);
      onDayDone?.call('d1', 3, 3);
      await end.future;
      return 3;
    };
    var ticks = 0;
    app.addListener(() => ticks++);
    final pass = app.debugAfterDrain();
    await _until(() => ticks >= 2);
    expect(ticks, greaterThanOrEqualTo(2),
        reason: 'index 1 and index == total still notify mid-pass');
    end.complete();
    await pass;
  });

  test('a pass that commits nothing does not bump mid-pass', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final gate = Completer<void>();
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScopeDays?.call(['d1']);
      await gate.future;
      return 0;
    };
    final start = app.insightsRevision.value;
    final pass = app.debugAfterDrain();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(app.insightsRevision.value, start);
    gate.complete();
    await pass;
  });

  testWidgets('Home has re-read and shows day 1\'s new value before the pass '
      'returns', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2600 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final repo = HomeRepo(homeBundle(
        overnightAt: todayAtMs(7, 10), activityAt: todayAtMs(8, 42)));
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
    await settle(t);
    expect(find.text('70'), findsOneWidget);

    final block = Completer<void>();
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScope?.call(3);
      onScopeDays?.call([todayId, 'd2', 'd1']);
      // Today commits: its row is now in the store.
      repo.today = homeBundle(
          readiness: 75,
          overnightAt: todayAtMs(9, 15),
          activityAt: todayAtMs(9, 15));
      onDayDone?.call(todayId, 1, 3);
      await block.future; // day 2 is still computing
      return 3;
    };

    // Not under t.runAsync: that would still be open while `settle` (which
    // uses runAsync itself) polls, and runAsync is not reentrant. The pass's
    // I/O completes through the pumps `settle` does.
    var returned = false;
    final pass = app.debugAfterDrain().whenComplete(() => returned = true);
    await settle(t, n: 60);

    expect(returned, isFalse, reason: 'the pass has not returned');
    expect(find.text('75'), findsOneWidget,
        reason: 'Home showed day 1\'s new value mid-pass');
    expect(find.text('70'), findsNothing);

    block.complete();
    for (var i = 0; i < 20 && !returned; i++) {
      await settle(t, n: 5);
    }
    await pass;
  });
}
