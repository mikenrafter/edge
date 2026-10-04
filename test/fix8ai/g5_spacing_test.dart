// 8AI G5 (red): the gesture queue honours the minimum spacing between two
// vibrations that the wake vocabulary learned, from ONE constant.
//
// Spec: "The gesture queue that streams buzzes to the band must honour the
// minimum inter-vibration spacing learned for the wake vocabulary (find the
// vocabulary constants from 8AF.6 and reuse the SAME constant; one source,
// AGENTS.md 3.8)."
//
// What exists today (8AF.6): the learned spacing is the profile's FASTEST
// stable gap, `HapticDeviceProfile.fastestGap()` (0 ms write delay after the
// band's ended event on the MG). `GestureCues.response` reads it
// (`p.fastestGap()?.delayMs`) for the follow-ups of ONE response; the wake
// plans in `WakeHaptics._plan` hard-code `delayMs: 0` (a second copy of the
// same number), and nothing spaces two gesture JOBS (the start cue the tap
// sends now, and the count response that follows it).
//
// ASSUMED API:
//   * `HapticDeviceProfile.minVibrationGapMs` (int getter,
//     lib/haptics/haptic_profile.dart): the minimum wait the band needs between
//     the end of one vibration and the write of the next, `fastestGap()`'s
//     `delayMs` (0 when the profile has no stable gap). It is the ONE source:
//     wake_haptics.dart and gesture_cues.dart read it and neither repeats the
//     number or calls `fastestGap()` itself.
//   * Within one gesture response (GestureCues.response) every follow-up is
//     written `minVibrationGapMs` after the band's ended event for the buzz
//     before it (already so today).
//   * Between two gesture jobs in a row, the later job's first write is at
//     least `minVibrationGapMs` after the earlier job's last vibration ended.
//     The queue (BandHapticQueue, driven by HapticsService with the profile's
//     gap) holds the next job that long.
//   * Wake plans (WakeHaptics.natural) write each command `minVibrationGapMs`
//     after the ended event of the one before it.
//
// The behavioural tests use a profile whose only measured gap is 300 ms (the
// real MG's is 0 ms, which would make every test trivially equal): a
// HapticsService subclass overrides `profile`, the way a band with another
// vocabulary would.
//
// Failure mode today: the getter does not exist; the wake plan writes at +0 ms
// whatever the profile says; two gesture jobs run back to back at +0 ms; both
// files repeat the number.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/gesture_cues.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/wake_haptics.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

import '../phase8/support/dart_source.dart';
import '../support/virtual_mg.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

/// The MG's phrases with ONE stable gap: write 300 ms after the ended event.
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

(VirtualMgBand, HapticsService) _rig(HapticDeviceProfile p) {
  final band = VirtualMgBand();
  final svc = _ProfiledService(port: band, custom: p);
  band.onEvent = svc.onBandEvent;
  return (band, svc);
}

/// How long after write [i - 1] ended (event 100) write [i] happened.
int _gapBefore(VirtualMgBand b, int i) {
  final prev = b.writes[i - 1];
  return b.writes[i].atMs -
      (prev.atMs + b.writeToFiredMs + prev.playback.envelopeMs);
}

