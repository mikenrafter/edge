// Two promises of the derive coordinator that a busy engine or a live session
// used to break:
//   * the Eager plug-in sweep is only spent by a pass the engine accepted; a
//     refused one (engine busy) looks again, and a finished sweep is not rerun;
//   * a screen's warm request that arrived under a hold is kept and runs when
//     the hold is over, instead of vanishing.

import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';
import 'package:openstrap_edge/state/power_source.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/last_result_cache.dart';

import '../p5/support/ask_source.dart';
import '../p5/support/fake_power_source.dart';
import '../split8aj/support/derive_harness.dart';

const _db = 'openstrap_review_job1_coordinator.db';

final _t0 = DateTime.utc(2026, 10, 4, 22, 0, 0);
const _eager = CalcPowerPolicy(CalcPowerMode.eager);

class _Host {
  bool warmHeld = false;
  final calls = <HookCall>[];
  int refuse = 0;
  Completer<void>? gate; // holds a pass open until completed

  late final DeriveCoordinator c = DeriveCoordinator(
    engine: () => DerivationEngine(log: (_) {}),
    profile: () => Profile.fromMap(const <String, dynamic>{}),
    log: (_) {},
    notify: () {},
    isDisposed: () => false,
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

  _Host() {
    c.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    // The engine answers "busy" (a thrown pass reads as a failed outcome, the
    // same `failed` the real refusal sets) for the first [refuse] calls.
    final ok = deriveHook(days: const ['d1']);
    c.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      calls.add(HookCall(heavy, changedOnly));
      if (refuse > 0) {
        refuse--;
        throw StateError('busy');
      }
      await gate?.future;
      return ok(
        heavy: heavy,
        changedOnly: changedOnly,
        onScope: onScope,
        onScopeDays: onScopeDays,
        onDayDone: onDayDone,
        onCrossDay: onCrossDay,
      );
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await deriveDbSetUp(_db);
    await Prefs.ensureLoaded();
    await LocalDb.instance;
  });
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() async => (await SharedPreferences.getInstance()).clear());

  group('the Eager sweep and a busy engine', () {
    void plugged(void Function(FakeAsync async, _Host h) body,
        {int refuse = 0}) {
      fakeAsync((async) {
        final src = FakePowerSource();
        final h = _Host()..refuse = refuse;
        h.c.policy = _eager;
        h.c.debugPowerSource = src;
        unawaited(h.c.attachPower());
        async.flushMicrotasks();
        src.plug();
        async.flushMicrotasks();
        try {
          body(async, h);
        } finally {
          h.c.dispose();
        }
      }, initialTime: _t0);
    }

    test('a refused sweep is retried, not consumed until the next unplug', () {
      plugged(refuse: 1, (async, h) {
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1), reason: 'the refused sweep at 5:00');

        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(h.calls, hasLength(2), reason: 'looked again a minute later');
        expect(h.calls.last.heavy, isTrue);
        expect(h.calls.last.changedOnly, isFalse);
      });
    });

    test('power events while a sweep runs do not start a second one', () {
      fakeAsync((async) {
        final src = FakePowerSource();
        final h = _Host()..gate = Completer<void>();
        h.c.policy = _eager;
        h.c.debugPowerSource = src;
        unawaited(h.c.attachPower());
        async.flushMicrotasks();
        src.plug();
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1), reason: 'the sweep is running');

        src.setSaver(true);
        src.plug();
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1), reason: 'not run twice at once');

        h.gate!.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1), reason: 'and not again once done');
        h.c.dispose();
      }, initialTime: _t0);
    });

    test('an accepted sweep is spent: nothing runs again this plug session',
        () {
      plugged((async, h) {
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1));

        async.elapse(const Duration(minutes: 30));
        async.flushMicrotasks();
        expect(h.calls, hasLength(1));
      });
    });
  });

  _saverWatchGroup();

  group('a warm request under a hold', () {
    test('runs when foreground activity finds the hold over', () async {
      LastResultCache.instance.clear();
      final h = _Host();
      final art = AskSource(const ['k']);
      h.c.debugArtifactSource = art;
      h.warmHeld = true; // a live breathing / ECG session
      final start = h.c.insightsRevision.value;

      await h.c.requestWarm('k');
      expect(art.warmed, isFalse, reason: 'nothing computes under a hold');
      expect(h.c.insightsRevision.value, start);

      h.warmHeld = false;
      h.c.noteActivity();
      await until(() => h.c.insightsRevision.value > start);
      expect(art.signatureAsked, ['k']);
      expect(h.c.insightsRevision.value, greaterThan(start));
      h.c.dispose();
    });
  });
}

/// A battery whose plug events the test sends; the saver reads are counted by
/// the source's own reader.
class _Battery implements Battery {
  final events = StreamController<BatteryState>.broadcast();

  @override
  Future<int> get batteryLevel async => 50;

  @override
  Future<bool> get isInBatterySaveMode async => false;

  @override
  Future<BatteryState> get batteryState async => BatteryState.discharging;

  @override
  Stream<BatteryState> get onBatteryStateChanged => events.stream;
}

void _saverWatchGroup() {
  // The coordinator owns the saver poll's switch: on exactly when a flip of the
  // OS saver would change a decision (CalcPowerPolicy.saverMatters).
  group('the saver poll follows the power policy', () {
    void scenario(
      void Function(
        _Host h,
        bool Function() polls,
        void Function(bool on) plug,
      ) body,
    ) {
      fakeAsync((async) {
        final battery = _Battery();
        var plugged = false;
        var saverReads = 0;
        final h = _Host();
        final src = BatteryPowerSource(
          battery: battery,
          readCharging: () async => plugged,
          readSaver: () async {
            saverReads++;
            return false;
          },
        );
        h.c.debugPowerSource = src;

        // Whether the poll read the saver during a few minutes of quiet.
        bool polls() {
          async.flushMicrotasks();
          final before = saverReads;
          async.elapse(const Duration(minutes: 3));
          async.flushMicrotasks();
          return saverReads > before;
        }

        void plug(bool on) {
          plugged = on;
          battery.events
              .add(on ? BatteryState.charging : BatteryState.discharging);
          async.flushMicrotasks();
        }

        try {
          body(h, polls, plug);
        } finally {
          h.c.dispose();
          src.dispose();
        }
      }, initialTime: _t0);
    }

    Future<void> attach(_Host h) => h.c.attachPower();

    test('Eager never needs it, Balanced always does', () {
      scenario((h, polls, plug) {
        h.c.policy = _eager;
        unawaited(attach(h));
        expect(polls(), isFalse, reason: 'Eager');
        h.c.policy = const CalcPowerPolicy(CalcPowerMode.balanced);
        expect(polls(), isTrue, reason: 'Balanced');
        h.c.policy = _eager;
        expect(polls(), isFalse, reason: 'Eager again');
      });
    });

    test('Maximum battery needs it only while unplugged, as power changes',
        () {
      scenario((h, polls, plug) {
        h.c.policy = const CalcPowerPolicy(CalcPowerMode.maxBattery);
        unawaited(attach(h));
        expect(polls(), isTrue, reason: 'unplugged');
        plug(true);
        expect(polls(), isFalse, reason: 'plugged in');
        plug(false);
        expect(polls(), isTrue, reason: 'unplugged again');
      });
    });
  });
}
