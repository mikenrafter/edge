// 8AC (spec I.5): the global band queue. Every band haptic job (a rule's
// rhythm, a single buzz, a tap ack, a preview) runs one at a time, first in
// first out, and only while the rolling safety limit (30 commands per 2
// minutes, one ledger shared with the pattern probe) allows its commands.
//
//   BandCommandLedger({}): record(n, at), reserve(n, at), commandsLeft(now),
//     nextFreeIn(now), waitFor(n, now)
//   BandEndedSignal: reset() on every write, signal() on a live event 100,
//     wait(timeout) -> true when a 100 came since the last reset
//   BandHapticQueue(ledger:, waitEnded:, onWrite:, log:).run(job(token),
//     commands:, timeout:, startBy:, settle:) -> BuzzDelivery
//
// The reservation, cancellation and playback-hold behaviour has its own file,
// band_queue_safety_test.dart.
//
// Times are fake (fake_async): the queue reads `clock`, never DateTime.now.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

const Duration _s = Duration(seconds: 1);

/// A job that records when it started and takes [takes] to finish.
class _Jobs {
  _Jobs(this.async);
  final FakeAsync async;
  final started = <String, int>{};
  final results = <String, BuzzDelivery>{};
  final errors = <String, Object>{};

  Future<BuzzDelivery> Function(BandJobToken) job(
    String name, {
    Duration takes = Duration.zero,
    BuzzDelivery result = BuzzDelivery.complete,
    bool never = false,
    Object? throws,
  }) =>
      (_) async {
        started[name] = async.elapsed.inMilliseconds;
        if (never) return Completer<BuzzDelivery>().future;
        if (takes > Duration.zero) await Future<void>.delayed(takes);
        if (throws != null) throw throws;
        return result;
      };

  void run(
    BandHapticQueue q,
    String name, {
    int commands = 1,
    Duration timeout = const Duration(seconds: 10),
    Duration? startBy,
    Duration settle = Duration.zero,
    Duration takes = Duration.zero,
    BuzzDelivery result = BuzzDelivery.complete,
    bool never = false,
    Object? throws,
  }) {
    final f = q
        .run(
          job(name, takes: takes, result: result, never: never, throws: throws),
          commands: commands,
          timeout: timeout,
          startBy: startBy ?? kBandQueueWait,
          settle: settle,
        )
        .then((v) => results[name] = v, onError: (Object e) {
      errors[name] = e;
      return BuzzDelivery.unknown;
    });
    unawaited(f);
  }
}

