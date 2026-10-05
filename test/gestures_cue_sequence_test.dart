// 8AI.3 (red): the gesture cues on the virtual MG band, as an ADDITIVE
// sequence. Each cue is its own band-queue job:
//
//   start()      the start cue, once, when the gesture begins
//   followUp()   ONE follow-up, per count increment (3, 4, 5)
//   confirm()    the confirm cue, when the gesture ends
//
// There is no response(n) that builds start + (n - 1) follow-ups in one job.
// Jobs are spaced by the queue's minimum gap (previous plan end +
// minVibrationGapMs, 8AI), never dropped or merged, and played in the order
// they were asked for.
//
// ASSUMED API (lib/haptics/gesture_cues.dart, GestureCues):
//   Future<BuzzDelivery> start()
//   Future<BuzzDelivery> followUp()
//   Future<BuzzDelivery> confirm()      (as today)
//   response(int) is removed.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import 'support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

final HapticDeviceProfile _slow = HapticDeviceProfile(
  id: _mg.id,
  name: 'MG, 300 ms minimum gap',
  unitMs: _mg.unitMs,
  probeSetId: _mg.probeSetId,
  version: _mg.version,
  phrases: _mg.phrases,
  gaps: [HapticGap(delayMs: 300, minUnits: 4, maxUnits: 6, sourceTests: [35])],
);

class _ProfiledService extends HapticsService {
  _ProfiledService({required super.port, required this.custom})
      : super(allowLong: () => false);
  final HapticDeviceProfile custom;
  @override
  HapticDeviceProfile? get profile => custom;
}

