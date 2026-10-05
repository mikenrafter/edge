// 8AJ seam 1 characterization: the per-day publish coalescer, the end-of-pass
// publish, bumpInsights, and the artifact warmer hand-off. Must pass before and
// after the DeriveCoordinator move.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/scripted_artifact_source.dart';
import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_split8aj_derive_publish.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState make({FakeArtifactSource? source}) {
    final a = AppState.forTesting();
    addTearDown(a.dispose);
    a.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    if (source != null) a.debugArtifactSource = source;
    return a;
  }

  group('bumpInsights', () {
    test('adds one to the shared notifier and ticks nobody else', () {
      final app = make();
      final ticks = TickCounter(app);
      final revs = RevisionLog(app);
      app.bumpInsights();
      app.bumpInsights();
      expect(app.insightsRevision.value, 2);
      expect(revs.seen, [1, 2]);
      expect(ticks.ticks, 0, reason: 'not a ChangeNotifier repaint');
    });

    test('a bump written straight to the notifier (log-workout sheet, '
        'import) is the same signal', () {
      final app = make();
      final revs = RevisionLog(app);
      app.insightsRevision.value++;
      app.bumpInsights();
      expect(revs.seen, [1, 2]);
    });
  });

  group('per-day publish coalescing', () {
    test('a day commits: the revision moves before the pass returns',
        () async {
      final app = make();
      final gate = Completer<void>();
      app.debugDeriveRun =
          deriveHook(days: ['d2', 'd1'], gate: gate, holdAfter: 1);
      final pass = app.debugAfterDrain();
      await until(() => app.insightsRevision.value > 0);
      expect(app.insightsRevision.value, 1);
      gate.complete();
      await pass;
      expect(app.insightsRevision.value, 2, reason: 'end-of-pass publish');
    });

    test('ten days in one burst: one immediate bump, one trailing flush ~1.5 s '
        'later, plus the end-of-pass bump = 3', () async {
      final app = make();
      app.debugDeriveRun =
          deriveHook(days: [for (var i = 10; i >= 1; i--) 'd$i']);
      final revs = RevisionLog(app);
      await app.debugAfterDrain();
      await settleMs(300);
      expect(revs.bumps, 2,
          reason: 'immediate day publish + end of pass; trailing flush waits');
      await until(() => revs.bumps >= 3, within: const Duration(seconds: 4));
      expect(revs.bumps, 3);
      await settleMs(300);
      expect(revs.bumps, 3, reason: 'nothing further');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a pass that commits no day publishes only at the end', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: const []);
      final revs = RevisionLog(app);
      await app.debugAfterDrain();
      await settleMs();
      expect(revs.bumps, 1);
    });

    test('two passes inside the gap share the publisher: the second pass\'s '
        'day publish is deferred to the trailing flush', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      final revs = RevisionLog(app);
      await app.debugAfterDrain();
      await settleMs(200);
      final afterFirst = revs.bumps;
      expect(afterFirst, 2);
      await app.debugAfterDrain();
      await settleMs(200);
      expect(revs.bumps, afterFirst + 1, reason: 'only the end-of-pass bump');
      await until(() => revs.bumps >= afterFirst + 2,
          within: const Duration(seconds: 4));
      expect(revs.bumps, afterFirst + 2, reason: 'then the trailing flush');
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('artifact warmer hand-off', () {
    FakeArtifactSource source() => FakeArtifactSource();

    test('a productive pass warms once, with the days it reported in order',
        () async {
      final src = source();
      final app = make(source: src);
      app.debugDeriveRun = deriveHook(days: ['d2', 'd1']);
      await app.debugAfterDrain();
      await until(() => src.candidateCalls.isNotEmpty);
      expect(src.candidateCalls, [
        ['d2', 'd1']
      ]);
    });

    test('light and heavy scheduler passes both warm', () async {
      final src = source();
      final app = make(source: src);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      await app.debugRunScheduled(kind: DeriveJobKind.heavy);
      await until(() => src.candidateCalls.length >= 2);
      expect(src.candidateCalls.length, 2);
    });

    test('the warm starts after the publish', () async {
      final src = source();
      final app = make(source: src);
      var revAtAsk = -1;
      src.onAsk = () => revAtAsk = app.insightsRevision.value;
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      await until(() => src.candidateCalls.isNotEmpty);
      expect(revAtAsk, greaterThanOrEqualTo(1));
    });

    test('computed 0 days: no warm', () async {
      final src = source();
      final app = make(source: src);
      app.debugDeriveRun = deriveHook(days: const []);
      await app.debugAfterDrain();
      await settleMs();
      expect(src.candidateCalls, isEmpty);
    });

    test('the engine counted days but none was reported done: no warm',
        () async {
      final src = source();
      final app = make(source: src);
      app.debugDeriveRun = deriveHook(days: const [], returns: 3);
      await app.debugAfterDrain();
      await settleMs();
      expect(src.candidateCalls, isEmpty);
    });

    test('days were reported done but the engine counted 0: no warm',
        () async {
      final src = source();
      final app = make(source: src);
      app.debugDeriveRun = deriveHook(days: ['d1'], returns: 0);
      await app.debugAfterDrain();
      await settleMs();
      expect(src.candidateCalls, isEmpty);
    });

    test('a changedOnly pass with nothing in scope: no warm', () async {
      final src = source();
      final app = make(source: src);
      app.debugDeriveRun = deriveHook(scope: 0);
      await app.debugRunScheduled(kind: DeriveJobKind.light);
      await settleMs();
      expect(src.candidateCalls, isEmpty);
    });

    test('a failed pass: no warm', () async {
      final src = source();
      final app = make(source: src);
      app.debugDeriveRun = deriveHook(throws: StateError('x'));
      await app.debugAfterDrain();
      await settleMs();
      expect(src.candidateCalls, isEmpty);
    });

    test('with no source and no repository there is no warmer at all',
        () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      final o = await app.debugRunScheduled(kind: DeriveJobKind.light);
      expect(o.complete, isTrue);
    });

    test('a live workout or breathing session holds the warm back; the next '
        'pass after it warms', () async {
      final src = source();
      final app = make(source: src);
      app.debugDeriveRun = deriveHook(days: ['d1']);
      app.breathingActive = true;
      await app.debugAfterDrain();
      await settleMs();
      expect(src.candidateCalls, isEmpty);
      app.breathingActive = false;
      await app.debugAfterDrain();
      await until(() => src.candidateCalls.isNotEmpty);
      expect(src.candidateCalls.length, 1);
    });

    test('the source is read when the warmer is first needed, so a source set '
        'before the first productive pass is the one used', () async {
      final src = source();
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      app.debugArtifactSource = src;
      await app.debugAfterDrain();
      await until(() => src.candidateCalls.isNotEmpty);
      expect(src.candidateCalls.length, 1);
      expect(identical(app.debugArtifactSource, src), isTrue);
    });
  });

  group('perf accessors', () {
    test('lastHomeRenderMs is null until recordHomeRender, then holds it',
        () {
      final app = make();
      expect(app.lastHomeRenderMs, isNull);
      app.recordHomeRender(42);
      expect(app.lastHomeRenderMs, 42);
      app.recordHomeRender(7);
      expect(app.lastHomeRenderMs, 7);
    });

    test('lastPassPerf is null before any pass has computed a day', () {
      final app = make();
      expect(app.lastPassPerf, isNull);
    });

    test('the engine hook does not touch the engine, so lastPassPerf stays '
        'null after a hooked pass', () async {
      final app = make();
      app.debugDeriveRun = deriveHook(days: ['d1']);
      await app.debugAfterDrain();
      expect(app.lastPassPerf, isNull);
    });
  });
}
