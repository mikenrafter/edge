// The "gyro ready" cue: one short buzz that tells the wearer motion data is
// flowing. It reuses the gesture follow-up slot's single buzz (the shortest
// single command of the band's vocabulary), which is distinct from the start
// cue's pair, the confirm cue and the failure cue. A band with no haptic
// profile (a 4.0) plays one plain pulse.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import 'support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

(VirtualMgBand, HapticsService) _rig({String generation = 'gen5'}) {
  final band = VirtualMgBand(generation: generation);
  final svc = HapticsService(port: band, allowLong: () => false);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

List<String> _cmds(VirtualMgBand b) =>
    [for (final w in b.writes) '${w.effects} x${w.loop}'];

void main() {
  test('plays one short single buzz, different from start, confirm and failed',
      () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      final cues = GestureCues(haptics: svc);
      Future<BuzzDelivery> done = cues.ready();
      BuzzDelivery? result;
      done.then((d) => result = d);
      async.elapse(const Duration(seconds: 20));
      expect(result, BuzzDelivery.complete);
      expect(_cmds(band), ['[14] x1']);

      final (other, svc2) = _rig();
      final c2 = GestureCues(haptics: svc2);
      c2.start();
      c2.confirm();
      c2.failed();
      async.elapse(const Duration(seconds: 60));
      expect(_cmds(other), isNot(contains('[14] x1')));
    });
  });

  test('a follow-up pattern the wearer assigned is what plays', () {
    fakeAsync((async) {
      final (band, svc) = _rig();
      final mine = BuzzSequence(
        const [0],
        durationsMs: const [500],
        profileId: _mg.id,
        profileVersion: _mg.version,
        bakedSteps: [BakedStep(effects: const [47], loop: 1, delayMs: 0)],
      );
      GestureCues(
        haptics: svc,
        patternFor: (k) => k == 'gesture.followUp' ? mine : null,
      ).ready();
      async.elapse(const Duration(seconds: 20));
      expect(_cmds(band), ['[47] x1']);
    });
  });

  test('a band with no haptic profile (a 4.0) plays one plain pulse', () {
    fakeAsync((async) {
      final (band, svc) = _rig(generation: 'gen4');
      GestureCues(haptics: svc).ready();
      async.elapse(const Duration(seconds: 20));
      expect(band.writes, hasLength(1));
    });
  });
}
