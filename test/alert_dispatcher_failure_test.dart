// Failure injection — AlertDispatcher and the buzz-sequence player.
// Every case ends in a defined give-up state: no throw out of dispatch, claims
// not leaked, and never a second buzz for the same event.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

const _both = AlertRule(
  id: 'health',
  kind: 'health',
  destinations: 3,
  channelPolicyId: 'health',
);
const _band = AlertRule(
  id: 'zone',
  kind: 'zone',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  staleAfter: Duration(seconds: 30),
  channelPolicyId: 'zone',
);

/// A ledger whose storage can fail, standing in for a throwing LocalDb.
class _FlakyLedger implements AlertDeliveryLedger {
  final Set<String> claims = {};
  bool failClaim = false, failRelease = false;
  int releaseCalls = 0;
  @override
  Future<bool> claim(String key) async {
    if (failClaim) throw StateError('database is locked');
    return claims.add(key);
  }

  @override
  Future<void> release(String key) async {
    releaseCalls++;
    if (failRelease) throw StateError('database is locked');
    claims.remove(key);
  }
}

AlertDispatcher _make({
  required AlertDeliveryLedger ledger,
  Future<bool> Function()? phone,
  Future<bool> Function()? band,
  bool Function()? connected,
  DateTime Function()? now,
  Duration timeout = const Duration(milliseconds: 80),
}) =>
    AlertDispatcher(
      phone: phone ?? () async => true,
      band: band ?? () async => true,
      isConnected: connected ?? () => true,
      supportedBandModes: const {AlertExecutionMode.phoneLive},
      ledger: ledger,
      now: now,
      transportTimeout: timeout,
    );

Future<AlertDeliveryOutcome> _go(AlertDispatcher d, AlertRule r, String id,
        {DateTime? at}) =>
    d.dispatch(r,
        eventId: id, sourceTime: at ?? DateTime.now(), historical: false);

