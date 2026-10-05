// P5 (RED): the power modes wired into the scheduler, the coordinator, the
// warmer hand-off and AppState. The pure decisions are in
// calc_power_policy_test.dart; what stays the same in balanced is recorded in
// balanced_pin_test.dart (green today) and repeated here under every power
// state.
//
// ASSUMED API (new). The pure types are listed in calc_power_policy_test.dart.
//
//   lib/state/power_source.dart
//     abstract class PowerSource {
//       Future<PowerState> read();            // the state right now
//       Stream<PowerState> get changes;       // every plug / unplug / saver edge
//     }
//     class BatteryPowerSource implements PowerSource   // battery_plus 6.2.3:
//         // Battery().batteryState / onBatteryStateChanged for the plug, and
//         // Battery().isInBatterySaveMode (a Future<bool>; there is NO change
//         // stream for it in the pinned version, so re-read it on every battery
//         // state event and on a slow poll). It stamps chargingSince with
//         // clock.now() on the unplugged -> plugged edge and clears it on the
//         // way out; `unknown` counts as not charging here. The fake in
//         // support/fake_power_source.dart does the same stamping.
//
//   DeriveScheduler (lib/compute/derive_scheduler.dart)
//     void setPowerHold(bool held)   // held exactly like _offloadActive: the
//         // settle timer is cancelled, queued jobs stay durable, releasing
//         // re-arms. snapshot()['power_hold'] is that flag (false by default).
//
//   DeriveCoordinator (lib/state/derive_coordinator.dart), all optional/new:
//     CalcPowerPolicy policy;            // settable; default balanced. Setting
//                                        // it re-evaluates everything below
//                                        // (this is how a mode change lands).
//     PowerSource? debugPowerSource;     // null in production = the battery one
//     Future<void> attachPower();        // read once, subscribe to `changes`,
//                                        // apply the power hold, arm the sweep
//                                        // and the plugged-in warm. dispose()
//                                        // cancels the subscription and every
//                                        // timer.
//     void noteActivity();               // foreground activity: (re)starts the
//                                        // idleWarmDelay timer; when it fires,
//                                        // the policy allows it and nothing is
//                                        // held, the warmer warms
//                                        // candidateKeys(const []) via
//                                        // warmKeys.
//   Behaviour:
//     * the scheduler's power hold == !policy.mayDeriveAutomatically(power),
//       updated on every power / policy change. USER work is never gated:
//       afterDrain (manual sync, re-analyze), requestWarm.
//     * the warm that follows a pass (warmAfterPass) needs
//       policy.mayWarmAfterPass(power).
//     * plug-in warm: on a power event with the phone charging (and on attach
//       when already charging), when policy.mayWarmWhilePlugged(power) and
//       nothing is held, warmKeys(candidateKeys(const [])) once per event.
//     * Eager sweep: when policy.untilEagerSweep(power, clock.now()) is
//       non-null a timer is armed for that long (re-armed on every change,
//       cancelled on unplug, policy change away from eager, dispose). On fire,
//       if the phone is still charging, no workout/breathing/ECG capture
//       (warmHeld), no offload / workout / manual-sync hold: ONE
//       afterDrain(heavy: true, changedOnly: false) (the existing run), then
//       warmKeys(candidateKeys(const [])). At most one sweep per plug
//       session (one chargingSince).
//
//   AppState (lib/state/app_state.dart)
//     CalcPowerMode get calcPowerMode;                 // Prefs, default balanced
//     Future<void> setCalcPowerMode(CalcPowerMode m);  // persists + sets the
//                                                      // coordinator's policy
//     @visibleForTesting set debugPowerSource(PowerSource s);
//     @visibleForTesting Future<void> debugAttachPower(); // policy from the
//                                                      // saved mode, then
//                                                      // attachPower()
//
// Failure mode today: none of these exist (compile error).

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_outcome.dart';
import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:openstrap_edge/state/prefs.dart';

import 'support/app_state_derive_harness.dart';
import 'support/artifact_source_spy.dart';
import 'support/fake_power_source.dart';

const _db = 'openstrap_p5_wiring.db';

final _t0 = DateTime.utc(2026, 10, 4, 22, 0, 0);
Duration _m(int m, [int s = 0]) => Duration(minutes: m, seconds: s);

const _max = CalcPowerPolicy(CalcPowerMode.maxBattery);
const _bal = CalcPowerPolicy(CalcPowerMode.balanced);
const _eager = CalcPowerPolicy(CalcPowerMode.eager);

