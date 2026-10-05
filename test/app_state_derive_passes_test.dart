// 8AJ seam 1 characterization: what one derive pass asks of the engine, how it
// ends, and what it notifies. Pins today's AppState behaviour through the
// public / @visibleForTesting surface; it must pass before and after the
// DeriveCoordinator move.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_split8aj_derive_passes.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState make({RescoreRepo? repo}) {
    final a = AppState.forTesting();
    addTearDown(a.dispose);
    a.repo = repo;
    a.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    return a;
  }

  group('changedOnly / automatic mapping', () {
    test('the scheduler\'s light job runs the engine light, changedOnly',
        () async {
      final app = make();
      final calls = <HookCall>[];
      app.debugDeriveRun = deriveHook(days: ['d1'], calls: calls);
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(calls.single.heavy, isFalse);
      expect(calls.single.changedOnly, isTrue);
    });

    test('the scheduler\'s heavy job runs the engine heavy, not changedOnly',
        () async {
      final app = make();
      final calls = <HookCall>[];
      app.debugDeriveRun = deriveHook(days: ['d1'], calls: calls);
      await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(calls.single.heavy, isTrue);
      expect(calls.single.changedOnly, isFalse);
    });

    test('debugAfterDrain defaults to a light full-sweep pass and forwards '
        'its flags verbatim', () async {
      final app = make();
      final calls = <HookCall>[];
      app.debugDeriveRun = deriveHook(days: ['d1'], calls: calls);
      await app.debugAfterDrain();
      await app.debugAfterDrain(heavy: true);
      await app.debugAfterDrain(changedOnly: true);
      await app.debugAfterDrain(heavy: true, changedOnly: true);
      expect([for (final c in calls) (c.heavy, c.changedOnly)], [
        (false, false),
        (true, false),
        (false, true),
        (true, true),
      ]);
    });

    test('one pass calls the engine hook exactly once', () async {
      final app = make();
      final calls = <HookCall>[];
      app.debugDeriveRun = deriveHook(days: ['d1', 'd2'], calls: calls);
      await app.debugAfterDrain();
      expect(calls, hasLength(1));
    });
  });

  group('outcome mapping', () {
    test('a hook that returned n maps to a complete outcome of n days',
        () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d2', 'd1']);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(o.complete, isTrue);
      expect(o.failed, isFalse);
      expect(o.computed, 2);
      expect(o.error, isNull);
    });

    test('a hook that throws maps to failed with the error, never rethrows',
        () async {
      final app = make();
      app.debugDeriveRun = deriveHook(throws: StateError('engine exploded'));
      final o = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(o.failed, isTrue);
      expect(o.complete, isFalse);
      expect(o.error, contains('engine exploded'));
    });

    test('a failed pass is followed by a normal one', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(throws: StateError('first'));
      await app.debugAfterDrain();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(o.complete, isTrue);
      expect(o.computed, 1);
    });

    test('a real light pass over an empty store finishes complete with 0 days',
        () async {
      final app = make();
      final battery = BatteryChannel('charging');
      addTearDown(battery.close);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(o.failed, isFalse);
      expect(o.computed, 0);
    });
  });

  group('PeriodicCalculationPolicy consultation', () {
    test('a real light pass consults the phone-charging input once',
        () async {
      final app = make();
      final battery = BatteryChannel('charging');
      addTearDown(battery.close);
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(battery.stateReads, 1);
    });

    test('a real heavy pass does not read the phone at all (heavy is decided '
        'before any evidence is gathered)', () async {
      final app = make();
      final battery = BatteryChannel('charging');
      addTearDown(battery.close);
      await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(battery.stateReads, 0);
    });

    test('the debug hook replaces the whole engine call, policy included',
        () async {
      final app = make();
      final battery = BatteryChannel('discharging');
      addTearDown(battery.close);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(battery.stateReads, 0);
    });

    test('a light pass with an unplugged phone and no band samples still ends '
        'a complete pass (the policy falls back to a full run)', () async {
      final app = make();
      final battery = BatteryChannel('discharging');
      addTearDown(battery.close);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(battery.stateReads, 1);
      expect(o.failed, isFalse);
    });
  });

  group('nothing-changed early return', () {
    test('a manual changedOnly pass with scope 0 stops before any post-derive '
        'work: no notify, no bump, no rescore, no rescan', () async {
      final repo = RescoreRepo(fixed: 5);
      final app = make(repo: repo);
      var rescans = 0;
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async {
        rescans++;
        return 0;
      };
      app.debugDeriveRun = deriveHook(scope: 0);
      final ticks = TickCounter(app);
      final revs = RevisionLog(app);
      await app.debugAfterDrain(heavy: true, changedOnly: true);
      await settleMs();
      expect(ticks.ticks, 0);
      expect(revs.bumps, 0);
      expect(repo.rescoreCalls, 0);
      expect(rescans, 0);
    });

    test('an automatic light pass with scope 0 still runs the cheap session '
        'rescore, and ticks only when it fixed something', () async {
      final repo = RescoreRepo(fixed: 0);
      final app = make(repo: repo);
      app.debugDeriveRun = deriveHook(scope: 0);
      final ticks = TickCounter(app);
      final revs = RevisionLog(app);
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(repo.rescoreCalls, 1);
      expect(ticks.ticks, 0);
      expect(revs.bumps, 0);

      repo.fixed = 2;
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(repo.rescoreCalls, 2);
      expect(ticks.ticks, 1);
      expect(revs.bumps, 1);
    });

    test('a failing rescore on the automatic early return is logged, not '
        'thrown, and the pass is still complete', () async {
      final repo = RescoreRepo(throwsOnRescore: true);
      final app = make(repo: repo);
      app.debugDeriveRun = deriveHook(scope: 0);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(o.failed, isFalse);
      expect(o.computed, 0);
    });

    test('a non-changedOnly pass with scope 0 does NOT return early', () async {
      final repo = RescoreRepo();
      final app = make(repo: repo);
      app.debugDeriveRun = deriveHook(scope: 0);
      final revs = RevisionLog(app);
      await app.debugAfterDrain();
      expect(repo.rescoreCalls, 1);
      expect(revs.bumps, 1, reason: 'the end-of-pass publish');
    });
  });

  group('post-derive work', () {
    test('a pass rescores recent sessions once; a fix adds no extra tick',
        () async {
      final repo = RescoreRepo(fixed: 3);
      final app = make(repo: repo);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      final ticks = TickCounter(app);
      await app.debugAfterDrain();
      expect(repo.rescoreCalls, 1);
      expect(ticks.ticks, 2, reason: 'day 1 + the end-of-pass publish');
    });

    test('a failing rescore on the full path does not fail the pass',
        () async {
      final repo = RescoreRepo(throwsOnRescore: true);
      final app = make(repo: repo);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      expect(o.failed, isFalse);
    });

    test('only a heavy pass runs the baseline-dirty rescan', () async {
      final app = make();
      var rescans = 0;
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async {
        rescans++;
        return 0;
      };
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      await settleMs();
      expect(rescans, 0);
      await app.debugAfterDrain(heavy: true);
      await until(() => rescans > 0);
      expect(rescans, 1);
    });

    test('a rescan that refreshed days bumps and ticks once more; one that '
        'refreshed nothing does not', () async {
      // Two apps, so the day publisher's 1.5 s coalescing gap does not couple
      // the two passes.
      Future<(int, int)> heavyPass(int rescanned) async {
        final app = make();
        app.debugRescanRecent = ({onScopeDays, onDayDone}) async => rescanned;
        app.debugDeriveRun = deriveHook(days: ['d1']);
        final ticks = TickCounter(app);
        final revs = RevisionLog(app);
        await app.debugAfterDrain(heavy: true);
        await settleMs();
        return (ticks.ticks, revs.bumps);
      }

      final quiet = await heavyPass(0);
      final refreshed = await heavyPass(2);
      expect(quiet.$1, 2, reason: 'day 1 + publish');
      expect(refreshed.$1, quiet.$1 + 1);
      expect(refreshed.$2, quiet.$2 + 1);
    });

    test('a throwing rescan is swallowed (the pass outcome is unaffected)',
        () async {
      final app = make();
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async =>
          throw StateError('rescan boom');
      app.debugDeriveRun = deriveHook(days: ['d1']);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      await settleMs();
      expect(o.complete, isTrue);
    });
  });

  group('notifyListeners per pass', () {
    // onDayDone ticks on day 1, every 3rd day and the last; the end of the pass
    // adds one publish tick.
    Future<int> ticksFor(List<String> days, {bool changedOnly = false}) async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: days);
      final ticks = TickCounter(app);
      await app.debugAfterDrain(changedOnly: changedOnly);
      await settleMs();
      return ticks.ticks;
    }

    test('0 days: one tick (the publish)', () async {
      expect(await ticksFor(const []), 1);
    });

    test('1 day: day 1 + publish = 2', () async {
      expect(await ticksFor(['d1']), 2);
    });

    test('2 days: day 1, day 2 (last) + publish = 3', () async {
      expect(await ticksFor(['d2', 'd1']), 3);
    });

    test('3 days: days 1 and 3 + publish = 3 (day 2 is silent)', () async {
      expect(await ticksFor(['d3', 'd2', 'd1']), 3);
    });

    test('4 days: days 1, 3, 4 + publish = 4', () async {
      expect(await ticksFor(['d4', 'd3', 'd2', 'd1']), 4);
    });

    test('7 days: days 1, 3, 6, 7 + publish = 5', () async {
      expect(await ticksFor([for (var i = 7; i >= 1; i--) 'd$i']), 5);
    });

    test('a pass that throws before any day: no tick at all', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(throws: StateError('x'));
      final ticks = TickCounter(app);
      await app.debugAfterDrain();
      await settleMs();
      expect(ticks.ticks, 0);
    });

    test('a pass that throws after one day keeps that day\'s tick only',
        () async {
      final app = make();
      app.debugDeriveRun = ({
        required heavy,
        required changedOnly,
        onScope,
        onScopeDays,
        onDayDone,
        onCrossDay,
      }) async {
        onScopeDays?.call(['d2', 'd1']);
        onDayDone?.call('d2', 1, 2);
        throw StateError('second day blew up');
      };
      final ticks = TickCounter(app);
      await app.debugAfterDrain();
      await settleMs();
      expect(ticks.ticks, 1);
    });
  });
}