void main() {
  group('DB failure (throwing ledger)', () {
    test('a claim that throws delivers nothing and does not throw', () async {
      final ledger = _FlakyLedger()..failClaim = true;
      var phones = 0, bands = 0;
      final d = _make(
        ledger: ledger,
        phone: () async => ++phones > 0,
        band: () async => ++bands > 0,
      );
      final out = await _go(d, _both, 'e1');
      expect(out.targets, isEmpty);
      expect(out.suppressionReason, 'deliveryFailed');
      expect((phones, bands), (0, 0), reason: 'fail closed: no claim, no buzz');
    });

    test('a failed band write whose release throws still returns, and the '
        'phone target is still attempted', () async {
      final ledger = _FlakyLedger()..failRelease = true;
      var phones = 0;
      final d = _make(
        ledger: ledger,
        phone: () async => ++phones > 0,
        band: () async => false, // the write failed
      );
      // Targets run phone first (set order), then band; whichever order, the
      // dispatcher must not throw and must deliver the one that worked.
      final out = await _go(d, _both, 'e2');
      expect(out.targets, ['phone']);
      expect(out.suppressionReason, 'deliveryFailed');
      expect(phones, 1);
    });

    test('a release that throws leaves the claim consumed: no double buzz '
        'on a retry of the same event', () async {
      final ledger = _FlakyLedger()..failRelease = true;
      var bands = 0;
      final d = _make(
        ledger: ledger,
        band: () async {
          bands++;
          return false;
        },
      );
      await _go(d, _band, 'e3');
      await _go(d, _band, 'e3');
      expect(bands, 1, reason: 'the second dispatch is refused by the claim');
    });
  });

  group('write timeout and BLE disconnect', () {
    test('a band write that never answers gives up, keeps its claim, and a '
        'retry of the same event cannot buzz again', () async {
      final ledger = _FlakyLedger();
      var calls = 0;
      final hang = Completer<bool>();
      final d = _make(
        ledger: ledger,
        band: () {
          calls++;
          return hang.future;
        },
      );
      final out = await _go(d, _band, 'slow');
      expect(out.targets, isEmpty);
      expect(out.suppressionReason, 'deliveryUnconfirmed');
      // The platform write may still complete late; a retry must not buzz twice.
      await _go(d, _band, 'slow');
      expect(calls, 1);
      hang.complete(true);
    });

    test('a disconnect during the write releases the claim: one later retry '
        'delivers exactly once', () async {
      final ledger = _FlakyLedger();
      var up = true, buzzes = 0;
      final d = _make(
        ledger: ledger,
        connected: () => up,
        band: () async {
          if (!up) return false;
          buzzes++;
          return true;
        },
      );
      up = false;
      final gone = await _go(d, _band, 'drop');
      expect(gone.targets, isEmpty);
      expect(gone.suppressionReason, 'bandUnavailable');
      up = true;
      expect((await _go(d, _band, 'drop')).targets, ['band']);
      expect((await _go(d, _band, 'drop')).targets, isEmpty);
      expect(buzzes, 1);
    });

    test('a write that fails mid-flight frees the claim for the next attempt',
        () async {
      final ledger = _FlakyLedger();
      var attempt = 0;
      final d = _make(ledger: ledger, band: () async => ++attempt > 1);
      expect((await _go(d, _band, 'flaky')).suppressionReason, 'deliveryFailed');
      expect(ledger.claims, isEmpty);
      expect((await _go(d, _band, 'flaky')).targets, ['band']);
    });
  });

  group('duplicate, clock skew, restart, permission loss', () {
    test('two overlapping dispatches of one event buzz once', () async {
      final ledger = _FlakyLedger();
      var bands = 0;
      final d = _make(ledger: ledger, band: () async {
        bands++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return true;
      });
      await Future.wait([_go(d, _band, 'dup'), _go(d, _band, 'dup')]);
      expect(bands, 1);
    });

    test('an event stamped in the future (skewed clock) is refused as stale',
        () async {
      final base = DateTime(2026, 10, 2, 8);
      final d = _make(ledger: _FlakyLedger(), now: () => base);
      final out = await _go(d, _band, 'future',
          at: base.add(const Duration(hours: 1)));
      expect(out.suppressionReason, 'stale');
      expect(out.targets, isEmpty);
    });

    test('an event older than its deadline is refused, however it got here',
        () async {
      final base = DateTime(2026, 10, 2, 8);
      final d = _make(ledger: _FlakyLedger(), now: () => base);
      final out = await _go(d, _band, 'old',
          at: base.subtract(const Duration(minutes: 5)));
      expect(out.suppressionReason, 'stale');
    });

    test('process restart: a second dispatcher on the same durable ledger '
        'does not buzz an event the first one delivered', () async {
      final shared = _FlakyLedger();
      var bands = 0;
      Future<bool> band() async => ++bands > 0;
      await _go(_make(ledger: shared, band: band), _band, 'once');
      await _go(_make(ledger: shared, band: band), _band, 'once');
      expect(bands, 1);
    });

    test('phone permission denied: the band still delivers, the phone claim '
        'is freed', () async {
      final ledger = _FlakyLedger();
      var bands = 0;
      final d = _make(
        ledger: ledger,
        phone: () async => false, // OS permission denied
        band: () async => ++bands > 0,
      );
      final out = await _go(d, _both, 'perm');
      expect(out.targets, ['band']);
      expect(out.suppressionReason, 'deliveryFailed');
      expect(ledger.claims.length, 1, reason: 'only the band claim is held');
    });
  });

  group('playBuzzSequence', () {
    test('a step whose write never answers stops the rhythm: no later step '
        'buzzes after the dispatcher gave up', () {
      fakeAsync((async) {
        var steps = 0;
        final hang = Completer<bool>();
        bool? result;
        playBuzzSequence(
          BuzzSequence([0, 500, 1000]),
          buzz: () {
            steps++;
            return steps == 1 ? hang.future : Future.value(true);
          },
          isConnected: () => true,
        ).then((r) => result = r);
        async.elapse(const Duration(seconds: 30));
        expect(result, isFalse, reason: 'gave up on the stuck write');
        // The stuck write finishing late must not start the remaining steps.
        hang.complete(true);
        async.elapse(const Duration(seconds: 30));
        expect(steps, 1);
      });
    });

    test('a disconnect between steps stops further steps', () async {
      var up = true, steps = 0;
      final r = await playBuzzSequence(
        BuzzSequence([0, 300, 600]),
        buzz: () async {
          steps++;
          up = false;
          return true;
        },
        isConnected: () => up,
      );
      expect(r, isFalse);
      expect(steps, 1);
    });

    test('a buzz that throws is a failed delivery, not an exception', () async {
      final r = await playBuzzSequence(
        BuzzSequence([0]),
        buzz: () async => throw StateError('gatt error'),
        isConnected: () => true,
      );
      expect(r, isFalse);
    });
  });
}