/// A coordinator with recorders for every collaborator. The derive hook counts
/// calls, so a test can tell which pass the policy let through.
class Host {
  bool warmHeld = false;
  bool disposed = false;
  final calls = <HookCall>[];
  DerivationEngine? engine;

  late final DeriveCoordinator c = DeriveCoordinator(
    engine: () => engine ??= DerivationEngine(log: (_) {}),
    profile: () => Profile.fromMap(const <String, dynamic>{}),
    log: (_) {},
    notify: () {},
    isDisposed: () => disposed,
    repo: () => null,
    warmHeld: () => warmHeld,
    refreshPhoneStepsToday: () async {},
    maybeNotifyRecoveryReady: () async {},
    runHealthExport: () async => 0,
    healthSyncEnabled: () => false,
    telemetryConsent: () => false,
    healthShareConsent: () => false,
    maybeReclaimDiskSpace: () async {},
  );

  Host() {
    c.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    c.debugDeriveRun = deriveHook(days: const ['d1'], calls: calls);
  }

  int get heavySweeps =>
      calls.where((x) => x.heavy && !x.changedOnly).length;
}

/// A host wired to [src] (power) and [art] (artifacts), policy [p], attached.
/// Call inside `fakeAsync` (or real time) and flush microtasks after.
Host _host(FakePowerSource src, CalcPowerPolicy p, {AskSource? art}) {
  final h = Host();
  h.c.policy = p;
  h.c.debugPowerSource = src;
  if (art != null) h.c.debugArtifactSource = art;
  unawaited(h.c.attachPower());
  return h;
}

