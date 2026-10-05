// 8AE.5 P1: HapticsService, the one owner of band haptic delivery.
//
// AppState used to hold the band queue, its ledger, the ended signal and the
// delivery helpers, so their wiring could only be checked by reading
// app_state.dart. HapticsService takes the engine as a BandHapticsPort, so the
// same wiring is driven here with a fake band:
//
//   delivery routing (baked plan, notes, taps, per-tap on a band with no
//   profile), the profile chosen by the band's generation, allow-long read per
//   delivery, the queue and its ledger, lab mode, and the band's ended event.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import 'support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

/// A band that records every command with the time it was written.
class _FakePort implements BandHapticsPort {
  _FakePort(this.async);
  final FakeAsync async;
  bool connected = true;
  String? gen = 'gen5';

  /// Called after each pattern write, with the write's index (0 based).
  void Function(int index)? onPattern;

  final patterns = <String>[];
  final patternAt = <int>[];
  final holds = <int>[];

  @override
  bool get isConnected => connected;

  @override
  String? get generation => gen;

  @override
  Future<bool> buzzBand({int holdMs = 0}) async {
    holds.add(holdMs);
    return true;
  }

  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) async {
    patterns.add('$effects x$loop');
    patternAt.add(async.elapsed.inMilliseconds);
    onPattern?.call(patterns.length - 1);
    return true;
  }
}

HapticsService _service(
  _FakePort port, {
  bool Function()? allowLong,
  List<String>? log,
}) =>
    HapticsService(
      port: port,
      allowLong: allowLong ?? () => false,
      log: log?.add,
    );

/// One stored step of the MG profile (47 is a measured 4-unit phrase).
BuzzSequence _baked({
  List<BakedStep>? steps,
  int? runtimeMs,
  String? notes,
  List<int> offsets = const [0],
  List<int> durations = const [500],
}) =>
    BuzzSequence(
      offsets,
      durationsMs: durations,
      notes: notes,
      profileId: _mg.id,
      profileVersion: _mg.version,
      bakedSteps: steps ?? [BakedStep(effects: const [47], loop: 1, delayMs: 0)],
      bakedRuntimeMs: runtimeMs,
    );

BuzzSequence _twoBaked() => _baked(steps: [
      BakedStep(effects: const [47], loop: 1, delayMs: 0),
      BakedStep(effects: const [47], loop: 1, delayMs: 0),
    ]);

/// A band event as the engine reports it: [ageSeconds] old.
StrapEvent _event(int id, {int ageSeconds = 0}) {
  final now = DateTime.now();
  return StrapEvent(
    eventId: id,
    tsEpoch: now.millisecondsSinceEpoch ~/ 1000 - ageSeconds,
    receivedAt: now,
    hex: '',
    deviceId: 'dev',
  );
}

BuzzDelivery? _done;

void _deliver(HapticsService s, BuzzSequence seq) {
  s.deliver(seq).then((v) => _done = v);
}

