import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/state/power_source.dart';

void main() {
  _pollGroup();

  test('a stale saver read cannot overwrite a newer plug edge', () async {
    final firstSaver = Completer<bool>();
    final secondSaver = Completer<bool>();
    final firstSaverStarted = Completer<void>();
    var charging = true;
    var saverReads = 0;
    final source = BatteryPowerSource(
      battery: _FakeBattery(),
      readCharging: () async => charging,
      readSaver: () {
        if (++saverReads == 1) {
          firstSaverStarted.complete();
          return firstSaver.future;
        }
        return secondSaver.future;
      },
    );
    addTearDown(source.dispose);

    final states = <bool>[];
    final sub = source.changes.listen((state) => states.add(state.charging));
    addTearDown(sub.cancel);

    final first = source.read();
    await firstSaverStarted.future;
    charging = false;
    final second = source.read();
    await Future<void>.delayed(Duration.zero);

    secondSaver.complete(false);
    await second;
    firstSaver.complete(false);
    await first;
    await Future<void>.delayed(Duration.zero);

    expect(states, [false]);
    expect((await source.read()).charging, isFalse);
  });
}

class _FakeBattery implements Battery {
  _FakeBattery();

  final StreamController<BatteryState> events =
      StreamController<BatteryState>.broadcast();
  int saverReads = 0;

  @override
  Future<int> get batteryLevel async => 50;

  @override
  Future<bool> get isInBatterySaveMode async {
    saverReads++;
    return false;
  }

  @override
  Future<BatteryState> get batteryState async => BatteryState.discharging;

  @override
  Stream<BatteryState> get onBatteryStateChanged => events.stream;
}

void _pollGroup() {
  // The OS saver has no change stream, so the source polls it; the poll runs
  // only while somebody listens and only while the owner says a saver flip
  // decides something.
  group('the saver poll', () {
    test('runs while listened, stops when the owner says the saver is moot, '
        'and on cancel and dispose', () {
      fakeAsync((async) {
        final battery = _FakeBattery();
        final source = BatteryPowerSource(battery: battery);

        expect(async.pendingTimers, isEmpty, reason: 'no listener, no poll');

        final sub = source.changes.listen((_) {});
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(1));
        async.elapse(kPowerSaverPoll * 2);
        expect(battery.saverReads, 2);

        source.watchSaver = false;
        expect(async.pendingTimers, isEmpty);
        async.elapse(kPowerSaverPoll * 3);
        expect(battery.saverReads, 2, reason: 'a moot saver is not read');

        source.watchSaver = true;
        expect(async.pendingTimers, hasLength(1));
        async.elapse(kPowerSaverPoll);
        expect(battery.saverReads, 3);

        sub.cancel();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty, reason: 'the last listener left');

        final again = source.changes.listen((_) {});
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(1));
        source.dispose();
        again.cancel();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        source.watchSaver = true;
        expect(async.pendingTimers, isEmpty, reason: 'a closed source never polls');
      });
    });

    test('a battery event still re-reads the saver with the poll off', () {
      fakeAsync((async) {
        final battery = _FakeBattery();
        final source = BatteryPowerSource(battery: battery)..watchSaver = false;
        final sub = source.changes.listen((_) {});
        async.flushMicrotasks();
        battery.events.add(BatteryState.charging);
        async.flushMicrotasks();
        expect(battery.saverReads, 1);
        sub.cancel();
        source.dispose();
      });
    });

    test('the policy asks for it where the saver decides something', () {
      const unplugged = PowerState(charging: false);
      final plugged = PowerState(charging: true, chargingSince: DateTime(2026));
      const max = CalcPowerPolicy(CalcPowerMode.maxBattery);
      const balanced = CalcPowerPolicy(CalcPowerMode.balanced);
      const eager = CalcPowerPolicy(CalcPowerMode.eager);
      expect(max.saverMatters(unplugged), isTrue);
      expect(max.saverMatters(plugged), isFalse,
          reason: 'plugged in, the hold is released whatever the saver says');
      expect(balanced.saverMatters(unplugged), isTrue);
      expect(balanced.saverMatters(plugged), isTrue);
      expect(eager.saverMatters(unplugged), isFalse);
      expect(eager.saverMatters(plugged), isFalse);
    });
  });
}
