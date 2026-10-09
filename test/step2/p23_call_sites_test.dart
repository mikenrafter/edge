// P2.3 call sites (design 02 step 2, B5; AGENTS.md 4.7 "a capability wired into
// one call path but not all N").
//
// B5 lists the callers of the freshness refresh: every published day and the
// end of a derive pass (DeriveCoordinator), imports, re-analysis, sleep edits,
// day deletes and overrides (AppState), the demo clear, startup, and getToday
// when its freshness row is stale. The checklist:
//
//   * every caller that pairs the refresh with a revision bump publishes
//     through the PublishGate (one serialised loop), not around it;
//   * the callers that cannot (no coordinator in reach, or a reader) are
//     listed with the reason, and the list only shrinks;
//   * getToday's stale-row refresh decodes the freshness projection, not a
//     full bundle.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:openstrap_edge/state/publish_gate.dart';

import '../support/app_state_derive_harness.dart';
import '../support/dart_source.dart';
import 'support/p23_support.dart';

const _db = 'p23_call_sites.db';

/// Files in lib/ (relative) that may call `LocalDb.refreshComputeFreshness`
/// directly, with the reason. Shrink-only: a listed file that stops calling
/// must be deleted from here.
const Map<String, String> _directCallers = {
  'data/db.dart': 'the definition',
  'state/publish_gate.dart': 'PublishGate.standard: step (1) of the loop',
  'state/app_state.dart': 'startup (initState-time freshness; no bump follows)',
  'demo/demo_data_generator.dart': 'the demo clear: a static helper with no coordinator',
  'data/local_repository_impl.dart': 'getToday when its freshness row is stale (a reader)',
};

String _code(String path) => stripCommentsAndStrings(File(path).readAsStringSync());

int _count(String code, Pattern p) => p.allMatches(code).length;

class _Host {
  final logs = <String>[];
  bool disposed = false;

  DeriveCoordinator build(PublishGate? gate) => DeriveCoordinator(
    engine: () => engine ??= DerivationEngine(log: logs.add),
    profile: () => Profile.fromMap(const <String, dynamic>{}),
    log: logs.add,
    notify: () {},
    isDisposed: () => disposed,
    repo: () => null,
    warmHeld: () => false,
    refreshPhoneStepsToday: () async {},
    maybeNotifyRecoveryReady: () async {},
    runHealthExport: () async => 0,
    healthSyncEnabled: () => false,
    telemetryConsent: () => false,
    healthShareConsent: () => false,
    maybeReclaimDiskSpace: () async {},
    publishGate: gate,
  );