void main() {
  setUp(() => _done = null);

  group('delivery routing on a band with a profile (gen5)', () {
    test('a stored plan plays as stored, ahead of the notes and the taps', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final s = _baked(notes: 'N4ff R4 N4ff', durations: const [500]);
        _deliver(_service(port), s);
        async.elapse(const Duration(minutes: 1));
        expect(_done, BuzzDelivery.complete);
        expect(port.patterns, ['[47] x1']);
        expect(port.holds, isEmpty);
      });
    });

    test('notes with no stored plan are compiled and played', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        const code = 'N4ff R4 N4ff';
        final s = BuzzSequence(const [0],
            durationsMs: const [500], notes: code, profileId: _mg.id);
        final plan = compile(PatternTranscript.parseCode(code).entries, _mg,
            dynamicWeight: 1,
            maxRuntimeMs: kMaxHapticRuntime.inMilliseconds)!;
        final taps = planForTaps(s, _mg)!;
        _deliver(_service(port), s);
        async.elapse(const Duration(minutes: 1));
        expect(_done, BuzzDelivery.complete);
        final want = [
          for (final st in plan.steps) '${st.phrase.effects} x${st.phrase.loop}',
        ];
        expect(port.patterns, want);
        expect(
          want,
          isNot([
            for (final st in taps.steps)
              '${st.phrase.effects} x${st.phrase.loop}',
          ]),
          reason: 'the notes, not the taps, must be what played',
        );
      });
    });

    test('taps with neither a plan nor notes are compiled and played', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final s = BuzzSequence([0, 875], durationsMs: [500, 500]);
        final plan = planForTaps(s, _mg)!;
        _deliver(_service(port), s);
        async.elapse(const Duration(minutes: 1));
        expect(_done, BuzzDelivery.complete);
        expect(port.patterns, [
          for (final st in plan.steps) '${st.phrase.effects} x${st.phrase.loop}',
        ]);
        expect(port.holds, isEmpty);
      });
    });

    test('a rhythm that does not compile is played tap by tap', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        // Five 3 s holds are over the 10 s cap: no plan, so one buzz per tap.
        final s = BuzzSequence(
          [for (var i = 0; i < 5; i++) i * 5000],
          durationsMs: List.filled(5, 3000),
        );
        expect(planForTaps(s, _mg), isNull);
        _deliver(_service(port), s);
        async.elapse(const Duration(minutes: 2));
        expect(_done, BuzzDelivery.complete);
        expect(port.patterns, isEmpty);
        expect(port.holds, List.filled(5, 3000));
      });
    });

    test('not connected: rejected and nothing written', () {
      fakeAsync((async) {
        final port = _FakePort(async)..connected = false;
        _deliver(_service(port), _twoBaked());
        async.elapse(const Duration(minutes: 1));
        expect(_done, BuzzDelivery.rejected);
        expect(port.patterns, isEmpty);
        expect(port.holds, isEmpty);
      });
    });
  });

  group('the profile follows the band\'s generation', () {
    test('gen4 and an unknown generation have none: per-tap buzzes only', () {
      for (final gen in <String?>['gen4', null]) {
        fakeAsync((async) {
          final port = _FakePort(async)..gen = gen;
          final svc = _service(port);
          expect(svc.profile, isNull, reason: '$gen');
          _deliver(svc, _baked());
          async.elapse(const Duration(minutes: 1));
          expect(_done, BuzzDelivery.complete, reason: '$gen');
          expect(port.patterns, isEmpty, reason: '$gen');
          expect(port.holds, [500], reason: '$gen');
        });
      }
    });

    test('gen5 is the MG profile, read again on every delivery', () {
      fakeAsync((async) {
        final port = _FakePort(async)..gen = 'gen4';
        final svc = _service(port);
        expect(svc.profile, isNull);
        port.gen = 'gen5';
        expect(svc.profile, same(_mg));
        _deliver(svc, _baked());
        async.elapse(const Duration(minutes: 1));
        expect(port.patterns, ['[47] x1']);
      });
    });

    test('sequenceTimeout is the sequence\'s own on gen4 and covers the plan '
        'on gen5', () {
      fakeAsync((async) {
        final port = _FakePort(async)..gen = 'gen4';
        final svc = _service(port);
        final s = _twoBaked();
        expect(svc.sequenceTimeout(s), s.transportTimeout);
        port.gen = 'gen5';
        expect(
          svc.sequenceTimeout(s),
          bandSequenceTimeout(s, _mg, maxRuntime: kMaxHapticRuntime),
        );
        expect(svc.sequenceTimeout(s), greaterThan(s.transportTimeout));
      });
    });
  });

  group('allow-long is read when a delivery happens', () {
    // A stored plan whose felt runtime (11 s) is over the 10 s cap.
    // Three stored commands; the cap refuses them, and the taps (one 500 ms
    // hold) compile to a single command instead.
    BuzzSequence longBaked() => _baked(runtimeMs: 11000, steps: [
          for (var i = 0; i < 3; i++)
            BakedStep(effects: const [14], loop: 1, delayMs: 0),
        ]);
    const stored = ['[14] x1', '[14] x1', '[14] x1'];

    test('off: the stored plan is refused; on: it plays', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        var allow = false;
        final svc = _service(port, allowLong: () => allow);
        expect(svc.maxRuntime, kMaxHapticRuntime);

        _deliver(svc, longBaked());
        async.elapse(const Duration(minutes: 3));
        expect(port.patterns, isNot(stored),
            reason: 'over the cap with allow-long off');

        allow = true;
        expect(svc.maxRuntime, isNull);
        port.patterns.clear();
        _deliver(svc, longBaked());
        async.elapse(const Duration(minutes: 3));
        expect(port.patterns, stored);
      });
    });

    test('sequenceTimeout follows the same setting', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        var allow = false;
        final svc = _service(port, allowLong: () => allow);
        final s = longBaked();
        final capped = svc.sequenceTimeout(s);
        allow = true;
        expect(svc.sequenceTimeout(s), isNot(capped));
        expect(svc.sequenceTimeout(s),
            bandSequenceTimeout(s, _mg, maxRuntime: null));
      });
    });
  });

  group('the queue and its ledger', () {
    test('every delivery counts its commands into the one ledger', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        expect(svc.commandsLeft, BandCommandLedger.maxCommands);
        _deliver(svc, _twoBaked());
        async.elapse(const Duration(seconds: 30));
        expect(port.patterns, hasLength(2));
        expect(svc.commandsLeft, BandCommandLedger.maxCommands - 2);
        expect(svc.ledger.commandsLeft(clock.now()),
            svc.commandsLeft,
            reason: 'the ledger the probes share is the one counted');
        // The window passes: the commands leave it.
        async.elapse(const Duration(minutes: 3));
        expect(svc.commandsLeft, BandCommandLedger.maxCommands);
      });
    });

    test('runJob is the door: a job over the ledger size is rejected unrun',
        () {
      fakeAsync((async) {
        final svc = _service(_FakePort(async));
        var ran = false;
        BuzzDelivery? out;
        svc.runJob(BandCommandLedger.maxCommands + 1, (job) async {
          ran = true;
          return BuzzDelivery.complete;
        }).then((v) => out = v);
        async.elapse(const Duration(seconds: 5));
        expect(out, BuzzDelivery.rejected);
        expect(ran, isFalse);
      });
    });

    test('a job writes through its token: counted, and one at a time', () {
      fakeAsync((async) {
        final svc = _service(_FakePort(async));
        final order = <String>[];
        Future<BuzzDelivery> job(String name, BandJobToken t) async {
          order.add('$name start');
          final ok = await t.write(() async => true);
          order.add('$name wrote $ok');
          return BuzzDelivery.complete;
        }

        svc.runJob(1, (t) => job('a', t));
        svc.runJob(1, (t) => job('b', t));
        async.elapse(const Duration(seconds: 30));
        expect(order, ['a start', 'a wrote true', 'b start', 'b wrote true']);
        expect(svc.commandsLeft, BandCommandLedger.maxCommands - 2);
        expect(svc.pending, 0);
      });
    });

    test('two deliveries never overlap: the second waits for the first', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        svc.deliver(_baked());
        svc.deliver(_baked());
        expect(svc.pending, 2);
        async.elapse(const Duration(minutes: 1));
        expect(port.patterns, ['[47] x1', '[47] x1']);
        expect(port.patternAt[1] - port.patternAt[0], greaterThan(1000),
            reason: 'the band is held through the first one\'s playback');
      });
    });

    test('the queue reports progress to the injected log', () {
      fakeAsync((async) {
        final log = <String>[];
        final svc = _service(_FakePort(async), log: log);
        svc.runJob(BandCommandLedger.maxCommands + 1,
            (_) async => BuzzDelivery.complete);
        async.elapse(const Duration(seconds: 1));
        expect(log, isNotEmpty);
        expect(log.first, contains('dropped'));
      });
    });
  });

  group('the band\'s ended event (100)', () {
    // A baked plan of two commands: without an ended event the second is
    // written after the first phrase's wait (4 units of 125 ms plus 1.5 s).
    const fullWaitMs = 4 * 125 + 1500;

    test('a live 100 releases the next command at once', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        port.onPattern = (i) {
          if (i == 0) {
            Timer(const Duration(milliseconds: 300),
                () => svc.onBandEvent(_event(100)));
          }
        };
        _deliver(svc, _twoBaked());
        async.elapse(const Duration(minutes: 1));
        expect(port.patternAt, [0, 300]);
      });
    });

    test('without it the second command waits the full time', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        _deliver(_service(port), _twoBaked());
        async.elapse(const Duration(minutes: 1));
        expect(port.patternAt, [0, fullWaitMs]);
      });
    });

    test('an old 100 (the band replays events in bursts) releases nothing',
        () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        port.onPattern = (i) {
          if (i == 0) {
            Timer(const Duration(milliseconds: 300),
                () => svc.onBandEvent(_event(100, ageSeconds: 600)));
          }
        };
        _deliver(svc, _twoBaked());
        async.elapse(const Duration(minutes: 1));
        expect(port.patternAt, [0, fullWaitMs]);
      });
    });

    test('another event id releases nothing', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        port.onPattern = (i) {
          if (i == 0) {
            Timer(const Duration(milliseconds: 300),
                () => svc.onBandEvent(_event(99)));
          }
        };
        _deliver(svc, _twoBaked());
        async.elapse(const Duration(minutes: 1));
        expect(port.patternAt, [0, fullWaitMs]);
      });
    });

    test('a 100 from before a write is cleared by the write', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        svc.onBandEvent(_event(100)); // arrives before anything is written
        _deliver(svc, _twoBaked());
        async.elapse(const Duration(minutes: 1));
        expect(port.patternAt, [0, fullWaitMs],
            reason: 'the first write resets the signal');
      });
    });
  });

  group('lab mode', () {
    test('with the lab open an ordinary delivery is held until it closes', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        expect(svc.labOpen, isFalse);
        svc.beginLab();
        expect(svc.labOpen, isTrue);
        _deliver(svc, _baked());
        async.elapse(const Duration(minutes: 1));
        expect(port.patterns, isEmpty);
        expect(_done, isNull);
        svc.endLab();
        expect(svc.labOpen, isFalse);
        async.elapse(const Duration(minutes: 1));
        expect(port.patterns, ['[47] x1']);
        expect(_done, BuzzDelivery.complete);
      });
    });

    test('runLab plays alone and ahead of a held delivery', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        final order = <String>[];
        svc.beginLab();
        svc.deliver(_baked()).then((_) => order.add('alert'));
        bool? ran;
        svc.runLab(() async => order.add('probe')).then((v) => ran = v);
        async.elapse(const Duration(seconds: 30));
        expect(ran, isTrue);
        expect(order, ['probe']);
        svc.endLab();
        async.elapse(const Duration(minutes: 1));
        expect(order, ['probe', 'alert']);
      });
    });

    test('asLabWork turns a delivery into a lab job only while the lab is '
        'open', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);

        // Lab closed: plain work, ordinary job.
        var plain = false;
        svc.asLabWork(() async => plain = true);
        async.flushMicrotasks();
        expect(plain, isTrue);

        svc.beginLab();
        final held = BuzzSequence([0], durationsMs: [500]);
        final labSeq = _baked();
        var heldDone = false;
        svc.deliver(held).then((_) => heldDone = true);
        svc.asLabWork(() => svc.deliver(labSeq));
        async.elapse(const Duration(seconds: 30));
        expect(port.patterns, ['[47] x1'], reason: 'the lab job went');
        expect(heldDone, isFalse);
        svc.endLab();
        async.elapse(const Duration(minutes: 1));
        expect(heldDone, isTrue);
        expect(port.patterns, hasLength(2));
      });
    });

    test('a lab probe reserves from the same ledger real alerts use', () {
      fakeAsync((async) {
        final svc = _service(_FakePort(async));
        final room = svc.ledger.reserve(10, clock.now())!;
        expect(svc.commandsLeft, BandCommandLedger.maxCommands - 10);
        room.release();
        expect(svc.commandsLeft, BandCommandLedger.maxCommands);
      });
    });
  });

  group('buzzForDuration', () {
    test('is one band buzz of that hold through the port', () {
      fakeAsync((async) {
        final port = _FakePort(async);
        final svc = _service(port);
        bool? ok;
        svc.buzzForDuration(750).then((v) => ok = v);
        async.flushMicrotasks();
        expect(ok, isTrue);
        expect(port.holds, [750]);
      });
    });
  });

  group('against the virtual MG band (test/support/virtual_mg.dart)', () {
    // The band's own busy/deaf rules and events, with the service wired to
    // its event stream like AppState does.
    (VirtualMgBand, HapticsService) rig({
      String gen = 'gen5',
      int? backlogAfterMs,
    }) {
      final band = VirtualMgBand(generation: gen, backlogAfterMs: backlogAfterMs);
      final svc = HapticsService(port: band, allowLong: () => false);
      band.onEvent = svc.onBandEvent;
      return (band, svc);
    }

    // When the band's event 100 for [w] comes, ms on the band's clock.
    int endedAt(MgWrite w) => w.atMs + 15 + w.playback.envelopeMs;

    test('two queued alerts never overlap: the second is written after the '
        'first one\'s event 100, and the band plays both', () {
      fakeAsync((async) {
        final (band, svc) = rig();
        svc.deliver(_baked());
        svc.deliver(_baked());
        async.elapse(const Duration(minutes: 1));
        expect(band.writes, hasLength(2));
        expect(band.writes.every((w) => w.played), isTrue,
            reason: 'nothing was written into a playing band');
        expect(band.writes[1].atMs, greaterThanOrEqualTo(endedAt(band.writes[0])));
        // Released by the 100 itself, not by the 1.5 s fallback.
        expect(band.writes[1].atMs - endedAt(band.writes[0]), lessThan(500));
      });
    });

    test('a burst of alerts: every write plays, none is swallowed or ignored',
        () {
      fakeAsync((async) {
        final (band, svc) = rig();
        var done = 0;
        for (var i = 0; i < 6; i++) {
          svc.deliver(_baked()).then((v) {
            if (v == BuzzDelivery.complete) done++;
          });
        }
        async.elapse(const Duration(minutes: 1));
        expect(done, 6);
        expect(band.writes, hasLength(6));
        expect(band.writes.every((w) => w.played && w.reply == 'pending'),
            isTrue);
        for (var i = 1; i < band.writes.length; i++) {
          expect(band.writes[i].atMs,
              greaterThanOrEqualTo(endedAt(band.writes[i - 1])));
        }
      });
    });

    test('a multi-command plan waits for each command\'s event 100', () {
      fakeAsync((async) {
        final (band, svc) = rig();
        _deliver(svc, _twoBaked());
        async.elapse(const Duration(minutes: 1));
        expect(_done, BuzzDelivery.complete);
        expect(band.played, hasLength(2));
        expect(band.writes[1].atMs, greaterThanOrEqualTo(endedAt(band.writes[0])));
      });
    });

    test('what the emulator does to a write made during playback is why the '
        'service never makes one', () {
      fakeAsync((async) {
        final (band, svc) = rig();
        svc.deliver(_baked());
        async.elapse(const Duration(milliseconds: 400)); // playing
        band.buzzMaverickPattern(const [47], 1); // a stray direct write
        async.elapse(const Duration(minutes: 1));
        expect(band.writes[1].played, isFalse);
        expect(band.writes[1].reply, 'pending');
      });
    });

    test('old 60/100 events delivered late in a burst release nothing', () {
      fakeAsync((async) {
        final (band, svc) = rig(backlogAfterMs: 300);
        _deliver(svc, _twoBaked());
        async.elapse(const Duration(minutes: 1));
        expect(_done, BuzzDelivery.complete);
        expect(band.events.where((e) => !e.$2.isLive), isNotEmpty);
        expect(band.played, hasLength(2));
        expect(band.writes[1].atMs, greaterThanOrEqualTo(endedAt(band.writes[0])),
            reason: 'a stale 100 must not release the next command');
      });
    });

    test('gen4 sends no event 100: the per-tap buzzes and the next job fall '
        'back on the playback time, and the band plays all of them', () {
      fakeAsync((async) {
        final (band, svc) = rig(gen: 'gen4');
        final taps = BuzzSequence(const [0, 900], durationsMs: const [500, 500]);
        svc.deliver(taps);
        svc.deliver(taps);
        async.elapse(const Duration(minutes: 1));
        expect(band.events, isEmpty);
        expect(band.writes, hasLength(4));
        expect(band.writes.every((w) => w.played), isTrue);
        // Between jobs the queue holds the band for kBandBuzzPlayback.
        expect(band.writes[2].atMs - band.writes[1].atMs,
            greaterThanOrEqualTo(kBandBuzzPlayback.inMilliseconds));
      });
    });

    test('lab hold: held alerts wait out the lab, whose probe writes play '
        'alone; afterwards the alert plays', () {
      fakeAsync((async) {
        final (band, svc) = rig();
        svc.beginLab();
        _deliver(svc, _baked());
        svc.runLab(() async {
          await band.buzzMaverickPattern(const [14], 1);
        });
        async.elapse(const Duration(seconds: 20));
        expect(band.writes, hasLength(1), reason: 'only the probe so far');
        expect(band.writes.single.effects, [14]);
        expect(_done, isNull);
        svc.endLab();
        async.elapse(const Duration(seconds: 30));
        expect(_done, BuzzDelivery.complete);
        expect(band.writes, hasLength(2));
        expect(band.writes.every((w) => w.played), isTrue);
      });
    });

    test('the ledger counts every command the band was given', () {
      fakeAsync((async) {
        final (band, svc) = rig();
        svc.deliver(_twoBaked());
        svc.deliver(_baked());
        async.elapse(const Duration(seconds: 30));
        expect(band.writes, hasLength(3));
        expect(svc.commandsLeft,
            BandCommandLedger.maxCommands - band.writes.length);
        async.elapse(const Duration(minutes: 3));
        expect(svc.commandsLeft, BandCommandLedger.maxCommands);
      });
    });
  });
}
