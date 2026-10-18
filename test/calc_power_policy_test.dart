// The pure power-mode policy. No clock, timer, database or platform:
// the time is an argument, so every case is exact.
//
// API (new; nothing below exists today)
//
//   lib/compute/calc_power_policy.dart
//     enum CalcPowerMode { maxBattery, balanced, eager }
//         Persisted by name; balanced is the default (see the settings test).
//
//     class PowerState {
//       const PowerState({required bool charging, DateTime? chargingSince,
//                         bool powerSaver = false});
//       final bool charging;
//       final DateTime? chargingSince;  // start of the CURRENT continuous
//                                       // external-power stretch; null when
//                                       // unplugged or when the start is not
//                                       // known (then no sweep is due)
//       final bool powerSaver;          // the OS power saver (Android power
//                                       // save / iOS low power mode)
//       // value ==/hashCode
//       static const PowerState unplugged = PowerState(charging: false);
//     }
//
//     class CalcPowerPolicy {
//       const CalcPowerPolicy(this.mode,
//           {Duration eagerPlugDelay = const Duration(minutes: 5),
//            Duration idleWarmDelay = const Duration(seconds: 30)});
//       final CalcPowerMode mode;
//       final Duration eagerPlugDelay, idleWarmDelay;
//
//       // May an AUTOMATIC derive pass run now? (the scheduler's gate; a user
//       // action never asks)
//       bool mayDeriveAutomatically(PowerState p);
//       // Worker cap for a pass, null = no cap (today). Feeds DerivePacing.
//       int? get maxWorkers;
//       // Idle warming: Home/Health artifacts once the foreground has been
//       // idle for idleWarmDelay.
//       bool mayWarmIdle(PowerState p);
//       // Warming of recent artifacts the moment/while the phone is plugged in.
//       bool mayWarmWhilePlugged(PowerState p);
//       // The warm that follows a derive pass that computed days (today's
//       // warmAfterPass).
//       bool mayWarmAfterPass(PowerState p);
//       // Eager plug-in sweep: time left until it is due (Duration.zero when
//       // due), null when it cannot become due (mode != eager, not charging,
//       // or chargingSince unknown). Measured against chargingSince, so a mode
//       // switch never resets the plug clock; an unplug/replug does (the
//       // source stamps a new chargingSince).
//       Duration? untilEagerSweep(PowerState p, DateTime now);
//       bool eagerSweepDue(PowerState p, DateTime now); // == zero
//       // The DeriveDebouncer tiers for this mode.
//       DeriveDebouncer get debouncer;
//     }
//
//   lib/compute/derive_pacing.dart
//     DerivePacing({required bool background, int? maxWorkers})
//         concurrency(cores) never exceeds maxWorkers (null = today's rule).

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/compute/derive_pacing.dart';

final _t0 = DateTime.utc(2026, 10, 4, 22, 0, 0);
DateTime _at(int m, [int s = 0]) => _t0.add(Duration(minutes: m, seconds: s));

PowerState _plugged({DateTime? since, bool saver = false}) =>
    PowerState(charging: true, chargingSince: since ?? _t0, powerSaver: saver);
PowerState _unplugged({bool saver = false}) =>
    PowerState(charging: false, powerSaver: saver);

CalcPowerPolicy _p(CalcPowerMode m) => CalcPowerPolicy(m);