  DerivationEngine? engine;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('source checklist (lib/)', () {
    test('only the listed files call LocalDb.refreshComputeFreshness directly',
        () {
      final callers = <String>{};
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (_code(f.path).contains('refreshComputeFreshness')) {
          callers.add(f.path.substring('lib/'.length));
        }
      }

      expect(callers.difference(_directCallers.keys.toSet()), isEmpty,
          reason: 'a publish path that bypasses the PublishGate: route it');
      expect(_directCallers.keys.toSet().difference(callers), isEmpty,
          reason: 'delete these lines from _directCallers (shrink-only)');
    });

    test('DeriveCoordinator neither refreshes freshness nor evicts the cache '
        'itself: its publish paths go through the gate', () {
      final code = _code('lib/state/derive_coordinator.dart');

      expect(code, isNot(contains('refreshComputeFreshness')));
      expect(code, isNot(contains('invalidateAll')));
      expect(code, isNot(contains('invalidateBundleMemo')));
      expect(code, contains('publishGate'));
    });

    test('the per-day publisher fires the gate', () {
      final code = _code('lib/state/derive_coordinator.dart');
      final at = code.indexOf('void _publishDay()');
      expect(at, greaterThanOrEqualTo(0));
      final body = code.substring(at, code.indexOf('}', at) + 1);
      expect(body, contains('publishGate.request()'));
    });

    test('AppState publishes through the coordinator at every site that paired '
        'a refresh with a bump (wake confirmation, re-analysis, sleep edit, '
        'rebuild, override, day delete)', () {
      final code = _code('lib/state/app_state.dart');

      expect(_count(code, 'LocalDb.refreshComputeFreshness'), lessThanOrEqualTo(1),
          reason: 'only the startup refresh may stay');
      expect(_count(code, '_deriveCoordinator.publishNow('), greaterThanOrEqualTo(6));
    });

    test('the pause-for-background eviction and the publish path are not the '
        'same thing: publish never calls invalidateAll anywhere in lib/state',
        () {
      for (final f in Directory('lib/state').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('app_state.dart')) continue; // pauseForBackground
        expect(_code(f.path), isNot(contains('BundleStore.shared.invalidateAll')),
            reason: f.path);
      }
    });
  });

  group('DeriveCoordinator through an injected gate', () {
    late _Host host;
    late P23Rig rig;
    late DeriveCoordinator c;
    late BundleStore store;

    setUp(() async {
      await deriveDbSetUp(_db);
      SharedPreferences.setMockInitialValues({});
      host = _Host();
      rig = P23Rig();
      // The gate's bump is the coordinator's own revision bump.
      late DeriveCoordinator coordinator;
      rig.onBump = () => coordinator.bumpInsights();
      coordinator = c = host.build(rig.gate);
      c.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      store = p22Store(P22Lane());
      p22UseStore(store);
    });
    tearDown(() async {
      c.dispose();
      rig.gate.dispose();
      await deriveDbTearDown(_db);
    });

    test('a committed day requests the gate: the refresh and the bump happen in '
        'the gate\'s steps, and the coordinator wrote no freshness itself',
        () async {
      c.debugDeriveRun = deriveHook(days: ['d2', 'd1']);

      await c.debugRunScheduled(kind: DeriveJobKind.light);

      expect(rig.count('refresh'), greaterThanOrEqualTo(1));
      expect(rig.count('bump'), greaterThanOrEqualTo(1));
      expect(c.insightsRevision.value, rig.count('bump'));
      expect(await LocalDb.computeFreshness('today'), isNull,
          reason: 'the fake step wrote nothing; the old path wrote the row');
    });

    test('the end of a pass waits for the gate to go idle (no publish is left '
        'running behind the pass)', () async {
      rig.holdRefresh = Completer<void>();
      c.debugDeriveRun = deriveHook(days: ['d1']);

      var done = false;
      final pass = c.debugRunScheduled(kind: DeriveJobKind.light).whenComplete(() => done = true);
      await p22Until(() => rig.count('refresh') >= 1, 'the gate started');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse, reason: 'the refresh is still held');

      rig.holdRefresh!.complete();
      await pass;

      expect(rig.events.last, 'bump');
      expect(rig.inFlight, 0);
    });

    test('publishNow requests a run and returns after its bump', () async {
      await c.publishNow();

      expect(rig.events, ['refresh', 'revs', 'warm:A,B', 'bump']);
      expect(c.insightsRevision.value, 1);
    });

    test('publishNow while a run is in flight does not start a second refresh '
        'beside it', () async {
      rig.holdRefresh = Completer<void>();
      final a = c.publishNow();
      await p22Until(() => rig.count('refresh') == 1, 'first refresh');
      final b = c.publishNow();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.count('refresh'), 1);

      rig.holdRefresh!.complete();
      await Future.wait([a, b]);

      expect(rig.maxInFlight, 1);
      expect(rig.events.last, 'bump');
    });

    test('a pass keeps the bundle cache: publishing does not evict', () async {
      await store.warm(const []); // no-op, the store is live
      final lane = P22Lane();
      store = p22Store(lane);
      p22UseStore(store);
      final db = await LocalDb.instance;
      await p23Row(db, p23Day(3), p23Payload(sleep: true), computedAt: 1);
      await store.read(BundleSource.day(p23Day(3)));
      expect(store.debugCachedKeys, hasLength(1));
      c.debugDeriveRun = deriveHook(days: ['d1']);

      await c.debugRunScheduled(kind: DeriveJobKind.light);

      expect(store.debugCachedKeys, hasLength(1),
          reason: 'the revision key makes eviction on publish unnecessary');
    });

    test('a disposed coordinator publishes nothing more', () async {
      c.dispose();
      final before = rig.events.length;
      host.disposed = true;

      c.publishGate.request();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(rig.events.length, before);
    });
  });

  group('getToday when its freshness row is stale', () {
    const name = 'p23_get_today.db';
    late P22Lane lane;

    setUp(() async {
      await p21Fresh(name);
      lane = P22Lane();
      p22UseStore(p22Store(lane));
    });
    tearDown(() => p21Drop(name));

    test('the refresh it triggers decodes the freshness projection, and the '
        'first decode of the call is that refresh\'s, not a full bundle',
        () async {
      final db = await LocalDb.instance;
      await p23Row(db, p23Day(0), p23Payload(), computedAt: 5000);
      await p23Row(db, p23Day(1), p23Payload(sleep: true, readiness: 70), computedAt: 4000);
      final repo = LocalRepositoryImpl(getProfileMap: () => p22Profile);

      await repo.getToday();

      expect(lane.chunks, isNotEmpty);
      expect(lane.chunks.first.projections.toSet(), {'freshness'});
      final row = await LocalDb.computeFreshness('today');
      expect(row, isNotNull, reason: 'the stale refresh was written');
    });
  });
}
