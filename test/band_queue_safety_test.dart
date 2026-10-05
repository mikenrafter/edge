// The safety behaviour of the global
// band queue, pinned with fake time and no source reading.
//
//   1. A job that times out is cancelled: it writes nothing more, and the band
//      is not handed to the next job until its in-flight write is over.
//   2. Every job holds the band through playback: until the band's ended event
//      (100) or a bounded playback timeout, also for a single buzz.
//   3+4. The ledger separates RESERVATIONS from WRITES: a job (or a probe)
//      reserves its whole count before it starts, each real write turns one
//      reservation into a write stamped when it happened, unused reservations
//      are released. The 30-per-2-minutes limit holds with probes and alerts
//      interleaved.
//   6. A job of more than 30 commands is rejected, never clamped.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

const Duration _s = Duration(seconds: 1);

/// Most commands written in any rolling two minutes, from write times.
int _busiestWindow(List<DateTime> writes) {
  var most = 0;
  for (final at in writes) {
    final n = writes
        .where((w) => !w.isAfter(at) && w.add(BandCommandLedger.window).isAfter(at))
        .length;
    if (n > most) most = n;
  }
  return most;
}

void main() {
  group('BandCommandLedger reservations', () {
    test('reserve admits atomically: all of n or nothing', () {
      fakeAsync((async) {
        final l = BandCommandLedger()..record(27, clock.now());
        final a = l.reserve(3, clock.now());
        expect(a, isNotNull);
        expect(l.commandsLeft(clock.now()), 0,
            reason: 'a live reservation counts like a write');
        expect(l.reserve(1, clock.now()), isNull);
        expect(l.commandsLeft(clock.now()), 0, reason: 'a refusal takes nothing');
        a!.release();
        expect(l.commandsLeft(clock.now()), 3);
        expect(l.reserve(4, clock.now()), isNull, reason: '27 + 4 > 30');
        expect(l.reserve(3, clock.now()), isNotNull);
      });
    });

    test('a reservation turns into writes one at a time, stamped when written',
        () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final r = l.reserve(3, clock.now())!;
        expect(r.remaining, 3);
        expect(r.take(clock.now()), isTrue);
        expect(l.commandsLeft(clock.now()), 27);
        async.elapse(const Duration(seconds: 100));
        expect(r.take(clock.now()), isTrue);
        expect(r.remaining, 1);
        expect(l.commandsLeft(clock.now()), 27);
        // The first write leaves the window at 120 s; the reservation does not
        // age at all.
        async.elapse(const Duration(seconds: 20));
        expect(l.commandsLeft(clock.now()), 28);
        r.release();
        expect(l.commandsLeft(clock.now()), 29);
        expect(r.take(clock.now()), isFalse, reason: 'released: nothing to take');
      });
    });

    test('release is idempotent and keeps the writes already made', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final r = l.reserve(5, clock.now())!;
        r.take(clock.now());
        r.release();
        r.release();
        expect(l.commandsLeft(clock.now()), 29);
      });
    });

    test('waitFor refuses a count above the limit instead of clamping it', () {
      final l = BandCommandLedger();
      expect(() => l.waitFor(31, DateTime(2026)), throwsArgumentError);
      expect(l.waitFor(30, DateTime(2026)), Duration.zero);
      expect(l.reserve(31, DateTime(2026)), isNull);
    });

    test('a reservation that blocks a job makes it poll, not wait for expiry',
        () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final lab = l.reserve(20, clock.now())!;
        expect(l.waitFor(11, clock.now()), greaterThan(Duration.zero));
        lab.release();
        expect(l.waitFor(11, clock.now()), Duration.zero);
      });
    });
  });

  group('BandHapticQueue: one band, one job, to the end', () {
    // A band that reports its ended event [playMs] after each write.
    ({
      BandHapticQueue queue,
      BandCommandLedger ledger,
      BandEndedSignal ended,
      List<(String, int)> writes,
      Future<bool> Function(String who, {Duration lands}) write,
    }) rig(FakeAsync async, {int? playMs, List<String>? log}) {
      final ledger = BandCommandLedger();
      final ended = BandEndedSignal();
      final writes = <(String, int)>[];
      final queue = BandHapticQueue(
        ledger: ledger,
        waitEnded: ended.wait,
        onWrite: ended.reset,
        log: log?.add,
      );
      Future<bool> write(String who, {Duration lands = Duration.zero}) async {
        writes.add((who, async.elapsed.inMilliseconds));
        if (playMs != null) Timer(Duration(milliseconds: playMs), ended.signal);
        if (lands > Duration.zero) await Future<void>.delayed(lands);
        return true;
      }

      return (
        queue: queue,
        ledger: ledger,
        ended: ended,
        writes: writes,
        write: write,
      );
    }

    Future<BuzzDelivery> Function(BandJobToken) oneBuzz(
      Future<bool> Function(String, {Duration lands}) write,
      String who,
    ) =>
        (t) async => await t.write(() => write(who))
            ? BuzzDelivery.complete
            : BuzzDelivery.rejected;

    test('finding 1: a write that outlives the job timeout is the last one of '
        'that job, and the next job starts only after it', () {
      fakeAsync((async) {
        final r = rig(async);
        final results = <String, BuzzDelivery>{};
        r.queue.run(
          (t) async {
            for (var i = 0; i < 3; i++) {
              final ok = await t.write(
                  () => r.write('a$i', lands: const Duration(seconds: 6)));
              if (!ok) return BuzzDelivery.partial;
            }
            return BuzzDelivery.complete;
          },
          commands: 3,
          timeout: const Duration(seconds: 4),
          settle: Duration.zero,
        ).then((v) => results['a'] = v);
        r.queue.run(oneBuzz(r.write, 'b'),
            commands: 1, timeout: const Duration(seconds: 5), settle: Duration.zero)
            .then((v) => results['b'] = v);
        async.elapse(const Duration(seconds: 30));
        expect(results['a'], BuzzDelivery.unknown,
            reason: 'its caller is told at the timeout');
        expect(r.writes.map((w) => w.$1).toList(), ['a0', 'b'],
            reason: 'a never writes again after its timeout');
        expect(r.writes.last.$2, greaterThanOrEqualTo(6000),
            reason: 'b waits for the write still in flight');
        expect(results['b'], BuzzDelivery.complete);
        expect(r.ledger.commandsLeft(clock.now()), 28,
            reason: 'two writes happened; a\'s unused reservation is back');
      });
    });

    test('finding 1: a write that never lands holds the band only for a '
        'bounded grace', () {
      fakeAsync((async) {
        final r = rig(async);
        r.queue.run(
          (t) async {
            await t.write(() => Completer<bool>().future);
            return BuzzDelivery.complete;
          },
          commands: 1,
          timeout: const Duration(seconds: 4),
          settle: Duration.zero,
        );
        r.queue.run(oneBuzz(r.write, 'b'),
            commands: 1, timeout: const Duration(seconds: 5), settle: Duration.zero);
        async.elapse(const Duration(seconds: 30));
        final b = r.writes.single;
        expect(b.$1, 'b');
        expect(b.$2, 4000 + kBandWriteGrace.inMilliseconds);
      });
    });

    test('finding 1: a cancelled job cannot write through its token', () {
      fakeAsync((async) {
        final r = rig(async);
        late BandJobToken token;
        r.queue.run(
          (t) async {
            token = t;
            return Completer<BuzzDelivery>().future;
          },
          commands: 2,
          timeout: const Duration(seconds: 2),
          settle: Duration.zero,
        );
        async.elapse(const Duration(seconds: 3));
        expect(token.cancelled, isTrue);
        var sent = 0;
        bool? ok;
        token.write(() async {
          sent++;
          return true;
        }).then((v) => ok = v);
        async.flushMicrotasks();
        expect(ok, isFalse);
        expect(sent, 0);
      });
    });

    test('finding 2: two queued single buzzes: the second is written after the '
        'first one\'s ended event', () {
      fakeAsync((async) {
        final r = rig(async, playMs: 1050);
        r.queue.run(oneBuzz(r.write, 'a'),
            commands: 1, timeout: const Duration(seconds: 7));
        r.queue.run(oneBuzz(r.write, 'b'),
            commands: 1, timeout: const Duration(seconds: 7));
        async.elapse(const Duration(seconds: 10));
        expect(r.writes.map((w) => w.$1).toList(), ['a', 'b']);
        expect(r.writes[1].$2, greaterThanOrEqualTo(1050));
        expect(r.writes[1].$2, lessThan(1500),
            reason: 'the ended event releases the band, no need to sit it out');
      });
    });

    test('finding 2: a band that never sends event 100 (gen 4) is held a '
        'bounded playback timeout, then released', () {
      fakeAsync((async) {
        final r = rig(async);
        r.queue.run(oneBuzz(r.write, 'a'),
            commands: 1, timeout: const Duration(seconds: 7));
        r.queue.run(oneBuzz(r.write, 'b'),
            commands: 1, timeout: const Duration(seconds: 7));
        async.elapse(const Duration(seconds: 10));
        expect(r.writes[1].$2, kBandBuzzPlayback.inMilliseconds);
        expect(kBandBuzzPlayback, const Duration(milliseconds: 1500));
      });
    });

    test('finding 2: an ended event from before the write does not release '
        'the band', () {
      fakeAsync((async) {
        final r = rig(async);
        r.ended.signal(); // the previous buzz's 100, long since
        r.queue.run(oneBuzz(r.write, 'a'),
            commands: 1, timeout: const Duration(seconds: 7));
        r.queue.run(oneBuzz(r.write, 'b'),
            commands: 1, timeout: const Duration(seconds: 7));
        async.elapse(const Duration(seconds: 10));
        expect(r.writes[1].$2, 1500, reason: 'the write reset the signal');
      });
    });

    test('finding 2: the per-tap fallback (no profile) holds the band too', () {
      fakeAsync((async) {
        final r = rig(async);
        final seq = BuzzSequence(const [0]);
        expect(bandSequenceSettle(seq, null), kBandBuzzPlayback);
        final results = <BuzzDelivery>[];
        for (final who in ['a', 'b']) {
          deliverBandSequenceQueued(
            r.queue,
            seq,
            profile: null,
            buzz: () => r.write(who),
            writePattern: (e, l) async => true,
            waitEnded: r.ended.wait,
            isConnected: () => true,
          ).then(results.add);
        }
        async.elapse(const Duration(seconds: 10));
        expect(r.writes.map((w) => w.$1).toList(), ['a', 'b']);
        expect(r.writes[1].$2, greaterThanOrEqualTo(1500));
        expect(results, [BuzzDelivery.complete, BuzzDelivery.complete]);
        expect(r.ledger.commandsLeft(clock.now()), 28);
      });
    });

    test('a timed-out job that wrote still lets the band finish playing',
        () {
      fakeAsync((async) {
        final r = rig(async, playMs: 1000);
        r.queue.run(
          (t) async {
            await t.write(() => r.write('a'));
            return Completer<BuzzDelivery>().future;
          },
          commands: 1,
          timeout: const Duration(seconds: 2),
        );
        r.queue.run(oneBuzz(r.write, 'b'),
            commands: 1, timeout: const Duration(seconds: 7));
        async.elapse(const Duration(seconds: 10));
        expect(r.writes[1].$2, 2000,
            reason: 'the band played long ago by the time of the timeout');
      });
    });
  });

  group('BandHapticQueue and the 30 per 2 minutes limit', () {
    BandHapticQueue newQueue(BandCommandLedger l) =>
        BandHapticQueue(ledger: l);

    test('finding 6: a job of more than 30 commands is rejected at once, not '
        'clamped; nothing runs and nothing is consumed', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final q = newQueue(l);
        var ran = false;
        BuzzDelivery? out;
        q.run((t) async {
          ran = true;
          return BuzzDelivery.complete;
        }, commands: 31, timeout: _s).then((v) => out = v);
        async.flushMicrotasks();
        expect(out, BuzzDelivery.rejected);
        expect(ran, isFalse);
        expect(l.commandsLeft(clock.now()), 30);
        expect(q.pending, 0);
      });
    });

    test('finding 4: a job rejected for waiting too long consumes nothing', () {
      fakeAsync((async) {
        final l = BandCommandLedger()..record(29, clock.now());
        final q = newQueue(l);
        BuzzDelivery? out;
        q.run((t) async => BuzzDelivery.complete,
            commands: 5, timeout: _s, startBy: const Duration(seconds: 15))
            .then((v) => out = v);
        async.elapse(const Duration(seconds: 20));
        expect(out, BuzzDelivery.rejected);
        expect(l.commandsLeft(clock.now()), 1);
      });
    });

    test('finding 4: a job that writes nothing leaves nothing behind', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final q = newQueue(l);
        q.run((t) async => BuzzDelivery.rejected,
            commands: 8, timeout: _s, settle: Duration.zero);
        async.elapse(_s);
        expect(l.commandsLeft(clock.now()), 30);
      });
    });

    test('finding 4: an 8-command job\'s entries leave the window per write '
        'time, not at the job start', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final q = newQueue(l);
        q.run(
          (t) async {
            for (var i = 0; i < 8; i++) {
              if (i > 0) await Future<void>.delayed(const Duration(seconds: 2));
              await t.write(() async => true);
            }
            return BuzzDelivery.complete;
          },
          commands: 8,
          timeout: const Duration(seconds: 30),
          settle: Duration.zero,
        );
        async.elapse(const Duration(seconds: 20));
        expect(l.commandsLeft(clock.now()), 22);
        // The first write (t = 0) is two minutes old; the last (t = 14 s) is
        // not. The old code expired all eight together.
        async.elapse(const Duration(seconds: 100));
        expect(l.commandsLeft(clock.now()), 23);
        async.elapse(const Duration(seconds: 2));
        expect(l.commandsLeft(clock.now()), 24);
        async.elapse(const Duration(seconds: 12));
        expect(l.commandsLeft(clock.now()), 30);
      });
    });

    test('finding 4: the unwritten rest of a cancelled job is released', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final q = newQueue(l);
        q.run(
          (t) async {
            await t.write(() async => true);
            return Completer<BuzzDelivery>().future;
          },
          commands: 6,
          timeout: const Duration(seconds: 2),
          settle: Duration.zero,
        );
        async.elapse(_s);
        expect(l.commandsLeft(clock.now()), 24, reason: 'still reserved');
        async.elapse(const Duration(seconds: 5));
        expect(l.commandsLeft(clock.now()), 29);
      });
    });

    test('a job that throws releases its reservation', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final q = newQueue(l);
        q.run((t) async => throw StateError('radio'),
                commands: 4, timeout: _s, settle: Duration.zero)
            .then((_) {}, onError: (Object _) {});
        async.elapse(_s);
        expect(l.commandsLeft(clock.now()), 30);
      });
    });

    test('a job waits while a lab reservation holds the room, then starts '
        'when it is released', () {
      fakeAsync((async) {
        final l = BandCommandLedger();
        final lab = l.reserve(25, clock.now())!;
        final q = newQueue(l);
        var startedAt = -1;
        q.run((t) async {
          startedAt = async.elapsed.inMilliseconds;
          return BuzzDelivery.complete;
        },
            commands: 6,
            timeout: _s,
            startBy: const Duration(seconds: 15),
            settle: Duration.zero);
        async.elapse(const Duration(seconds: 5));
        expect(startedAt, -1);
        lab.release();
        async.elapse(const Duration(seconds: 2));
        expect(startedAt, greaterThanOrEqualTo(5000));
      });
    });
  });

  group('finding 3: probes and alerts share the limit without overshoot', () {
    // Test index of a 3-command paced test: the first style that sends three
    // separate commands with fixed pacing.
    final PatternTest threePaced = const PatternTest(
      waveform: BuzzWaveform('effect 47 alone', [47]),
      style: BuzzStyle.paced,
      count: 3,
    );

    test('pattern probe at 27 used: an alert cannot slip into the slots the '
        'probe still has to write; 30 is never exceeded', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger()..record(27, clock.now());
        final written = <DateTime>[
          for (var i = 0; i < 27; i++) clock.now(),
        ];
        final queue = BandHapticQueue(ledger: ledger);
        final probe = PatternProbe(
          sendPattern: (e, l, onReply) async {
            written.add(clock.now());
            if (written.length == 28) {
              // The probe's first command has landed. An alert now wants the
              // two slots that look free.
              queue.run(
                (t) async {
                  for (var i = 0; i < 2; i++) {
                    await t.write(() async {
                      written.add(clock.now());
                      return true;
                    });
                  }
                  return BuzzDelivery.complete;
                },
                commands: 2,
                timeout: const Duration(seconds: 10),
                startBy: const Duration(minutes: 3),
                settle: Duration.zero,
              );
            }
            return true;
          },
          isConnected: () => true,
          now: clock.now,
          tests: [threePaced],
          ledger: ledger,
        );
        PatternTestResult? r;
        probe.play(threePaced).then((v) => r = v);
        async.elapse(const Duration(seconds: 30));
        expect(r, isNotNull);
        expect(r!.commands.where((c) => c.written), hasLength(3));
        expect(written, hasLength(30), reason: 'the alert has not written yet');
        async.elapse(const Duration(minutes: 4));
        expect(written, hasLength(32), reason: 'the alert played once room came');
        expect(_busiestWindow(written), lessThanOrEqualTo(30));
      });
    });

    test('pattern probe reserves its whole budget before the first write', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger()..record(27, clock.now());
        var leftAtFirstWrite = -1;
        final probe = PatternProbe(
          sendPattern: (e, l, onReply) async {
            if (leftAtFirstWrite < 0) {
              leftAtFirstWrite = ledger.commandsLeft(clock.now());
            }
            return true;
          },
          isConnected: () => true,
          now: clock.now,
          tests: [threePaced],
          ledger: ledger,
        );
        probe.play(threePaced);
        async.elapse(const Duration(seconds: 30));
        expect(leftAtFirstWrite, 0);
        expect(ledger.commandsLeft(clock.now()), 0);
      });
    });

    test('pattern probe refused: a running alert job holds the room', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger()..record(27, clock.now());
        final queue = BandHapticQueue(ledger: ledger);
        queue.run(
          (t) async {
            await Future<void>.delayed(const Duration(seconds: 5));
            await t.write(() async => true);
            return BuzzDelivery.complete;
          },
          commands: 2,
          timeout: const Duration(seconds: 20),
          settle: Duration.zero,
        );
        async.flushMicrotasks();
        final sent = <int>[];
        final probe = PatternProbe(
          sendPattern: (e, l, onReply) async {
            sent.add(l);
            return true;
          },
          isConnected: () => true,
          now: clock.now,
          tests: [threePaced],
          ledger: ledger,
        );
        PatternTestResult? r = PatternTestResult(threePaced);
        probe.play(threePaced).then((v) => r = v);
        async.flushMicrotasks();
        expect(probe.lastRefusal, PatternRefusal.resting);
        expect(r, isNull);
        expect(sent, isEmpty);
      });
    });

    test('pattern probe: what it did not write is given back', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger();
        final probe = PatternProbe(
          sendPattern: (e, l, onReply) async => false,
          isConnected: () => true,
          now: clock.now,
          tests: [threePaced],
          ledger: ledger,
        );
        probe.play(threePaced);
        async.elapse(const Duration(seconds: 30));
        expect(ledger.commandsLeft(clock.now()), 29,
            reason: 'one attempted write counts, the other two are returned');
      });
    });

    test('buzz probe reserves its whole run first and is refused when the '
        'room is short', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger()..record(10, clock.now());
        var sent = 0;
        final lines = <String>[];
        final probe = HapticProbe(
          sendOne: (onReply) async {
            sent++;
            return true;
          },
          askFelt: (t, i) async => null,
          isConnected: () => true,
          step: lines.add,
          now: clock.now,
          wait: (d) => Future<void>.delayed(d),
          ledger: ledger,
        );
        probe.run();
        async.elapse(const Duration(minutes: 1));
        expect(probe.refused, isTrue);
        expect(sent, 0);
        expect(ledger.commandsLeft(clock.now()), 20, reason: 'nothing taken');
        expect(lines.join('\n'), contains('resting'));
      });
    });

    test('buzz probe: the whole run is held while it goes, and each buzz '
        'turns one reservation into a write', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger();
        final left = <int>[];
        final probe = HapticProbe(
          sendOne: (onReply) async {
            left.add(ledger.commandsLeft(clock.now()));
            return true;
          },
          askFelt: (t, i) async => null,
          isConnected: () => true,
          now: clock.now,
          wait: (d) => Future<void>.delayed(d),
          ledger: ledger,
        );
        probe.run();
        // The run takes about a minute: no write has left the window yet.
        async.elapse(const Duration(seconds: 90));
        final total =
            HapticProbe.defaultTrials.fold<int>(0, (n, t) => n + t.commands);
        expect(left, hasLength(total));
        expect(left.toSet(), {30 - total},
            reason: 'reserved up front, then converted one for one');
        expect(ledger.commandsLeft(clock.now()), 30 - total);
        expect(probe.refused, isFalse);
      });
    });

    test('buzz probe: a stopped run gives its unused reservation back', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger();
        late final HapticProbe probe;
        probe = HapticProbe(
          sendOne: (onReply) async {
            probe.stop();
            return true;
          },
          askFelt: (t, i) async => null,
          isConnected: () => true,
          now: clock.now,
          wait: (d) => Future<void>.delayed(d),
          ledger: ledger,
        );
        probe.run();
        async.elapse(const Duration(minutes: 1));
        expect(ledger.commandsLeft(clock.now()), 29);
      });
    });

    testWidgets('the lab\'s buzz probe is refused with the existing note when '
        'the ledger cannot hold its run', (t) async {
      final ledger = BandCommandLedger()..record(10, clock.now());
      var sent = 0;
      final r = HardwareProbeRunner(
        lab: DeviceLabLog(),
        sendBuzz: (onReply) async {
          sent++;
          return true;
        },
        sendPattern: (e, l, onReply) async => true,
        isConnected: () => true,
        ecgSupported: () => true,
        ecgBusy: () => false,
        beginEcg: () async => false,
        endEcg: () async {},
        isEcgAlive: () => false,
        ledger: ledger,
      );
      await r.runBuzz();
      expect(sent, 0);
      expect(r.note, contains('resting'));
      expect(r.running, isNull);
      expect(ledger.commandsLeft(clock.now()), 20);
    });
  });
}