void main() {
  group('the one constant', () {
    test('minVibrationGapMs is the profile\'s fastest gap', () {
      expect((_slow as dynamic).minVibrationGapMs, 300);
      expect((_mg as dynamic).minVibrationGapMs, _mg.fastestGap()!.delayMs);
    });

    test('a profile with no stable gap has none to honour: 0', () {
      final none = HapticDeviceProfile(
        id: _mg.id,
        name: 'no gaps',
        unitMs: _mg.unitMs,
        probeSetId: _mg.probeSetId,
        phrases: _mg.phrases,
        gaps: [
          HapticGap(
              delayMs: 100,
              minUnits: 1,
              maxUnits: 6,
              stable: false,
              sourceTests: [5]),
        ],
      );
      expect((none as dynamic).minVibrationGapMs, 0);
    });
  });

  group('within one cue (8AI.3: each cue is its own job)', () {
    test('a cue of two commands writes the second the constant after the '
        'ended event', () {
      fakeAsync((async) {
        final (band, svc) = _rig(_slow);
        // The built-in start is one command; the confirm is one; a stored
        // two-command cue is what chains inside one job.
        GestureCues(
          haptics: svc,
          patternFor: (k) => BuzzSequence(
            const [0],
            durationsMs: const [500],
            profileId: _slow.id,
            profileVersion: _slow.version,
            bakedSteps: [
              BakedStep(effects: const [47], loop: 1, delayMs: 0),
              BakedStep(effects: const [14], loop: 1, delayMs: 300),
            ],
          ),
        ).followUp();
        async.elapse(const Duration(seconds: 30));
        expect(band.writes, hasLength(2));
        expect(_gapBefore(band, 1), 300);
      });
    });
  });

  group('between two gesture jobs', () {
    test('the start cue and the count response that follows are spaced by '
        'the constant', () {
      fakeAsync((async) {
        final (band, svc) = _rig(_slow);
        final cues = GestureCues(haptics: svc);
        cues.start(); // the start cue the tap sends
        cues.followUp(); // the first count increment, behind it in the queue
        cues.followUp(); // the next one
        async.elapse(const Duration(seconds: 60));
        expect(band.writes, hasLength(3));
        expect(band.played, hasLength(3), reason: 'none swallowed');
        for (var i = 1; i < 3; i++) {
          expect(_gapBefore(band, i), greaterThanOrEqualTo(300),
              reason: 'job ${i + 1} started too close to job $i');
        }
      });
    });

    test('with the real MG (0 ms) nothing is added: back to back as today',
        () {
      fakeAsync((async) {
        final (band, svc) = _rig(_mg);
        final cues = GestureCues(haptics: svc);
        cues.start();
        cues.followUp();
        async.elapse(const Duration(seconds: 60));
        expect(band.writes, hasLength(2));
        expect(_gapBefore(band, 1), (_mg as dynamic).minVibrationGapMs);
      });
    });
  });

  group('wake plans use the same constant', () {
    test('natural wake writes each command the constant after the ended '
        'event', () {
      fakeAsync((async) {
        final (band, svc) = _rig(_slow);
        BuzzDelivery? done;
        WakeHaptics(svc)
            .natural(runAlarm: () async => BuzzDelivery.complete)
            .then((v) => done = v);
        async.elapse(const Duration(seconds: 60));
        expect(done, BuzzDelivery.complete);
        expect(band.writes, hasLength(3));
        for (var i = 1; i < 3; i++) {
          expect(_gapBefore(band, i), 300, reason: 'command ${i + 1}');
        }
      });
    });

    test('a gradual step still plays its one phrase', () {
      fakeAsync((async) {
        final (band, svc) = _rig(_slow);
        WakeHaptics(svc).gradualStep(GradualPattern.steady, 0,
            perTap: BuzzSequence([0]));
        async.elapse(const Duration(seconds: 10));
        expect(band.writes, hasLength(1));
      });
    });
  });

  group('one source (source guards)', () {
    test('the profile defines the constant from its fastest gap', () {
      final src = File('lib/haptics/haptic_profile.dart').readAsStringSync();
      final code = codeOnly(src);
      expect(code, contains('minVibrationGapMs'));
      expect(RegExp(r'minVibrationGapMs[^;]*fastestGap\(\)').hasMatch(code),
          isTrue,
          reason: 'it is fastestGap().delayMs, not a second literal');
    });

    // 8AI.3: a gesture cue is its own queue job, so the spacing between cues
    // is the queue's (haptics_service.dart hands it the constant); the cues
    // themselves chain nothing and repeat no gap.
    for (final f in ['wake_haptics.dart', 'haptics_service.dart']) {
      test('$f reads the constant and repeats neither the number nor '
          'fastestGap()', () {
        final code = codeOnly(File('lib/haptics/$f').readAsStringSync());
        expect(code, contains('minVibrationGapMs'));
        expect(code, isNot(contains('fastestGap(')),
            reason: 'two readers of the table are two sources');
        expect(RegExp(r'delayMs:\s*0\b').hasMatch(code), isFalse,
            reason: 'a literal 0 ms gap is the number copied');
      });
    }

    test('gesture_cues.dart chains no cues and repeats no gap', () {
      final code =
          codeOnly(File('lib/haptics/gesture_cues.dart').readAsStringSync());
      expect(code, isNot(contains('fastestGap(')));
      expect(code, isNot(contains('minVibrationGapMs')),
          reason: 'the queue spaces the cues, not GestureCues');
      expect(RegExp(r'delayMs:\s*0\b').hasMatch(code), isFalse);
    });
  });
}