void main() {
  group('defaults', () {
    test('the sweep waits 5 minutes and idle warming 30 seconds', () {
      const p = CalcPowerPolicy(CalcPowerMode.balanced);
      expect(p.eagerPlugDelay, const Duration(minutes: 5));
      expect(p.idleWarmDelay, const Duration(seconds: 30));
    });

    test('three modes, balanced in the middle', () {
      expect(CalcPowerMode.values,
          [CalcPowerMode.maxBattery, CalcPowerMode.balanced, CalcPowerMode.eager]);
    });
  });

  group('the decision matrix: mode x {plugged, unplugged} x saver', () {
    // derive, warmIdle, warmWhilePlugged, warmAfterPass
    final table = <(CalcPowerMode, bool, bool), (bool, bool, bool, bool)>{
      // Maximum battery: derives unless unplugged under the saver; never warms.
      (CalcPowerMode.maxBattery, true, false): (true, false, false, false),
      (CalcPowerMode.maxBattery, true, true): (true, false, false, false),
      (CalcPowerMode.maxBattery, false, false): (true, false, false, false),
      (CalcPowerMode.maxBattery, false, true): (false, false, false, false),
      // Balanced: always derives (today); the saver suppresses the NEW warming
      // (idle, plugged-in) but not the warm that follows a pass (today).
      (CalcPowerMode.balanced, true, false): (true, true, true, true),
      (CalcPowerMode.balanced, true, true): (true, false, false, true),
      (CalcPowerMode.balanced, false, false): (true, true, false, true),
      (CalcPowerMode.balanced, false, true): (true, false, false, true),
      // Eager: ignores the saver. Plugged-in warming needs a plug.
      (CalcPowerMode.eager, true, false): (true, true, true, true),
      (CalcPowerMode.eager, true, true): (true, true, true, true),
      (CalcPowerMode.eager, false, false): (true, true, false, true),
      (CalcPowerMode.eager, false, true): (true, true, false, true),
    };
    for (final e in table.entries) {
      final (mode, plugged, saver) = e.key;
      final (derive, idle, onPower, afterPass) = e.value;
      test('${mode.name}, ${plugged ? "plugged" : "unplugged"}, '
          'saver ${saver ? "on" : "off"}', () {
        final pol = _p(mode);
        final s = plugged ? _plugged(saver: saver) : _unplugged(saver: saver);
        expect(pol.mayDeriveAutomatically(s), derive, reason: 'derive');
        expect(pol.mayWarmIdle(s), idle, reason: 'idle warm');
        expect(pol.mayWarmWhilePlugged(s), onPower, reason: 'plugged warm');
        expect(pol.mayWarmAfterPass(s), afterPass, reason: 'after-pass warm');
      });
    }

    test('chargingSince changes none of these (only the sweep reads it)', () {
      for (final m in CalcPowerMode.values) {
        final a = _p(m).mayWarmWhilePlugged(_plugged(since: _t0));
        final b = _p(m).mayWarmWhilePlugged(
            PowerState(charging: true, chargingSince: null));
        expect(a, b, reason: m.name);
      }
    });
  });

  group('one worker', () {
    test('only Maximum battery caps the pass to one worker', () {
      expect(_p(CalcPowerMode.maxBattery).maxWorkers, 1);
      expect(_p(CalcPowerMode.balanced).maxWorkers, isNull);
      expect(_p(CalcPowerMode.eager).maxWorkers, isNull);
    });

    test('DerivePacing honours the cap, foreground and background', () {
      for (final bg in [false, true]) {
        for (final cores in [0, 1, 2, 3, 4, 8]) {
          expect(DerivePacing(background: bg, maxWorkers: 1).concurrency(cores),
              1, reason: 'bg=$bg cores=$cores');
        }
      }
      expect(DerivePacing(background: false, maxWorkers: 2).concurrency(8), 2);
      expect(DerivePacing(background: false, maxWorkers: 2).concurrency(1), 1,
          reason: 'a cap never raises the count');
    });

    test('no cap is exactly today\'s rule', () {
      for (final bg in [false, true]) {
        for (final cores in [-1, 0, 1, 2, 3, 4, 8, 64]) {
          expect(DerivePacing(background: bg, maxWorkers: null).concurrency(cores),
              DerivePacing(background: bg).concurrency(cores),
              reason: 'bg=$bg cores=$cores');
        }
      }
    });
  });

  group('the Eager plug-in sweep', () {
    final eager = _p(CalcPowerMode.eager);

    test('4:59 plugged is not due; 5:00 is; 5:01 still is', () {
      final s = _plugged();
      expect(eager.eagerSweepDue(s, _at(4, 59)), isFalse);
      expect(eager.untilEagerSweep(s, _at(4, 59)), const Duration(seconds: 1));
      expect(eager.eagerSweepDue(s, _at(5)), isTrue);
      expect(eager.untilEagerSweep(s, _at(5)), Duration.zero);
      expect(eager.eagerSweepDue(s, _at(5, 1)), isTrue);
      expect(eager.untilEagerSweep(s, _at(5, 1)), Duration.zero,
          reason: 'never negative');
    });

    test('the time left counts down from the moment of plugging in', () {
      final s = _plugged();
      expect(eager.untilEagerSweep(s, _t0), const Duration(minutes: 5));
      expect(eager.untilEagerSweep(s, _at(2)), const Duration(minutes: 3));
    });

    test('unplugged: never due, however long ago it was plugged', () {
      expect(eager.untilEagerSweep(_unplugged(), _at(600)), isNull);
      expect(eager.eagerSweepDue(_unplugged(), _at(600)), isFalse);
    });

    test('plugged with an unknown start: not due (it is not guessed)', () {
      const s = PowerState(charging: true);
      expect(eager.untilEagerSweep(s, _at(600)), isNull);
      expect(eager.eagerSweepDue(s, _at(600)), isFalse);
    });

    test('the OS power saver does not hold Eager back', () {
      final s = _plugged(saver: true);
      expect(eager.eagerSweepDue(s, _at(5)), isTrue);
    });

    test('balanced and Maximum battery never run the sweep', () {
      for (final m in [CalcPowerMode.balanced, CalcPowerMode.maxBattery]) {
        expect(_p(m).untilEagerSweep(_plugged(), _at(600)), isNull, reason: m.name);
        expect(_p(m).eagerSweepDue(_plugged(), _at(600)), isFalse,
            reason: m.name);
      }
    });

    test('unplug at 4:00, replug at 4:30: the 5:00 starts over', () {
      // What a source reports: the replug carries a NEW chargingSince.
      final first = _plugged();
      expect(eager.eagerSweepDue(first, _at(3, 59)), isFalse);
      // unplugged from 4:00: nothing can be due
      expect(eager.eagerSweepDue(_unplugged(), _at(4)), isFalse);
      final again = _plugged(since: _at(4, 30));
      // 5:00 on the old clock, but only 0:30 on the new one
      expect(eager.eagerSweepDue(again, _at(5)), isFalse);
      expect(eager.untilEagerSweep(again, _at(5)), const Duration(minutes: 4, seconds: 30));
      expect(eager.eagerSweepDue(again, _at(9, 29)), isFalse);
      expect(eager.eagerSweepDue(again, _at(9, 30)), isTrue);
    });

    test('a mode switch mid-wait does not reset the plug clock', () {
      final s = _plugged();
      // 3:00 in, switched to balanced: nothing is due, nothing is armed
      expect(_p(CalcPowerMode.balanced).untilEagerSweep(s, _at(3)), isNull);
      // 4:00 in, switched back to Eager: 1:00 left, not a fresh 5:00
      expect(eager.untilEagerSweep(s, _at(4)), const Duration(minutes: 1));
      expect(eager.eagerSweepDue(s, _at(5)), isTrue);
    });

    test('the delay is the policy\'s own', () {
      const quick = CalcPowerPolicy(CalcPowerMode.eager,
          eagerPlugDelay: Duration(seconds: 90));
      expect(quick.eagerSweepDue(_plugged(), _at(1, 29)), isFalse);
      expect(quick.eagerSweepDue(_plugged(), _at(1, 30)), isTrue);
    });
  });

  group('saver toggles', () {
    test('Maximum battery unplugged: saver on defers derive, off releases it',
        () {
      final pol = _p(CalcPowerMode.maxBattery);
      expect(pol.mayDeriveAutomatically(_unplugged(saver: false)), isTrue);
      expect(pol.mayDeriveAutomatically(_unplugged(saver: true)), isFalse);
      expect(pol.mayDeriveAutomatically(_unplugged(saver: false)), isTrue);
    });

    test('plugging in releases a saver-deferred derive in Maximum battery', () {
      final pol = _p(CalcPowerMode.maxBattery);
      expect(pol.mayDeriveAutomatically(_unplugged(saver: true)), isFalse);
      expect(pol.mayDeriveAutomatically(_plugged(saver: true)), isTrue);
    });

    test('balanced: the saver turns idle warming off and back on', () {
      final pol = _p(CalcPowerMode.balanced);
      expect(pol.mayWarmIdle(_unplugged()), isTrue);
      expect(pol.mayWarmIdle(_unplugged(saver: true)), isFalse);
      expect(pol.mayWarmIdle(_unplugged()), isTrue);
    });
  });

  group('debouncer tiers', () {
    final today = const DeriveDebouncer();
    final max = _p(CalcPowerMode.maxBattery).debouncer;
    final bal = _p(CalcPowerMode.balanced).debouncer;
    final eag = _p(CalcPowerMode.eager).debouncer;

    List<Duration> fields(DeriveDebouncer d) => [
          d.staleQuietPeriod,
          d.staleMaxWait,
          d.freshQuietPeriod,
          d.freshMaxWait,
          d.staleThreshold,
          d.foregroundQuietPeriod,
          d.foregroundMaxWait,
          d.backgroundQuietPeriod,
          d.backgroundMaxWait,
        ];

    test('balanced is exactly today\'s tiers, field by field', () {
      expect(fields(bal), fields(today));
    });

    test('Maximum battery: every tier is at least the slowest one that exists '
        '(the 20 min / 45 min background tier)', () {
      for (final q in [
        max.staleQuietPeriod,
        max.freshQuietPeriod,
        max.foregroundQuietPeriod,
        max.backgroundQuietPeriod,
      ]) {
        expect(q, greaterThanOrEqualTo(today.backgroundQuietPeriod));
      }
      for (final w in [
        max.staleMaxWait,
        max.freshMaxWait,
        max.foregroundMaxWait,
        max.backgroundMaxWait,
      ]) {
        expect(w, greaterThanOrEqualTo(today.backgroundMaxWait));
      }
    });

    test('Eager: no tier is slower than today, and the common ones are faster',
        () {
      final a = fields(eag), b = fields(today);
      for (var i = 0; i < a.length; i++) {
        if (i == 4) continue; // the staleness threshold is not a wait
        expect(a[i], lessThanOrEqualTo(b[i]), reason: 'field $i');
      }
      expect(eag.freshQuietPeriod, lessThan(today.freshQuietPeriod));
      expect(eag.freshMaxWait, lessThan(today.freshMaxWait));
    });

    test('the same pending run: Eager derives no later than balanced, balanced '
        'no later than Maximum battery', () {
      bool go(DeriveDebouncer d, Duration since) => d.shouldDerive(
            hasPending: true,
            sinceLastRecord: since,
            sinceFirstPending: since,
            dataStaleness: const Duration(minutes: 1),
          );
      var seenEager = false, seenBalanced = false;
      for (var s = 0; s <= 50 * 60; s += 5) {
        final d = Duration(seconds: s);
        final e = go(eag, d), b = go(bal, d), m = go(max, d);
        if (m) expect(b, isTrue, reason: 'balanced already derived at ${s}s');
        if (b) expect(e, isTrue, reason: 'eager already derived at ${s}s');
        seenEager |= e;
        seenBalanced |= b;
      }
      expect(seenEager && seenBalanced, isTrue);
    });

    test('Maximum battery keeps a foreground wait of 5 s from deriving; '
        'balanced (today) derives', () {
      bool go(DeriveDebouncer d) => d.shouldDerive(
            hasPending: true,
            sinceLastRecord: const Duration(seconds: 5),
            sinceFirstPending: const Duration(seconds: 5),
            dataStaleness: const Duration(minutes: 1),
            isForeground: true,
          );
      expect(go(bal), isTrue);
      expect(go(max), isFalse);
    });
  });

  group('balanced == today (pure surface)', () {
    final bal = _p(CalcPowerMode.balanced);
    test('derives automatically in every power state', () {
      for (final plugged in [true, false]) {
        for (final saver in [true, false]) {
          final s = plugged ? _plugged(saver: saver) : _unplugged(saver: saver);
          expect(bal.mayDeriveAutomatically(s), isTrue,
              reason: 'plugged=$plugged saver=$saver');
          expect(bal.mayWarmAfterPass(s), isTrue,
              reason: 'plugged=$plugged saver=$saver');
        }
      }
    });
    test('no worker cap, no sweep, today\'s tiers', () {
      expect(bal.maxWorkers, isNull);
      expect(bal.untilEagerSweep(_plugged(), _at(600)), isNull);
    });
  });
}
