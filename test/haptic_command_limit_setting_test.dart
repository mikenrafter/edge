// The band command limit as a developer setting (rule 6): how many band haptic
// commands may be sent in any 2 minutes. 10..60, 30 until changed, clamped,
// stored, and what the ledger and the haptics service follow.
//
// New API pinned:
//   Prefs.hapticsCommandLimit      const String 'haptics_command_limit'
//   Prefs.hapticCommandLimit       static int getter: the stored value clamped
//                                  to 10..60, 30 when unset (synchronous, like
//                                  allowLongHaptics)
//   Prefs.setHapticCommandLimit(n) clamps n to 10..60, caches it for an
//                                  immediate read and writes it as an int
//   HapticsService(commandLimit: int Function()?)  handed to the service's own
//                                  ledger (when no ledger is passed), read at
//                                  every use; null is the default 30
// The screen control is pinned in haptic_command_limit_ui_test.dart and the
// AppState wiring in gesture_haptic_budget_wiring_test.dart.

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Port implements BandHapticsPort {
  int buzzes = 0;
  @override
  bool get isConnected => true;
  @override
  String? get generation => null;
  @override
  Future<bool> buzzBand({int holdMs = 0}) async {
    buzzes++;
    return true;
  }

  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) async => false;
}

const _key = 'haptics_command_limit';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the stored setting', () {
    // First on purpose: Prefs caches its SharedPreferences instance.
    test('the key is haptics_command_limit and it defaults to 30 (10..60)',
        () async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      expect(Prefs.hapticsCommandLimit, _key);
      expect(Prefs.hapticCommandLimit, 30);
      expect(kBandCommandLimitMin, 10);
      expect(kBandCommandLimitMax, 60);
      expect(kBandCommandLimitDefault, 30);
    });

    test('a value in range is read back at once', () async {
      await Prefs.ensureLoaded();
      for (final v in const [10, 11, 30, 45, 59, 60]) {
        Prefs.setHapticCommandLimit(v);
        expect(Prefs.hapticCommandLimit, v);
      }
    });

    test('the bounds clamp on write: below 10 is 10, above 60 is 60, and the '
        'stored value is the clamped one', () async {
      await Prefs.ensureLoaded();
      final sp = await SharedPreferences.getInstance();
      for (final (given, kept) in const [
        (9, 10),
        (0, 10),
        (-5, 10),
        (61, 60),
        (1000, 60),
      ]) {
        Prefs.setHapticCommandLimit(given);
        expect(Prefs.hapticCommandLimit, kept, reason: '$given');
        expect(sp.getInt(_key), kept, reason: '$given is stored as $kept');
      }
    });

    test('an out-of-range value already in storage is clamped on read',
        () async {
      await Prefs.ensureLoaded();
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_key, 999);
      expect(Prefs.hapticCommandLimit, 60);
      await sp.setInt(_key, 2);
      expect(Prefs.hapticCommandLimit, 10);
      await sp.setInt(_key, 25);
      expect(Prefs.hapticCommandLimit, 25);
    });

    test('it is persisted: the platform store holds it, not only the cache',
        () async {
      await Prefs.ensureLoaded();
      Prefs.setHapticCommandLimit(42);
      await pumpEventQueue();
      final sp = await SharedPreferences.getInstance();
      await sp.reload(); // read it back from the store
      expect(sp.getInt(_key), 42);
      expect(Prefs.hapticCommandLimit, 42);
    });
  });

  group('the haptics service follows it', () {
    test('its ledger uses the limit, read at every use', () {
      var limit = 20;
      final svc = HapticsService(
          port: _Port(), allowLong: () => false, commandLimit: () => limit);
      expect(svc.commandsLeft, 20);
      limit = 60;
      expect(svc.commandsLeft, 60);
      limit = 10;
      expect(svc.commandsLeft, 10);
    });

    test('it is clamped to 10..60 there too, and null is the default 30', () {
      expect(
          HapticsService(
                  port: _Port(), allowLong: () => false, commandLimit: () => 3)
              .commandsLeft,
          10);
      expect(
          HapticsService(
                  port: _Port(), allowLong: () => false, commandLimit: () => 99)
              .commandsLeft,
          60);
      expect(HapticsService(port: _Port(), allowLong: () => false).commandsLeft,
          30);
    });

    test('runJob refuses a job over the limit in force and plays one at it',
        () {
      fakeAsync((async) {
        final port = _Port();
        final svc = HapticsService(
            port: port, allowLong: () => false, commandLimit: () => 12);
        BuzzDelivery? big, fits;
        svc.runJob(13, (job) async => BuzzDelivery.complete).then((v) => big = v);
        async.flushMicrotasks();
        expect(big, BuzzDelivery.rejected);
        svc.runJob(12, (job) async {
          for (var i = 0; i < 12; i++) {
            await job.write(() => port.buzzBand());
          }
          return BuzzDelivery.complete;
        }).then((v) => fits = v);
        async.elapse(const Duration(seconds: 5));
        expect(fits, BuzzDelivery.complete);
        expect(port.buzzes, 12);
        expect(svc.commandsLeft, 0);
      });
    });

    test('a change of the limit takes effect on the next job without a new '
        'service', () {
      fakeAsync((async) {
        var limit = 30;
        final svc = HapticsService(
            port: _Port(), allowLong: () => false, commandLimit: () => limit);
        svc.ledger.record(20, clock.now());
        expect(svc.commandsLeft, 10);
        limit = 15;
        expect(svc.commandsLeft, 0);
        BuzzDelivery? out;
        svc.runJob(1, (job) async => BuzzDelivery.complete).then((v) => out = v);
        async.elapse(const Duration(seconds: 30));
        expect(out, isNull,
            reason: 'still waiting for the window (not dropped, not played)');
        limit = 60;
        expect(svc.commandsLeft, 40);
      });
    });
  });
}