(VirtualMgBand, HapticsService) _rig([HapticDeviceProfile? p]) {
  final band = VirtualMgBand();
  final svc = p == null
      ? HapticsService(port: band, allowLong: () => false)
      : _ProfiledService(port: band, custom: p);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

List<String> _cmds(VirtualMgBand b) =>
    [for (final w in b.writes) '${w.effects} x${w.loop}'];

int _gapBefore(VirtualMgBand b, int i) {
  final prev = b.writes[i - 1];
  return b.writes[i].atMs -
      (prev.atMs + b.writeToFiredMs + prev.playback.envelopeMs);
}

BuzzSequence _custom(List<(List<int>, int, int)> steps) => BuzzSequence(
      const [0],
      durationsMs: const [500],
      profileId: _mg.id,
      profileVersion: _mg.version,
      bakedSteps: [
        for (final (effects, loop, delay) in steps)
          BakedStep(effects: effects, loop: loop, delayMs: delay),
      ],
    );

void main() {
  group('one cue per call', () {
    test('start() plays the start cue only: the pair, one command', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        BuzzDelivery? done;
        GestureCues(haptics: svc).start().then((v) => done = v);
        async.elapse(const Duration(seconds: 20));
        expect(done, BuzzDelivery.complete);
        expect(_cmds(band), ['[47, 152] x1']);
      });
    });

    test('followUp() plays ONE single, however often the gesture counted',
        () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        GestureCues(haptics: svc).followUp();
        async.elapse(const Duration(seconds: 20));
        expect(_cmds(band), ['[14] x1']);
      });
    });

    test('confirm() plays the confirm cue only', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        GestureCues(haptics: svc).confirm();
        async.elapse(const Duration(seconds: 20));
        expect(_cmds(band), hasLength(1));
        expect(_cmds(band).single, isNot('[47, 152] x1'),
            reason: 'not the start cue');
        expect(_cmds(band).single, isNot('[14] x1'),
            reason: 'not a follow-up');
      });
    });
  });

  group('a gesture that goes to 5', () {
    test('start, follow-up, follow-up, follow-up, confirm: five jobs, in '
        'order, none dropped or merged', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(haptics: svc);
        final done = <BuzzDelivery>[];
        // The moments the session asks for them, in the gesture's order.
        cues.start().then(done.add);
        cues.followUp().then(done.add); // count 3
        cues.followUp().then(done.add); // count 4
        cues.followUp().then(done.add); // count 5
        cues.confirm().then(done.add);
        async.elapse(const Duration(seconds: 60));
        expect(done, List.filled(5, BuzzDelivery.complete));
        final start = '[47, 152] x1';
        final follow = '[14] x1';
        final seq = _cmds(band);
        expect(seq, hasLength(5), reason: 'one write per cue, none merged');
        expect(seq.sublist(0, 4), [start, follow, follow, follow]);
        expect(band.played, hasLength(5), reason: 'the band swallowed none');
      });
    });

    test('the cues are written the minimum gap after the one before ended',
        () {
      fakeAsync((async) {
        final (band, svc) = _rig(_slow);
        final cues = GestureCues(haptics: svc);
        cues.start();
        cues.followUp();
        cues.followUp();
        cues.followUp();
        cues.confirm();
        async.elapse(const Duration(seconds: 120));
        expect(band.writes, hasLength(5));
        expect(band.played, hasLength(5));
        for (var i = 1; i < 5; i++) {
          expect(_gapBefore(band, i), greaterThanOrEqualTo(300),
              reason: 'cue ${i + 1} was written too close to cue $i');
        }
      });
    });

    test('a cue asked for late is still queued behind the earlier ones',
        () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final cues = GestureCues(haptics: svc);
        cues.start();
        async.elapse(const Duration(milliseconds: 200)); // start still plays
        cues.followUp();
        cues.followUp();
        async.elapse(const Duration(seconds: 60));
        expect(_cmds(band), ['[47, 152] x1', '[14] x1', '[14] x1']);
        expect(band.played, hasLength(3));
      });
    });
  });

  group('the user\'s cues: start N1* N1* R1 N1* N1*, follow-up N1*', () {
    // What the wearer reported: ".. x2" as start (4 pulses), ".." x1 as
    // follow-up (one pulse). On a count step they felt four pulses, not one.
    test('a follow-up is the follow-up cue alone, one pulse', () {
      fakeAsync((async) {
        final (band, svc) = _rig();
        final stored = <String, BuzzSequence>{
          'gesture.start': _custom([
            ([47], 1, 0),
            ([47], 1, 0),
            ([47], 1, 125),
            ([47], 1, 0),
          ]),
          'gesture.followUp': _custom([
            ([47], 1, 0),
          ]),
        };
        final cues = GestureCues(haptics: svc, patternFor: (k) => stored[k]);
        cues.followUp();
        async.elapse(const Duration(seconds: 30));
        expect(_cmds(band), ['[47] x1'],
            reason: 'one pulse; the start cue is not replayed');
      });
    });
  });

  group('a band with no profile: one pulse per increment', () {
    test('start, follow-up, follow-up are three plain pulses, one job each',
        () {
      fakeAsync((async) {
        final band = VirtualMgBand(generation: 'gen4');
        final svc = HapticsService(port: band, allowLong: () => false);
        band.onEvent = svc.onBandEvent;
        expect(svc.profile, isNull);
        final cues = GestureCues(haptics: svc);
        cues.start();
        cues.followUp();
        cues.followUp();
        async.elapse(const Duration(seconds: 30));
        expect(band.writes, hasLength(3));
        expect([for (final w in band.writes) w.effects], [
          [0],
          [0],
          [0],
        ]);
      });
    });

    test('the confirm is one more plain pulse', () {
      fakeAsync((async) {
        final band = VirtualMgBand(generation: 'gen4');
        final svc = HapticsService(port: band, allowLong: () => false);
        band.onEvent = svc.onBandEvent;
        GestureCues(haptics: svc).confirm();
        async.elapse(const Duration(seconds: 10));
        expect(band.writes, hasLength(1));
      });
    });
  });

  test('not connected: a cue writes nothing and says it was rejected', () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      band.connected = false;
      BuzzDelivery? done;
      GestureCues(haptics: svc).followUp().then((v) => done = v);
      async.elapse(const Duration(seconds: 20));
      expect(band.writes, isEmpty);
      expect(done, BuzzDelivery.rejected);
    });
  });
}
