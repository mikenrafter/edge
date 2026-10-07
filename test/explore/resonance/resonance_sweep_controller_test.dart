// The controller on a fake clock. No real timers: the test sets the clock,
// calls tick(), and lets microtasks settle.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/resonance/resonance_analyzer.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_controller.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_plan.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

import 'support/sweep_fixtures.dart';

typedef Frames = List<({int atMs, String hex})>;

Duration sec(int n) => Duration(seconds: n);

Future<void> settle() => Future<void>.delayed(Duration.zero);

class Harness {
  Harness({
    List<double> rates = const [6.0, 5.0],
    this.connected = true,
    bool hapticOnly = false,
    this.cueOutcome,
    Map<double, double> amp = const {},
    this.decodeThrows = false,
    double Function(Duration, Duration)? still,
  }) {
    plan = planFor(rates);
    c = ResonanceSweepController(
      plan: plan,
      isConnected: () => connected,
      deliverCue: (kind) async {
        cues.add((at: clock.difference(t0), kind: kind));
        return cueOutcome?.call(clock.difference(t0), kind) ??
            CueDelivery.delivered;
      },
      decodeBeats: (frames) async {
        decodeCalls.add(frames);
        if (decodeThrows) throw StateError('decode blew up');
        if (frames.isEmpty) return const [];
        final b = plan.blocks.firstWhere((b) =>
            frames.first.atMs >= b.start.inMilliseconds &&
            frames.first.atMs < b.end.inMilliseconds);
        return synthBeats(b, amplitudeBpm: amp[b.rateBpm] ?? 4);
      },
      acquireStreams: () async => acquired++,
      releaseStreams: () => released++,
      stillFraction: still == null
          ? null
          : (from, to) {
              stillCalls.add((from: from, to: to));
              return still(from, to);
            },
      now: () => clock,
      hapticOnly: hapticOnly,
    );
    c.addListener(() => notifications++);
  }

  final bool connected;
  final CueDelivery Function(Duration at, BreathPhaseKind kind)? cueOutcome;
  final bool decodeThrows;

  late final ResonanceSweepPlan plan;
  late final ResonanceSweepController c;

  DateTime clock = DateTime.utc(2026, 10, 7, 8);
  late DateTime t0 = clock;
  int acquired = 0;
  int released = 0;
  int notifications = 0;
  final cues = <({Duration at, BreathPhaseKind kind})>[];
  final decodeCalls = <Frames>[];
  final stillCalls = <({Duration from, Duration to})>[];
  int _sec = 0;

  Future<void> start() async {
    t0 = clock;
    _sec = 0;
    await c.start();
  }

  /// Ticks once a second up to [upTo] after the start, tapping one frame a
  /// second, and lets async work settle after each tick.
  Future<void> run(Duration upTo, {bool frames = true}) async {
    while (_sec < upTo.inSeconds) {
      _sec++;
      clock = t0.add(sec(_sec));
      if (frames) c.tapFrame('f$_sec');
      c.tick();
      await settle();
    }
    await pumpEventQueue();
  }
}

