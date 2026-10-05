// P5: "balanced == today", recorded against the code as it is BEFORE P5.
//
// Uses ONLY symbols that exist today, so it compiles and PASSES now and must
// stay green through the P5 implementation: a green that changes any value
// below has drifted today's behaviour. It records what the scheduler, the
// debouncer, the pacing and the artifact warmer decide in each relevant state.
// The same observations are repeated under CalcPowerMode.balanced and every
// power state (plugged / unplugged x saver) in calc_power_wiring_test.dart.
//
// Not pinned here, because it is private to SyncController with no seam (a
// `DateTime.now()` inside the reconnect callback): the 30-minute background
// heavy throttle (`_lastBackgroundHeavyAt`). P5 must leave that code alone.
//
// Notes recorded from reading the code:
//  * DeriveScheduler.setBackground only holds on iOS (`Platform.isIOS`); on
//    the Linux test host it is a no-op, so the `background` hold is not driven
//    here.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_pacing.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/recalc_state.dart';

import 'support/app_state_derive_harness.dart';
import 'support/artifact_source_spy.dart';

const _db = 'openstrap_p5_balanced_pin.db';

Duration _s(int s) => Duration(seconds: s);
Duration _m(int m) => Duration(minutes: m);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('DeriveDebouncer: the five tiers and what they decide', () {
    const d = DeriveDebouncer();

    test('the tier numbers', () {
      expect(d.staleQuietPeriod, _s(12));
      expect(d.staleMaxWait, _s(90));
      expect(d.freshQuietPeriod, _m(1));
      expect(d.freshMaxWait, _m(5));
      expect(d.staleThreshold, _m(30));
      expect(d.foregroundQuietPeriod, _s(5));
      expect(d.foregroundMaxWait, _s(15));
      expect(d.backgroundQuietPeriod, _m(20));
      expect(d.backgroundMaxWait, _m(45));
    });

    bool go(Duration sinceLast, Duration sinceFirst,
            {Duration staleness = const Duration(minutes: 1),
            bool fg = false,
            bool bg = false}) =>
        d.shouldDerive(
          hasPending: true,
          sinceLastRecord: sinceLast,
          sinceFirstPending: sinceFirst,
          dataStaleness: staleness,
          isForeground: fg,
          isBackgrounded: bg,
        );

    test('foreground: 5 s quiet or 15 s max', () {
      expect(go(_s(4), _s(4), fg: true), isFalse);
      expect(go(_s(5), _s(5), fg: true), isTrue);
      expect(go(_s(1), _s(15), fg: true), isTrue);
      expect(go(_s(1), _s(14), fg: true), isFalse);
    });

    test('fresh data: 1 min quiet or 5 min max', () {
      expect(go(_s(59), _s(59)), isFalse);
      expect(go(_m(1), _m(1)), isTrue);
      expect(go(_s(1), _m(5)), isTrue);
      expect(go(_s(1), _s(299)), isFalse);
    });

    test('stale data (30 min or more): 12 s quiet or 90 s max', () {
      const stale = Duration(minutes: 30);
      expect(go(_s(11), _s(11), staleness: stale), isFalse);
      expect(go(_s(12), _s(12), staleness: stale), isTrue);
      expect(go(_s(1), _s(90), staleness: stale), isTrue);
      expect(go(_s(1), _s(89), staleness: stale), isFalse);
    });

    test('backgrounded: 20 min quiet or 45 min max', () {
      expect(go(_m(19), _m(19), bg: true), isFalse);
      expect(go(_m(20), _m(20), bg: true), isTrue);
      expect(go(_s(1), _m(45), bg: true), isTrue);
      expect(go(_s(1), _m(44), bg: true), isFalse);
    });

    test('nothing pending never derives; foreground beats backgrounded', () {
      expect(
          d.shouldDerive(
              hasPending: false,
              sinceLastRecord: _m(99),
              sinceFirstPending: _m(99),
              dataStaleness: _m(99)),
          isFalse);
      expect(go(_s(5), _s(5), fg: true, bg: true), isTrue);
    });
  });

  group('DerivePacing', () {
    test('foreground: min(cores, 3), at least 1', () {
      const p = DerivePacing(background: false);
      expect([for (final c in [-1, 0, 1, 2, 3, 4, 8, 64]) p.concurrency(c)],
          [1, 1, 1, 2, 3, 3, 3, 3]);
      expect(DerivePacing.maxForegroundConcurrency, 3);
    });

    test('background: always 1', () {
      const p = DerivePacing(background: true);
      expect([for (final c in [-1, 0, 1, 2, 8]) p.concurrency(c)],
          [1, 1, 1, 1, 1]);
    });

    test('per-day timeouts: 90 s foreground, 4 min background', () {
      expect(const DerivePacing(background: false).perDayTimeout, _s(90));
      expect(const DerivePacing(background: true).perDayTimeout, _m(4));
    });
  });

  group('DeriveScheduler: settle defaults and what holds a queued pass', () {
    late List<DeriveJobKind> ran;
    late DeriveScheduler s;

    setUp(() async {
      final db = await LocalDb.instance;
      await db.delete('compute_jobs');
      final mine = ran = [];
      s = DeriveScheduler(
        run: ({required DeriveJobKind kind}) async {
          mine.add(kind);
          return const DeriveOutcome();
        },
        log: (_) {},
        onChanged: () {},
        lightSettle: const Duration(milliseconds: 10),
        heavySettle: const Duration(milliseconds: 10),
      );
    });
    tearDown(() => s.dispose());

    test('the production settle times and workout cap', () {
      final prod = DeriveScheduler(
          run: ({required kind}) async => const DeriveOutcome(),
          log: (_) {},
          onChanged: () {});
      addTearDown(prod.dispose);
      expect(prod.lightSettle, _s(8));
      expect(prod.heavySettle, _s(2));
      expect(prod.workoutHoldCap, const Duration(hours: 6));
    });

    test('an idle scheduler reports no hold', () {
      final snap = s.snapshot();
      expect(snap['offload_active'], isFalse);
      expect(snap['workout_active'], isFalse);
      expect(snap['background'], isFalse);
      expect(snap['manual_sync_hold'], isFalse);
      expect(snap['running'], isFalse);
      expect(staleHoldOf(snap), isNull);
    });

    test('nothing held: stored data runs a light pass, a capture-settled '
        'request runs a heavy one', () async {
      s.markStoredData();
      await until(() => ran.isNotEmpty);
      expect(ran, [DeriveJobKind.light]);
      await until(() => !s.running);
      s.requestHeavy();
      await until(() => ran.length == 2);
      expect(ran.last, DeriveJobKind.heavy);
    });

    for (final hold in <(String, void Function(DeriveScheduler), void Function(DeriveScheduler))>[
      ('an offload', (x) => x.setOffloadActive(true), (x) => x.setOffloadActive(false)),
      ('a live workout', (x) => x.setWorkoutActive(true), (x) => x.setWorkoutActive(false)),
    ]) {
      test('${hold.$1} parks the pass; releasing it runs it', () async {
        hold.$2(s);
        s.markStoredData();
        await until(() => s.pendingLight);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(ran, isEmpty);
        hold.$3(s);
        await until(() => ran.isNotEmpty);
        expect(ran, [DeriveJobKind.light]);
      });
    }

    test('a manual sync parks the pass; ending it without absorbing runs it',
        () async {
      final h = s.beginManualSync();
      s.markStoredData();
      await until(() => s.pendingLight);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(ran, isEmpty);
      await s.endManualSync(h, absorb: false);
      await until(() => ran.isNotEmpty);
      expect(ran, [DeriveJobKind.light]);
    });

    test('the holds map to the staleness reasons they do today', () {
      s.setWorkoutActive(true);
      expect(staleHoldOf(s.snapshot()), StaleHold.workout);
      s.setWorkoutActive(false);
      s.setOffloadActive(true);
      expect(staleHoldOf(s.snapshot()), StaleHold.sync);
      s.setOffloadActive(false);
      expect(staleHoldOf(s.snapshot()), isNull);
    });
  });

  group('the artifact warmer, through AppState: what warms after a pass', () {
    // A key per test: a stored result with a matching signature would make a
    // later test warm nothing for the wrong reason (AskSource signs 'sig-<k>').
    Future<(AppState, AskSource)> rig(String key,
        {List<String> days = const ['d1']}) async {
      final src = AskSource([key]);
      final app = AppState.forTesting();
      app.debugArtifactSource = src;
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      app.debugDeriveRun = deriveHook(days: days);
      addTearDown(app.dispose);
      return (app, src);
    }

    test('a productive pass warms the candidate keys of the changed days',
        () async {
      final (app, src) = await rig('pin-a', days: ['d2', 'd1']);
      await app.debugAfterDrain();
      await until(() => src.warmed);
      expect(src.candidateAsked, [
        ['d2', 'd1']
      ]);
      expect(src.signatureAsked, ['pin-a']);
    });

    test('a pass that computed nothing warms nothing', () async {
      final (app, src) = await rig('pin-b', days: const []);
      await app.debugAfterDrain();
      await settleMs(200);
      expect(src.candidateAsked, isEmpty);
      expect(src.signatureAsked, isEmpty);
    });

    test('an offload holds the warm (the pass itself is unaffected)',
        () async {
      final (app, src) = await rig('pin-c');
      app.debugDeriveScheduler.setOffloadActive(true);
      await app.debugAfterDrain();
      await settleMs(200);
      expect(src.warmed, isFalse);
      app.debugDeriveScheduler.setOffloadActive(false);
      await app.debugAfterDrain();
      await until(() => src.warmed);
      expect(src.signatureAsked, ['pin-c']);
    });

    test('a screen asking for one key warms exactly that key', () async {
      final (app, src) = await rig('pin-d');
      src.sigs['pin-e'] = 'sig-pin-e';
      await app.requestWarm('pin-e');
      expect(src.signatureAsked, ['pin-e']);
      expect(src.candidateAsked, isEmpty, reason: 'no candidate scan');
    });
  });
}