void main() {
  group('BandCommandLedger', () {
    test('a new ledger has the whole allowance', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        expect(l.commandsLeft(clock.now()), 30);
        expect(l.nextFreeIn(clock.now()), isNull);
        expect(l.waitFor(30, clock.now()), Duration.zero);
        expect(BandCommandLedger.maxCommands, 30);
        expect(BandCommandLedger.window, const Duration(minutes: 2));
      });
    });

    test('record(n, at) counts n commands and never goes below zero', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        l.record(4, clock.now());
        expect(l.commandsLeft(clock.now()), 26);
        l.record(40, clock.now());
        expect(l.commandsLeft(clock.now()), 0);
      });
    });

    test('commands leave the window two minutes after they were recorded', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        l.record(1, clock.now());
        async.elapse(const Duration(seconds: 50));
        l.record(4, clock.now());
        expect(l.commandsLeft(clock.now()), 25);
        expect(l.nextFreeIn(clock.now()), const Duration(seconds: 70),
            reason: 'the oldest command leaves first');
        async.elapse(const Duration(seconds: 70));
        expect(l.commandsLeft(clock.now()), 26);
        expect(l.nextFreeIn(clock.now()), const Duration(seconds: 50));
        async.elapse(const Duration(seconds: 50));
        expect(l.commandsLeft(clock.now()), 30);
        expect(l.nextFreeIn(clock.now()), isNull);
      });
    });

    test('waitFor(n) is how long until n more commands fit', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        l.record(29, clock.now());
        async.elapse(const Duration(seconds: 10));
        l.record(1, clock.now());
        final now = clock.now();
        expect(l.waitFor(1, now), const Duration(seconds: 110),
            reason: 'the 30 are full: one old command must leave');
        expect(l.waitFor(2, now), const Duration(seconds: 110));
        expect(l.waitFor(0, now), Duration.zero);
        async.elapse(const Duration(seconds: 110));
        expect(l.waitFor(29, clock.now()), Duration.zero);
        expect(l.waitFor(30, clock.now()), const Duration(seconds: 10),
            reason: 'all 30 only once the late one has left too');
      });
    });

    test('record(n) adds writes the reservations and the probes count with',
        () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        l.record(2, clock.now());
        expect(l.commandsLeft(clock.now()), 28);
        final r = l.reserve(3, clock.now())!;
        expect(l.commandsLeft(clock.now()), 25);
        r.take(clock.now());
        l.record(3, clock.now());
        expect(l.commandsLeft(clock.now()), 22);
      });
    });
  });

  group('BandEndedSignal', () {
    test('a 100 after the reset releases the wait, also when it came first',
        () {
      fakeAsync((async) {
        final s = BandEndedSignal();
        bool? got;
        s.wait(const Duration(seconds: 5)).then((v) => got = v);
        async.elapse(const Duration(seconds: 1));
        expect(got, isNull);
        s.signal();
        async.flushMicrotasks();
        expect(got, isTrue);
        // Latched: a 100 that came before the wait began still counts.
        bool? late;
        s.wait(const Duration(seconds: 5)).then((v) => late = v);
        async.flushMicrotasks();
        expect(late, isTrue);
      });
    });

    test('reset forgets earlier events; no 100 in time is false', () {
      fakeAsync((async) {
        final s = BandEndedSignal()..signal();
        s.reset();
        bool? got;
        s.wait(const Duration(seconds: 3)).then((v) => got = v);
        async.elapse(const Duration(seconds: 2));
        expect(got, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(got, isFalse);
      });
    });
  });

  group('BandHapticQueue', () {
    BandHapticQueue newQueue(
      BandCommandLedger l, {
      List<String>? log,
      Future<bool> Function(Duration)? waitEnded,
    }) =>
        BandHapticQueue(ledger: l, log: log?.add, waitEnded: waitEnded);

    test('a lone job starts at once, returns its result and records its '
        'commands', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final q = newQueue(l);
        final j = _Jobs(async)..run(q, 'a', commands: 3, takes: _s);
        async.flushMicrotasks();
        expect(j.started['a'], 0);
        expect(l.commandsLeft(clock.now()), 27);
        expect(q.pending, 1);
        async.elapse(_s);
        expect(j.results['a'], BuzzDelivery.complete);
        expect(q.pending, 0);
      });
    });

    test('one job at a time, first in first out', () {
      fakeAsync((async) {
        final q = newQueue(BandCommandLedger());
        final j = _Jobs(async)
          ..run(q, 'a', takes: const Duration(seconds: 3))
          ..run(q, 'b', takes: const Duration(seconds: 2))
          ..run(q, 'c');
        async.flushMicrotasks();
        expect(j.started, {'a': 0});
        expect(q.pending, 3);
        async.elapse(const Duration(seconds: 3));
        expect(j.started['b'], 3000);
        expect(j.started.containsKey('c'), isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(j.started['c'], 5000);
        expect(j.results.keys, containsAll(['a', 'b', 'c']));
        expect(q.pending, 0);
      });
    });

    test('a job that waits behind another logs how many are ahead', () {
      fakeAsync((async) {
        final log = <String>[];
        final q = newQueue(BandCommandLedger(), log: log);
        _Jobs(async)
          ..run(q, 'a', takes: _s)
          ..run(q, 'b')
          ..run(q, 'c');
        async.flushMicrotasks();
        expect(log, [
          'Band queue: waiting for the band (1 ahead)',
          'Band queue: waiting for the band (2 ahead)',
        ]);
        async.elapse(const Duration(seconds: 3));
      });
    });

    test('the ledger can make a job rest; it starts when its commands fit and '
        'the log says how long', () {
      fakeAsync((async) {
        final l = BandCommandLedger()..record(29, clock.now());
        final log = <String>[];
        final q = newQueue(l, log: log);
        final j = _Jobs(async)
          ..run(q, 'a', commands: 2, startBy: const Duration(minutes: 3));
        async.elapse(const Duration(seconds: 119));
        expect(j.started, isEmpty);
        expect(q.pending, 1);
        expect(q.nextFreeIn, const Duration(seconds: 1));
        expect(log, contains('Band queue: resting, ready in 120 s'));
        async.elapse(_s);
        expect(j.started['a'], 120000);
        expect(j.results['a'], BuzzDelivery.complete);
      });
    });

    test('a job that cannot start before its deadline is rejected at once, '
        'nothing written and nothing recorded', () {
      fakeAsync((async) {
        final l = BandCommandLedger()..record(30, clock.now());
        final q = newQueue(l);
        final j = _Jobs(async)..run(q, 'a', startBy: const Duration(seconds: 15));
        async.flushMicrotasks();
        expect(j.results['a'], BuzzDelivery.rejected);
        expect(j.started, isEmpty, reason: 'the job body never ran');
        expect(l.commandsLeft(clock.now()), 0, reason: 'nothing recorded');
        expect(q.pending, 0);
      });
    });

    test('a job waiting behind a long one is rejected at its own deadline; '
        'the ones after it carry on', () {
      fakeAsync((async) {
        final q = newQueue(BandCommandLedger());
        final j = _Jobs(async)
          ..run(q, 'a',
              takes: const Duration(seconds: 20),
              timeout: const Duration(seconds: 30))
          ..run(q, 'b', startBy: const Duration(seconds: 15))
          ..run(q, 'c', startBy: const Duration(seconds: 40));
        async.elapse(const Duration(seconds: 14));
        expect(j.results.containsKey('b'), isFalse);
        async.elapse(_s);
        expect(j.results['b'], BuzzDelivery.rejected);
        expect(j.started.containsKey('b'), isFalse);
        async.elapse(const Duration(seconds: 5));
        expect(j.started['c'], 20000);
        expect(j.results['c'], BuzzDelivery.complete);
      });
    });

    test('the transport timeout counts from the start, not from the enqueue',
        () {
      fakeAsync((async) {
        final q = newQueue(BandCommandLedger());
        final j = _Jobs(async)
          ..run(q, 'a', takes: const Duration(seconds: 10))
          ..run(q, 'b',
              takes: const Duration(seconds: 3),
              timeout: const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 14));
        expect(j.started['b'], 10000);
        expect(j.results['b'], BuzzDelivery.complete,
            reason: '3 s of work inside a 5 s timeout, though 13 s since '
                'enqueue');
      });
    });

    test('a job that never answers is unknown after its timeout and frees the '
        'slot', () {
      fakeAsync((async) {
        final q = newQueue(BandCommandLedger());
        final j = _Jobs(async)
          ..run(q, 'a', never: true, timeout: const Duration(seconds: 4))
          ..run(q, 'b');
        async.elapse(const Duration(seconds: 3));
        expect(j.started.containsKey('b'), isFalse);
        async.elapse(_s);
        expect(j.results['a'], BuzzDelivery.unknown);
        expect(j.started['b'], 4000);
        expect(j.results['b'], BuzzDelivery.complete);
      });
    });

    test('a job that throws hands the error to its caller and the queue '
        'carries on', () {
      fakeAsync((async) {
        final q = newQueue(BandCommandLedger());
        final j = _Jobs(async)
          ..run(q, 'a', throws: StateError('radio'))
          ..run(q, 'b');
        async.flushMicrotasks();
        expect(j.errors['a'], isA<StateError>());
        expect(j.results['b'], BuzzDelivery.complete);
        expect(q.pending, 0);
      });
    });

    test('settle: the slot stays busy until the band reports the last command '
        'ended, but the caller already has its result', () {
      fakeAsync((async) {
        final ended = BandEndedSignal();
        final q = newQueue(BandCommandLedger(), waitEnded: ended.wait);
        final j = _Jobs(async)
          ..run(q, 'a', settle: const Duration(seconds: 4), takes: _s)
          ..run(q, 'b');
        ended.reset();
        async.elapse(const Duration(seconds: 2));
        expect(j.results['a'], BuzzDelivery.complete,
            reason: 'the result does not wait for the band');
        expect(j.started.containsKey('b'), isFalse,
            reason: 'but the band is still playing');
        async.elapse(const Duration(seconds: 1));
        ended.signal();
        async.elapse(Duration.zero);
        expect(j.started['b'], 3000);
      });
    });

    test('settle: no 100 in time still frees the slot', () {
      fakeAsync((async) {
        final ended = BandEndedSignal();
        final q = newQueue(BandCommandLedger(), waitEnded: ended.wait);
        final j = _Jobs(async)
          ..run(q, 'a', settle: const Duration(seconds: 4))
          ..run(q, 'b');
        async.elapse(const Duration(seconds: 5));
        expect(j.started['b'], 4000);
      });
    });

    test('a rejected job does not settle', () {
      fakeAsync((async) {
        final ended = BandEndedSignal();
        final q = newQueue(BandCommandLedger(), waitEnded: ended.wait);
        final j = _Jobs(async)
          ..run(q, 'a',
              settle: const Duration(seconds: 4), result: BuzzDelivery.rejected)
          ..run(q, 'b');
        async.elapse(_s);
        expect(j.started['b'], 0);
      });
    });

    test('nextFreeIn mirrors the shared ledger', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final q = newQueue(l);
        expect(q.nextFreeIn, isNull);
        l.record(2, clock.now());
        expect(q.nextFreeIn, const Duration(minutes: 2));
      });
    });
  });

  group('AlertDispatcher gives the queue its time', () {
    const rule = AlertRule(
      id: 'buzz_preview',
      kind: 'buzzPreview',
      destinations: AlertRule.band,
      executionMode: AlertExecutionMode.phoneLive,
      staleAfter: Duration(seconds: 30),
      channelPolicyId: 'buzz_preview',
    );

    AlertDispatcher make({
      Duration queueWait = Duration.zero,
      Duration Function(BuzzSequence)? sequenceTimeout,
      Future<BuzzDelivery> Function(BuzzSequence)? delivery,
    }) =>
        AlertDispatcher(
          phone: () async => false,
          band: () async => true,
          isConnected: () => true,
          now: clock.now,
          ledger: MemoryAlertDeliveryLedger(),
          bandSequenceDelivery: delivery,
          bandQueueWait: queueWait,
          sequenceTimeout: sequenceTimeout,
        );

    test('bandQueueWait is added to the band deadline, so waiting in the '
        'queue does not eat the transport time', () {
      fakeAsync((async) {
        AlertDeliveryOutcome? slow, roomy;
        Future<BuzzDelivery> twelve() async {
          await Future<void>.delayed(const Duration(seconds: 12));
          return BuzzDelivery.complete;
        }

        make().dispatch(rule,
            eventId: 'x', sourceTime: clock.now(), historical: false,
            bandDelivery: twelve).then((o) => slow = o);
        make(queueWait: kBandQueueWait).dispatch(rule,
            eventId: 'y', sourceTime: clock.now(), historical: false,
            bandDelivery: twelve).then((o) => roomy = o);
        async.elapse(const Duration(seconds: 30));
        expect(slow!.suppressionReason, 'deliveryUnconfirmed',
            reason: 'the flat 10 s runs out');
        expect(roomy!.targets, ['band']);
      });
    });

    test('sequenceTimeout sizes the deadline of a rule\'s saved rhythm', () {
      fakeAsync((async) {
        final seq = BuzzSequence([0, 400]);
        final saved = rule.copyWith(buzzSequence: seq);
        AlertDeliveryOutcome? out;
        make(
          queueWait: kBandQueueWait,
          sequenceTimeout: (s) => const Duration(seconds: 40),
          delivery: (s) async {
            await Future<void>.delayed(const Duration(seconds: 35));
            return BuzzDelivery.complete;
          },
        ).dispatch(saved,
            eventId: 'z', sourceTime: clock.now(),
            historical: false).then((o) => out = o);
        async.elapse(const Duration(seconds: 60));
        expect(out!.targets, ['band']);
      });
    });
  });

  group('two alerts at once on a WHOOP 5.0 MG', () {
    const rule = AlertRule(
      id: 'buzz_preview',
      kind: 'buzzPreview',
      destinations: AlertRule.band,
      executionMode: AlertExecutionMode.phoneLive,
      staleAfter: Duration(seconds: 30),
      channelPolicyId: 'buzz_preview',
    );
    // Two half-second holds: a plan of more than one command.
    final seq = BuzzSequence([0, 875], durationsMs: [500, 500]);

    // A band that plays each command for 600 ms and then reports event 100.
    // The same wiring AppState._deliverBandSequence has: the player, the
    // ended signal, the queue.
    ({
      Future<AlertDeliveryOutcome> Function(String who) send,
      List<(String, int)> writes,
      List<int> endedAt,
      List<String> log,
      BandCommandLedger ledger,
      BandHapticQueue queue,
    }) rig(FakeAsync async) {
      final ledger = BandCommandLedger();
      final ended = BandEndedSignal();
      final log = <String>[];
      final writes = <(String, int)>[];
      final endedAt = <int>[];
      final queue = BandHapticQueue(
        ledger: ledger,
        waitEnded: ended.wait,
        onWrite: ended.reset,
        log: log.add,
      );
      final dispatcher = AlertDispatcher(
        phone: () async => false,
        band: () async => true,
        isConnected: () => true,
        now: clock.now,
        ledger: MemoryAlertDeliveryLedger(),
        bandQueueWait: kBandQueueWait,
      );
      Future<AlertDeliveryOutcome> send(String who) => dispatcher.dispatch(
            rule,
            eventId: who,
            sourceTime: clock.now(),
            historical: false,
            bandTimeout: bandSequenceTimeout(seq, _mg),
            bandDelivery: () => deliverBandSequenceQueued(
              queue,
              seq,
              profile: _mg,
              buzz: () async => true,
              writePattern: (effects, loop) async {
                writes.add((who, async.elapsed.inMilliseconds));
                Timer(const Duration(milliseconds: 600), () {
                  endedAt.add(async.elapsed.inMilliseconds);
                  ended.signal();
                });
                return true;
              },
              waitEnded: ended.wait,
              isConnected: () => true,
            ),
          );
      return (
        send: send,
        writes: writes,
        endedAt: endedAt,
        log: log,
        ledger: ledger,
        queue: queue,
      );
    }

    test('the second one writes only after the first one\'s last ended event',
        () {
      fakeAsync((async) {
        final r = rig(async);
        final out = <String, AlertDeliveryOutcome>{};
        r.send('a').then((o) => out['a'] = o);
        r.send('b').then((o) => out['b'] = o);
        async.elapse(const Duration(seconds: 30));
        expect(out['a']!.targets, ['band']);
        expect(out['b']!.targets, ['band']);
        final a = [for (final w in r.writes) if (w.$1 == 'a') w.$2];
        final b = [for (final w in r.writes) if (w.$1 == 'b') w.$2];
        expect(a.length, bandSequenceCommands(seq, _mg));
        expect(b.length, a.length);
        expect(r.writes.map((w) => w.$1).toList(),
            [...List.filled(a.length, 'a'), ...List.filled(b.length, 'b')],
            reason: 'never interleaved');
        final aLastEnded = r.endedAt[a.length - 1];
        expect(b.first, greaterThanOrEqualTo(aLastEnded));
        expect(r.log, contains('Band queue: waiting for the band (1 ahead)'));
        expect(r.ledger.commandsLeft(clock.now()), 30 - 2 * a.length);
      });
    });

    test('with the ledger nearly full the second waits for nextFreeIn, then '
        'plays', () {
      fakeAsync((async) {
        final r = rig(async);
        // 28 commands recorded 110 s ago: they leave at +10 s.
        r.ledger.record(28, clock.now().subtract(const Duration(seconds: 110)));
        final out = <String, AlertDeliveryOutcome>{};
        r.send('a').then((o) => out['a'] = o);
        r.send('b').then((o) => out['b'] = o);
        async.elapse(const Duration(seconds: 60));
        final b = [for (final w in r.writes) if (w.$1 == 'b') w.$2];
        expect(out['a']!.targets, ['band']);
        expect(out['b']!.targets, ['band']);
        expect(b.first, 10000, reason: 'the old commands have left by then');
        expect(r.log.any((l) => l.startsWith('Band queue: resting, ready in')),
            isTrue);
      });
    });

    test('with the ledger full beyond its deadline the second is rejected: '
        'nothing written, and it can be sent again later', () {
      fakeAsync((async) {
        final r = rig(async);
        // 27 recorded now stay for 2 minutes: the first plan (2 commands)
        // fits, the second would have to wait far past its 15 s deadline.
        r.ledger.record(27, clock.now());
        final out = <String, AlertDeliveryOutcome>{};
        r.send('a').then((o) => out['a'] = o);
        r.send('b').then((o) => out['b'] = o);
        async.elapse(const Duration(seconds: 30));
        expect(out['a']!.targets, ['band']);
        expect(out['b']!.targets, isEmpty);
        expect(out['b']!.suppressionReason, 'deliveryFailed');
        expect([for (final w in r.writes) w.$1].every((who) => who == 'a'),
            isTrue,
            reason: 'nothing of b was written');
        expect(r.queue.pending, 0);
        // The claim was given back: the same alert may try again once the
        // band has rested.
        async.elapse(const Duration(minutes: 2));
        r.send('b').then((o) => out['b2'] = o);
        async.elapse(const Duration(seconds: 10));
        expect(out['b2']!.targets, ['band']);
      });
    });
  });

  group('the pattern probe shares the ledger', () {
    StrapEvent clockEvent(int id) {
      final now = clock.now().add(const Duration(seconds: 10));
      final ms = now.millisecondsSinceEpoch;
      return StrapEvent(
        eventId: id,
        tsEpoch: ms ~/ 1000,
        tsSubsec: ((ms % 1000) * 32768) ~/ 1000,
        receivedAt: now,
        hex: '',
        deviceId: 'band',
      );
    }

    HardwareProbeRunner runner(BandCommandLedger ledger, List<int> sent) {
      late final HardwareProbeRunner r;
      r = HardwareProbeRunner(
        lab: DeviceLabLog(),
        sendBuzz: (onReply) async => true,
        sendPattern: (effects, loop, onReply) async {
          sent.add(loop);
          r.onBandEvent(clockEvent(100));
          onReply('pending', 40);
          return true;
        },
        isConnected: () => true,
        ecgSupported: () => true,
        ecgBusy: () => false,
        beginEcg: () async => false,
        endEcg: () async {},
        isEcgAlive: () => false,
        ledger: ledger,
      );
      return r;
    }

    // Test 8 is the first with one command.
    const oneCommandTest = 8;

    testWidgets('alert commands count against the probe\'s limit and its '
        'read-outs', (t) async {
      final ledger = BandCommandLedger();
      final r = runner(ledger, <int>[]);
      ledger.record(5, clock.now());
      expect(r.patternCommandsLeft, 25);
      expect(r.patternNextFreeIn, const Duration(minutes: 2));
    });

    testWidgets('a probe write is recorded in the ledger the alerts read',
        (t) async {
      final ledger = BandCommandLedger();
      final sent = <int>[];
      final r = runner(ledger, sent);
      await r.openPattern();
      r.patternTest(oneCommandTest);
      await r.playPattern();
      expect(sent, hasLength(1));
      expect(ledger.commandsLeft(clock.now()), 29);
      expect(r.patternCommandsLeft, 29);
      r.closePattern();
    });

    testWidgets('a full ledger makes the probe rest, whoever filled it',
        (t) async {
      final ledger = BandCommandLedger()..record(30, clock.now());
      final sent = <int>[];
      final r = runner(ledger, sent);
      await r.openPattern();
      r.patternTest(oneCommandTest);
      await r.playPattern();
      expect(sent, isEmpty);
      expect(r.patternRefusal, PatternRefusal.resting);
      r.closePattern();
    });
  });

  group('the notification relay goes through the same queue', () {
    final seq = BuzzSequence([0, 400]);

    NotificationRelay relay({
      Future<BuzzDelivery> Function(BuzzSequence)? deliver,
      Future<BuzzDelivery> Function(
              int commands, Future<BuzzDelivery> Function(BandJobToken job) job)?
          runBand,
      List<String>? engineBuzzes,
    }) =>
        NotificationRelay(
          buzz: () async => engineBuzzes?.add('buzz'),
          buzzForDuration: (h) async {
            engineBuzzes?.add('hold $h');
            return true;
          },
          isConnected: () => true,
          deliverSequence: deliver,
          sequenceTimeout: (s) => const Duration(seconds: 33),
          runBand: runBand,
        );

    test('the controller\'s rhythm transports use the injected delivery, never '
        'the engine buzz directly', () async {
      final engine = <String>[];
      final delivered = <BuzzSequence>[];
      final r = relay(
        engineBuzzes: engine,
        deliver: (s) async {
          delivered.add(s);
          return BuzzDelivery.complete;
        },
      );
      expect(await r.controller.deliverSequence!(seq), BuzzDelivery.complete);
      expect(await r.controller.playSequence!(seq), isTrue);
      expect(delivered, [seq, seq]);
      expect(engine, isEmpty);
    });

    test('playSequence is false unless the delivery completed', () async {
      final r = relay(deliver: (s) async => BuzzDelivery.unknown);
      expect(await r.controller.playSequence!(seq), isFalse);
    });

    test('the controller sizes the band deadline with the injected '
        'sequenceTimeout', () {
      final r = relay(deliver: (s) async => BuzzDelivery.complete);
      expect(r.controller.sequenceTimeout!(seq), const Duration(seconds: 33));
    });

    test('a matched-haptics pattern buzzes inside a queue job of its pulse '
        'count, each pulse counted when it is written', () async {
      final jobs = <int>[];
      final engine = <String>[];
      final ledger = BandCommandLedger();
      final queue = BandHapticQueue(ledger: ledger);
      final r = relay(
        engineBuzzes: engine,
        runBand: (commands, job) {
          jobs.add(commands);
          return queue.run(job,
              commands: commands,
              timeout: const Duration(seconds: 5),
              settle: Duration.zero);
        },
      );
      expect(await r.controller.buzz([0, 200, 100, 200]), isTrue);
      expect(jobs, [2]);
      expect(engine, ['buzz', 'buzz']);
      expect(ledger.commandsLeft(clock.now()), 28);
    });
  });
}