void main() {
  group('start', () {
    test('without a connection it fails and touches nothing', () async {
      final h = Harness(connected: false);
      await h.start();
      expect(h.c.state, SweepState.failed);
      expect(h.c.error, 'Connect your band first.');
      expect(h.acquired, 0);
      h.c.tick();
      await pumpEventQueue();
      expect(h.cues, isEmpty);
      expect(h.released, 0);
    });

    test('acquires the streams once and is running at elapsed zero', () async {
      final h = Harness();
      expect(h.c.state, SweepState.idle);
      await h.start();
      expect(h.c.state, SweepState.running);
      expect(h.acquired, 1);
      expect(h.released, 0);
      expect(h.c.elapsed, Duration.zero);
      expect(h.c.result, isNull);
      expect(h.c.error, isNull);
    });
  });

  group('tick', () {
    test('advances elapsed from the injected clock and notifies', () async {
      final h = Harness();
      await h.start();
      final before = h.notifications;
      await h.run(sec(10));
      expect(h.c.elapsed, sec(10));
      expect(h.c.currentBlock!.rateBpm, 6.0);
      expect(h.notifications, greaterThan(before));
      await h.run(sec(160));
      expect(h.c.currentBlock!.rateBpm, 5.0);
    });

    test('cues once per phase boundary, restarting at inhale in every block',
        () async {
      // 5 bpm first: its last phase (from 144 s) is an inhale, and the next
      // block's first cue is an inhale too. It must not be swallowed.
      final h = Harness(rates: [5.0, 6.0]);
      await h.start();
      h.c.tick();
      h.c.tick(); // a second tick at the same instant is not a new boundary
      await settle();
      expect(h.cues.length, 1);
      expect(h.cues.single.kind, BreathPhaseKind.inhale);

      await h.run(sec(150));
      final first = h.cues.where((q) => q.at < sec(150)).toList();
      expect(first.length, 25); // 6 s phases from 0 to 144 s
      for (var i = 0; i < first.length; i++) {
        expect(first[i].kind,
            i.isEven ? BreathPhaseKind.inhale : BreathPhaseKind.exhale);
        expect(first[i].at, sec(6 * i));
      }

      await h.run(sec(299));
      final second = h.cues.where((q) => q.at >= sec(150)).toList();
      expect(second.length, 30); // 5 s phases from 150 to 295 s
      expect(second.first.at, sec(150));
      expect(second.first.kind, BreathPhaseKind.inhale);
      expect(second[1].kind, BreathPhaseKind.exhale);
      expect(second[1].at, sec(155));
    });

    test('tick while idle does nothing', () async {
      final h = Harness();
      h.c.tick();
      await pumpEventQueue();
      expect(h.cues, isEmpty);
      expect(h.c.state, SweepState.idle);
    });
  });

  group('missed cues', () {
    Future<SweepComparison> runWith(
      CueDelivery miss, {
      required int atSec,
      bool hapticOnly = true,
    }) async {
      final h = Harness(
        hapticOnly: hapticOnly,
        cueOutcome: (at, _) => at == sec(atSec) ? miss : CueDelivery.delivered,
      );
      await h.start();
      await h.run(sec(300));
      expect(h.c.state, SweepState.finished);
      return h.c.result!;
    }

    for (final miss in [
      CueDelivery.skippedBusy,
      CueDelivery.rejectedBudget,
      CueDelivery.notConnected,
    ]) {
      test('a $miss cue inside the measure window rejects a haptic-only block',
          () async {
        final r = await runWith(miss, atSec: 50); // block 0 measures 30..150 s
        expect(r.blocks[0].rejection, BlockRejection.missedCues);
        expect(r.blocks[1].rejection, isNull);
      });
    }

    test('a missed cue inside the settle window is not counted', () async {
      final r = await runWith(CueDelivery.skippedBusy, atSec: 10);
      expect(r.blocks[0].rejection, isNull);
      expect(r.blocks[1].rejection, isNull);
    });

    test('with the on-screen ring too, a missed buzz does not reject',
        () async {
      final r = await runWith(CueDelivery.skippedBusy,
          atSec: 50, hapticOnly: false);
      expect(r.blocks[0].rejection, isNull);
    });
  });

  group('frames', () {
    test('taps before start are ignored; only measure-window frames decode',
        () async {
      final h = Harness();
      h.c.tapFrame('pre');
      await h.start();
      await h.run(sec(300));
      expect(h.decodeCalls.length, 2);
      for (var i = 0; i < 2; i++) {
        final b = h.plan.blocks[i];
        final frames = h.decodeCalls[i];
        expect(frames.any((f) => f.hex == 'pre'), isFalse);
        expect(frames.length, greaterThanOrEqualTo(119));
        for (final f in frames) {
          expect(f.atMs, inInclusiveRange(
              b.settleEnd.inMilliseconds, b.end.inMilliseconds));
        }
      }
    });

    test('the buffer is bounded at 20000 frames', () async {
      final h = Harness(rates: [6.0, 5.0, 4.5]);
      await h.start();
      await h.run(sec(60), frames: false);
      for (var i = 0; i < 25000; i++) {
        h.c.tapFrame('x$i');
      }
      await h.run(sec(160), frames: false);
      await h.c.stop();
      final decoded = h.decodeCalls.fold<int>(0, (n, f) => n + f.length);
      expect(decoded, greaterThan(0));
      expect(decoded, lessThanOrEqualTo(20000));
    });
  });

  group('still fraction', () {
    test('is asked per block over its measure window; low means movement',
        () async {
      final h = Harness(still: (from, to) => from == sec(30) ? 0.5 : 1.0);
      await h.start();
      await h.run(sec(300));
      expect(h.stillCalls, contains((from: sec(30), to: sec(150))));
      expect(h.stillCalls, contains((from: sec(180), to: sec(300))));
      expect(h.c.result!.blocks[0].rejection, BlockRejection.movement);
      expect(h.c.result!.blocks[1].rejection, isNull);
    });

    test('defaults to fully still when not injected', () async {
      final h = Harness();
      await h.start();
      await h.run(sec(300));
      expect(h.c.result!.blocks.every((b) => b.rejection == null), isTrue);
    });
  });

  group('finish', () {
    test('a full default sweep ends finished with a tentative rate, '
        'releasing the streams once', () async {
      final h = Harness(
        rates: kPlanRates,
        amp: {6.5: 3, 6.0: 4, 5.5: 6, 5.0: 4, 4.5: 3},
      );
      await h.start();
      await h.run(sec(749));
      expect(h.c.state, SweepState.running);
      expect(h.released, 0);
      await h.run(sec(750));
      expect(h.c.state, SweepState.finished);
      expect(h.acquired, 1);
      expect(h.released, 1);
      expect(h.decodeCalls.length, 5);
      final r = h.c.result!;
      expect(r.blocks.length, 5);
      expect(r.outcome, ComparisonOutcome.tentativeRate);
      expect(r.rateBpm, 5.5);
    });

    test('ticking again at or after the total finishes nothing twice',
        () async {
      final h = Harness();
      await h.start();
      await h.run(sec(299));
      h.clock = h.t0.add(sec(300));
      h.c.tick();
      h.c.tick();
      await pumpEventQueue();
      final cuesAtEnd = h.cues.length;
      h.clock = h.t0.add(sec(400));
      h.c.tick();
      h.c.tapFrame('late');
      await pumpEventQueue();
      expect(h.c.state, SweepState.finished);
      expect(h.decodeCalls.length, 2);
      expect(h.released, 1);
      expect(h.cues.length, cuesAtEnd);
    });

    test('two blocks cannot be compared: the result abstains', () async {
      final h = Harness();
      await h.start();
      await h.run(sec(300));
      expect(h.c.result!.outcome, ComparisonOutcome.inconclusiveTooFewBlocks);
      expect(h.c.result!.rateBpm, isNull);
    });

    test('a decode failure fails the session and still releases once',
        () async {
      final h = Harness(decodeThrows: true);
      await h.start();
      await h.run(sec(300));
      expect(h.c.state, SweepState.failed);
      expect(h.c.error, isNotNull);
      expect(h.c.error, isNotEmpty);
      expect(h.c.result, isNull);
      expect(h.released, 1);
    });
  });

  group('stop', () {
    test('mid-session scores complete blocks only, as stopped early',
        () async {
      final h = Harness(
        rates: kPlanRates,
        amp: {6.5: 3, 6.0: 4, 5.5: 6, 5.0: 4, 4.5: 3},
      );
      await h.start();
      await h.run(sec(400)); // blocks 0 and 1 are done; block 2 is half way
      await h.c.stop();
      expect(h.c.state, SweepState.stopped);
      final r = h.c.result!;
      expect(r.outcome, ComparisonOutcome.stoppedEarly);
      expect(r.rateBpm, isNull);
      expect(r.range, isNull);
      expect(r.blocks.map((b) => b.rateBpm), [6.5, 6.0]);
      expect(h.decodeCalls.length, 2);
      expect(h.released, 1);
    });

    test('is idempotent, even when called twice at once', () async {
      final h = Harness(rates: kPlanRates);
      await h.start();
      await h.run(sec(400));
      await Future.wait([h.c.stop(), h.c.stop()]);
      await h.c.stop();
      expect(h.c.state, SweepState.stopped);
      expect(h.released, 1);
      expect(h.decodeCalls.length, 2);
    });

    test('after a finished session changes nothing', () async {
      final h = Harness();
      await h.start();
      await h.run(sec(300));
      await h.c.stop();
      expect(h.c.state, SweepState.finished);
      expect(h.released, 1);
      expect(h.decodeCalls.length, 2);
    });

    test('before a start does not throw and releases nothing', () async {
      final h = Harness();
      await h.c.stop();
      expect(h.released, 0);
      expect(h.acquired, 0);
    });

    test('a decode failure on stop fails the session and releases once',
        () async {
      final h = Harness(rates: kPlanRates, decodeThrows: true);
      await h.start();
      await h.run(sec(400));
      await h.c.stop();
      expect(h.c.state, SweepState.failed);
      expect(h.c.error, isNotEmpty);
      expect(h.released, 1);
    });
  });

  group('dispose', () {
    test('releases streams that are still held', () async {
      final h = Harness();
      await h.start();
      h.c.dispose();
      expect(h.released, 1);
    });

    test('releases nothing that was never acquired', () {
      final h = Harness();
      h.c.dispose();
      expect(h.released, 0);
    });

    test('does not release again after a finish or a stop', () async {
      final done = Harness();
      await done.start();
      await done.run(sec(300));
      done.c.dispose();
      expect(done.released, 1);

      final stopped = Harness(rates: kPlanRates);
      await stopped.start();
      await stopped.run(sec(160));
      await stopped.c.stop();
      stopped.c.dispose();
      expect(stopped.released, 1);
    });
  });
}