void _fake(void Function(FakeAsync async) body) =>
    fakeAsync(body, initialTime: _t0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await deriveDbSetUp(_db);
    await Prefs.ensureLoaded();
    // Opened here, in the real zone: fakeAsync tests below never wait on it.
    await LocalDb.instance;
  });
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() async => (await SharedPreferences.getInstance()).clear());

  group('DeriveScheduler power hold', () {
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

    test('no power hold by default', () {
      expect(s.snapshot()['power_hold'], isFalse);
    });

    test('a power hold parks a queued pass; releasing it runs it', () async {
      s.setPowerHold(true);
      expect(s.snapshot()['power_hold'], isTrue);
      s.markStoredData();
      await until(() => s.pendingLight);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(ran, isEmpty, reason: 'held: no timer, no drain');
      s.setPowerHold(false);
      await until(() => ran.isNotEmpty);
      expect(ran, [DeriveJobKind.light]);
      expect(s.snapshot()['power_hold'], isFalse);
    });

    test('a heavy request is parked the same way', () async {
      s.setPowerHold(true);
      s.requestHeavy();
      await until(() => s.pendingHeavy);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(ran, isEmpty);
      s.setPowerHold(false);
      await until(() => ran.isNotEmpty);
      expect(ran, [DeriveJobKind.heavy]);
    });

    test('the power hold stacks with the others: it alone releasing is not '
        'enough while a workout holds', () async {
      s.setPowerHold(true);
      s.setWorkoutActive(true);
      s.markStoredData();
      await until(() => s.pendingLight);
      s.setPowerHold(false);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(ran, isEmpty);
      s.setWorkoutActive(false);
      await until(() => ran.isNotEmpty);
    });

    test('setting the same value twice is harmless', () {
      s.setPowerHold(true);
      s.setPowerHold(true);
      s.setPowerHold(false);
      s.setPowerHold(false);
      expect(s.snapshot()['power_hold'], isFalse);
    });
  });

  group('coordinator: the scheduler follows the policy and the power state', () {
    bool held(Host h) => h.c.scheduler.snapshot()['power_hold'] == true;

    test('Maximum battery: held exactly when unplugged AND under the saver',
        () {
      _fake((async) {
        final src = FakePowerSource(charging: false, powerSaver: true);
        final h = _host(src, _max);
        async.flushMicrotasks();
        expect(held(h), isTrue, reason: 'unplugged + saver');
        src.plug();
        async.flushMicrotasks();
        expect(held(h), isFalse, reason: 'plugged in');
        src.unplug();
        async.flushMicrotasks();
        expect(held(h), isTrue, reason: 'unplugged again, saver still on');
        src.setSaver(false);
        async.flushMicrotasks();
        expect(held(h), isFalse, reason: 'saver off');
        src.setSaver(true);
        async.flushMicrotasks();
        expect(held(h), isTrue, reason: 'saver back on');
        h.c.dispose();
      });
    });

    test('balanced and Eager never hold, in any of the four power states', () {
      _fake((async) {
        for (final p in [_bal, _eager]) {
          final src = FakePowerSource();
          final h = _host(src, p);
          async.flushMicrotasks();
          for (final plugged in [false, true]) {
            for (final saver in [false, true]) {
              if (plugged) {
                src.plug(saver: saver);
                async.flushMicrotasks();
              } else {
                src.unplug(saver: saver);
                async.flushMicrotasks();
              }
              expect(held(h), isFalse,
                  reason: '${p.mode.name} plugged=$plugged saver=$saver');
            }
          }
          h.c.dispose();
        }
      });
    });

    test('a mode change applies at once, from the same power state', () {
      _fake((async) {
        final src = FakePowerSource(charging: false, powerSaver: true);
        final h = _host(src, _max);
        async.flushMicrotasks();
        expect(held(h), isTrue);
        h.c.policy = _bal;
        async.flushMicrotasks();
        expect(held(h), isFalse, reason: 'balanced does not defer');
        h.c.policy = _max;
        async.flushMicrotasks();
        expect(held(h), isTrue);
        h.c.policy = _eager;
        async.flushMicrotasks();
        expect(held(h), isFalse);
        h.c.dispose();
      });
    });

    test('the power hold shows up in the snapshot the staleness line reads',
        () {
      _fake((async) {
        final src = FakePowerSource(charging: false, powerSaver: true);
        final h = _host(src, _max);
        async.flushMicrotasks();
        expect(h.c.scheduler.snapshot()['power_hold'], isTrue);
        h.c.dispose();
      });
    });

    test('dispose drops the subscription', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _max);
        async.flushMicrotasks();
        expect(src.hasListener, isTrue);
        h.c.dispose();
        expect(src.hasListener, isFalse);
      });
    });
  });

  group('coordinator: user-triggered work is never gated', () {
    test('Maximum battery, unplugged, saver on: a user pass still runs', () {
      _fake((async) {
        final src = FakePowerSource(charging: false, powerSaver: true);
        final h = _host(src, _max);
        async.flushMicrotasks();
        expect(h.c.scheduler.snapshot()['power_hold'], isTrue);
        // The manual-sync / re-analyze entry: not `automatic`.
        unawaited(h.c.afterDrain(heavy: true));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1));
        expect(h.calls.single.heavy, isTrue);
        h.c.dispose();
      });
    });

    test('Maximum battery, unplugged, saver on: a screen asking for an '
        'artifact still gets it warmed', () {
      _fake((async) {
        final src = FakePowerSource(charging: false, powerSaver: true);
        final art = AskSource(['screen-key']);
        final h = _host(src, _max, art: art);
        async.flushMicrotasks();
        unawaited(h.c.requestWarm('screen-key'));
        async.flushMicrotasks();
        expect(art.signatureAsked, ['screen-key']);
        h.c.dispose();
      });
    });
  });

  group('idle warming', () {
    // Foreground activity restarts a 30 s timer; the policy and the holds are
    // read when it fires.
    test('balanced: 30 s after the last activity, and not a second before', () {
      _fake((async) {
        final art = AskSource(['idle-a']);
        final h = _host(FakePowerSource(), _bal, art: art);
        async.flushMicrotasks();
        h.c.noteActivity();
        async.elapse(const Duration(seconds: 29));
        expect(art.warmed, isFalse, reason: 'at 0:29');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(art.signatureAsked, ['idle-a'], reason: 'at 0:30');
        expect(art.candidateAsked, [<String>[]],
            reason: 'the full candidate set, no changed days');
        h.c.dispose();
      });
    });

    test('more activity restarts the wait', () {
      _fake((async) {
        final art = AskSource(['idle-c']);
        final h = _host(FakePowerSource(), _bal, art: art);
        async.flushMicrotasks();
        h.c.noteActivity();
        async.elapse(const Duration(seconds: 20));
        h.c.noteActivity();
        async.elapse(const Duration(seconds: 29));
        expect(art.warmed, isFalse, reason: '0:49: 29 s since the last');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(art.warmed, isTrue, reason: '0:50: 30 s since the last');
        h.c.dispose();
      });
    });

    test('balanced under the OS power saver: never', () {
      _fake((async) {
        final art = AskSource(['idle-d']);
        final h = _host(FakePowerSource(powerSaver: true), _bal, art: art);
        async.flushMicrotasks();
        h.c.noteActivity();
        async.elapse(_m(10));
        async.flushMicrotasks();
        expect(art.warmed, isFalse);
        h.c.dispose();
      });
    });

    test('the saver coming on during the wait suppresses it at the end', () {
      _fake((async) {
        final src = FakePowerSource();
        final art = AskSource(['idle-e']);
        final h = _host(src, _bal, art: art);
        async.flushMicrotasks();
        h.c.noteActivity();
        async.elapse(const Duration(seconds: 10));
        src.setSaver(true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();
        expect(art.warmed, isFalse);
        h.c.dispose();
      });
    });

    test('Maximum battery: no background warming at all', () {
      _fake((async) {
        final art = AskSource(['idle-f']);
        final h = _host(FakePowerSource(), _max, art: art);
        async.flushMicrotasks();
        h.c.noteActivity();
        async.elapse(_m(10));
        async.flushMicrotasks();
        expect(art.warmed, isFalse);
        h.c.dispose();
      });
    });

    test('Eager ignores the saver', () {
      _fake((async) {
        final art = AskSource(['idle-g']);
        final h = _host(FakePowerSource(powerSaver: true), _eager, art: art);
        async.flushMicrotasks();
        h.c.noteActivity();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(art.warmed, isTrue);
        h.c.dispose();
      });
    });

    test('a live session or the background (warmHeld) stops it', () {
      _fake((async) {
        final art = AskSource(['idle-h']);
        final h = _host(FakePowerSource(), _bal, art: art);
        h.warmHeld = true;
        async.flushMicrotasks();
        h.c.noteActivity();
        async.elapse(_m(2));
        async.flushMicrotasks();
        expect(art.warmed, isFalse);
        h.c.dispose();
      });
    });

    test('dispose cancels the idle timer', () {
      _fake((async) {
        final h = _host(FakePowerSource(), _bal, art: AskSource(['idle-i']));
        async.flushMicrotasks();
        h.c.noteActivity();
        expect(async.pendingTimers, isNotEmpty);
        h.c.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('warming while plugged in', () {
    test('balanced, no saver: plugging in warms the recent artifacts', () {
      _fake((async) {
        final src = FakePowerSource();
        final art = AskSource(['plug-a']);
        final h = _host(src, _bal, art: art);
        async.flushMicrotasks();
        expect(art.warmed, isFalse, reason: 'unplugged: only idle warming');
        src.plug();
        async.flushMicrotasks();
        async.flushMicrotasks();
        expect(art.signatureAsked, ['plug-a']);
        h.c.dispose();
      });
    });

    test('balanced under the saver, and Maximum battery: plugging in warms '
        'nothing', () {
      _fake((async) {
        final src = FakePowerSource(powerSaver: true);
        final art = AskSource(['plug-b']);
        final h = _host(src, _bal, art: art);
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.flushMicrotasks();
        expect(art.warmed, isFalse, reason: 'balanced + saver');
        h.c.dispose();

        final src2 = FakePowerSource();
        final art2 = AskSource(['plug-c']);
        final h2 = _host(src2, _max, art: art2);
        async.flushMicrotasks();
        src2.plug();
        async.flushMicrotasks();
        async.flushMicrotasks();
        expect(art2.warmed, isFalse, reason: 'Maximum battery');
        h2.c.dispose();
      });
    });
  });

  group('the Eager plug-in sweep (fake time)', () {
    test('4:59 plugged: nothing; 5:00: one heavy full pass', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(4, 59));
        async.flushMicrotasks();
        expect(h.calls, isEmpty, reason: 'at 4:59');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1), reason: 'at 5:00');
        expect(h.calls.single.heavy, isTrue);
        expect(h.calls.single.changedOnly, isFalse,
            reason: 'the full sweep, not the changed-only light pass');
        h.c.dispose();
      });
    });

    test('the 5:00 counts from the plug-in, not from attach: plugged at 0:00, '
        'attached at 2:00, due at 5:00', () {
      _fake((async) {
        final src = FakePowerSource(charging: true); // since _t0
        async.elapse(_m(2));
        final h = _host(src, _eager);
        async.flushMicrotasks();
        async.elapse(_m(2, 59));
        async.flushMicrotasks();
        expect(h.calls, isEmpty, reason: 'at 4:59');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1), reason: 'at 5:00');
        h.c.dispose();
      });
    });

    test('unplug at 4:00: no sweep, and no timer left', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(4));
        expect(async.pendingTimers, isNotEmpty, reason: 'armed while plugged');
        src.unplug();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty, reason: 'cancelled on unplug');
        async.elapse(_m(30));
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        h.c.dispose();
      });
    });

    test('unplug at 4:00, replug at 4:30: due at 9:30, not at 5:00', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(4));
        src.unplug();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(0, 30)); // 5:00 on the first clock
        async.flushMicrotasks();
        expect(h.calls, isEmpty, reason: '5:00 on the old clock');
        async.elapse(_m(4, 29));
        async.flushMicrotasks();
        expect(h.calls, isEmpty, reason: '9:29');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1), reason: '9:30');
        h.c.dispose();
      });
    });

    test('a mode switch away mid-wait cancels it; switching back resumes the '
        'same plug clock', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(3));
        h.c.policy = _bal;
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty, reason: 'no sweep timer in balanced');
        async.elapse(_m(1));
        h.c.policy = _eager; // 4:00 in: 1:00 left
        async.flushMicrotasks();
        expect(async.pendingTimers, isNotEmpty);
        async.elapse(_m(0, 59));
        async.flushMicrotasks();
        expect(h.calls, isEmpty, reason: 'at 4:59');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1), reason: 'at 5:00 of the plug');
        h.c.dispose();
      });
    });

    test('switching to Maximum battery mid-wait cancels it for good', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(2));
        h.c.policy = _max;
        async.flushMicrotasks();
        async.elapse(_m(60));
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        expect(async.pendingTimers, isEmpty);
        h.c.dispose();
      });
    });

    test('Eager ignores the saver: plugged under the saver, due at 5:00', () {
      _fake((async) {
        final src = FakePowerSource(powerSaver: true);
        final h = _host(src, _eager);
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(5));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1));
        h.c.dispose();
      });
    });

    test('balanced and Maximum battery: plugged for an hour, no sweep and no '
        'timer', () {
      _fake((async) {
        for (final p in [_bal, _max]) {
          final src = FakePowerSource();
          final h = _host(src, p);
          async.flushMicrotasks();
          src.plug();
          async.flushMicrotasks();
          async.elapse(_m(60));
          async.flushMicrotasks();
          expect(h.calls, isEmpty, reason: p.mode.name);
          expect(async.pendingTimers, isEmpty, reason: p.mode.name);
          h.c.dispose();
        }
      });
    });

    test('dispose before 5:00: nothing fires, no timer, no subscription', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(2));
        h.c.dispose();
        expect(async.pendingTimers, isEmpty);
        expect(src.hasListener, isFalse);
        async.elapse(_m(30));
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
      });
    });

    test('a live workout holds the sweep (it is not run, not queued behind)',
        () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        async.flushMicrotasks();
        h.c.scheduler.setWorkoutActive(true);
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(30));
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        h.c.scheduler.setWorkoutActive(false); // cancels the hold-cap timer
        h.c.dispose();
      });
    });

    test('a live capture or the background (warmHeld) holds the sweep', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        h.warmHeld = true;
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(30));
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        h.c.dispose();
      });
    });

    test('an offload holds the sweep', () {
      _fake((async) {
        final src = FakePowerSource();
        final h = _host(src, _eager);
        async.flushMicrotasks();
        h.c.scheduler.setOffloadActive(true);
        src.plug();
        async.flushMicrotasks();
        async.elapse(_m(30));
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        h.c.scheduler.setOffloadActive(false);
        h.c.dispose();
      });
    });
  });

  group('the Eager sweep calls the existing run and warm paths (real time, '
      'a 30 ms plug delay)', () {
    const quick =
        CalcPowerPolicy(CalcPowerMode.eager, eagerPlugDelay: Duration(milliseconds: 30));

    test('one heavy full pass, then the warm of every candidate artifact; '
        'later power events in the same plug session add nothing', () async {
      final src = FakePowerSource();
      final art = AskSource(['sweep-a', 'sweep-b']);
      final h = _host(src, quick, art: art);
      addTearDown(h.c.dispose);
      await settleMs(20);
      src.plug();
      await until(() => h.calls.isNotEmpty);
      expect(h.calls.single.heavy, isTrue);
      expect(h.calls.single.changedOnly, isFalse);
      await until(() => art.signatureAsked.length >= 2);
      expect(art.signatureAsked, containsAll(['sweep-a', 'sweep-b']));
      expect(art.candidateAsked, isNotEmpty);

      src.setSaver(true);
      src.setSaver(false);
      src.plug(); // a duplicate event: still the same session
      await settleMs(250);
      expect(h.heavySweeps, 1, reason: 'once per plug session');
      expect(h.calls, hasLength(1));
    });

    test('a new plug session sweeps again', () async {
      final src = FakePowerSource();
      final art = AskSource(['sweep-c']);
      final h = _host(src, quick, art: art);
      addTearDown(h.c.dispose);
      await settleMs(20);
      src.plug();
      await until(() => h.calls.length == 1);
      await settleMs(100);
      src.unplug();
      await settleMs(20);
      src.plug();
      await until(() => h.calls.length == 2);
      expect(h.heavySweeps, 2);
    });
  });

  group('AppState: the saved mode, and balanced == today in every power state',
      () {
    Future<(AppState, FakePowerSource, AskSource)> rig(String key,
        {bool plugged = false, bool saver = false}) async {
      final src = FakePowerSource(charging: plugged, powerSaver: saver);
      final art = AskSource([key]);
      final app = AppState.forTesting();
      app.debugArtifactSource = art;
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      app.debugDeriveRun = deriveHook(days: ['d1']);
      (app as dynamic).debugPowerSource = src;
      addTearDown(app.dispose);
      return (app, src, art);
    }

    Future<void> attach(AppState a) => (a as dynamic).debugAttachPower();
    Future<void> setMode(AppState a, CalcPowerMode m) =>
        (a as dynamic).setCalcPowerMode(m);

    test('the default is balanced', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect((app as dynamic).calcPowerMode, CalcPowerMode.balanced);
    });

    test('a saved mode is the one the coordinator attaches with', () async {
      final (app, _, _) = await rig('as-a', saver: true);
      await setMode(app, CalcPowerMode.maxBattery);
      expect((app as dynamic).calcPowerMode, CalcPowerMode.maxBattery);
      await attach(app);
      expect(app.debugDeriveScheduler.snapshot()['power_hold'], isTrue,
          reason: 'Maximum battery, unplugged, saver on');
      await setMode(app, CalcPowerMode.balanced);
      expect(app.debugDeriveScheduler.snapshot()['power_hold'], isFalse,
          reason: 'the change lands at once');
    });

    // What balanced does today (balanced_pin_test.dart): a productive pass
    // warms; nothing about the power state changes that, or the pass.
    for (final plugged in [false, true]) {
      for (final saver in [false, true]) {
        test('balanced, plugged=$plugged saver=$saver: the pass runs, nothing '
            'is held, the post-pass warm happens', () async {
          final (app, _, art) = await rig(
              'bal-$plugged-$saver', plugged: plugged, saver: saver);
          await setMode(app, CalcPowerMode.balanced);
          await attach(app);
          expect(app.debugDeriveScheduler.snapshot()['power_hold'], isFalse);
          expect(app.staleHold, isNull);
          await app.debugAfterDrain();
          await until(() => art.candidateAsked.any((d) => d.length == 1));
          expect(art.candidateAsked.any((d) => d.length == 1 && d.first == 'd1'),
              isTrue,
              reason: 'the changed days of the pass');
          expect(art.signatureAsked, contains('bal-$plugged-$saver'));
        });
      }
    }

    test('Maximum battery: the pass runs but the post-pass warm does not',
        () async {
      final (app, _, art) = await rig('max-a', plugged: true);
      await setMode(app, CalcPowerMode.maxBattery);
      await attach(app);
      await app.debugAfterDrain();
      await settleMs(300);
      expect(art.signatureAsked, isEmpty);
      expect(art.candidateAsked, isEmpty);
    });

    test('Eager: the post-pass warm happens, under the saver too', () async {
      final (app, _, art) = await rig('eager-a', saver: true);
      await setMode(app, CalcPowerMode.eager);
      await attach(app);
      await app.debugAfterDrain();
      await until(() => art.signatureAsked.contains('eager-a'));
    });

    test('a user pass and a screen\'s warm run in Maximum battery under the '
        'saver', () async {
      final (app, _, art) = await rig('max-b', saver: true);
      art.sigs['max-screen'] = 's';
      await setMode(app, CalcPowerMode.maxBattery);
      await attach(app);
      expect(app.debugDeriveScheduler.snapshot()['power_hold'], isTrue);
      await app.requestWarm('max-screen');
      expect(art.signatureAsked, ['max-screen']);
    });
  });
}
