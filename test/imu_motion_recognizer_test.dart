import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/motion/motion_recognizer.dart';
import 'package:openstrap_edge/gestures/motion/motion_segments.dart';
import 'package:openstrap_edge/gestures/motion/imu_series.dart';
import 'package:openstrap_edge/gestures/motion/twist_calibration.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

import 'support/motion_synth.dart';

MotionDecision decide(Scene s,
        {TwistCalibration? calibration,
        ImuVector gravity = const ImuVector(0, 0, 1),
        ImuVector bias = const ImuVector(0, 0, 0),
        Set<int> gapBefore = const {},
        double clipDps = 2000,
        bool deviceStartup = true}) =>
    recognizeMotion(
        s.packets(
            gravity: gravity,
            bias: bias,
            gapBefore: gapBefore,
            clipDps: clipDps,
            deviceStartup: deviceStartup),
        calibration: calibration);

Scene outTwist({double lead = 1.5, double tail = 1.0}) =>
    Scene().quiet(lead).flick(outAxis).quiet(tail);
Scene inTwist({double lead = 1.5, double tail = 1.0}) =>
    Scene().quiet(lead).flick(inAxis).quiet(tail);

void main() {
  group('signed wrist rotation', () {
    test('turn out and back is rotationOut; the mirror is rotationIn', () {
      expect(decide(outTwist()).kind, MotionKind.rotationOut);
      expect(decide(inTwist()).kind, MotionKind.rotationIn);
    });

    test('three repetitions are still one out', () {
      final s = Scene().quiet(1.5);
      for (var i = 0; i < 3; i++) {
        s.flick(outAxis).quiet(0.8);
      }
      expect(decide(s.quiet(0.5)).kind, MotionKind.rotationOut);
    });

    test('the sign is the turn direction, not which lobe is faster', () {
      final s = Scene()
          .quiet(1.5)
          .flick(inAxis, seconds: 0.2, backSeconds: 0.1)
          .quiet(1);
      expect(decide(s).kind, MotionKind.rotationIn);
    });

    test('gravity direction does not matter', () {
      for (final g in [unit(0, 0, 1), unit(0, 1, 0), unit(1, 0, 0), unit(1, 1, -1)]) {
        expect(decide(outTwist(), gravity: g).kind, MotionKind.rotationOut);
      }
    });

    test('a rotation already under way when the stream starts is not read as '
        'the lead lobe', () {
      // Only the return lobe is visible first (the owner\'s lying-down take).
      final s = Scene()
          .pulse(inAxis, 140, 0.17)
          .quiet(1.2)
          .flick(outAxis)
          .quiet(1);
      final d = decide(s);
      expect(d.kind, MotionKind.rotationOut);
    });

    test('a stream that starts inside a lobe with nothing after is unknown', () {
      final s = Scene().pulse(inAxis, 140, 0.17).quiet(2);
      final d = decide(s);
      expect(d.kind, isNot(MotionKind.rotationOut));
      expect(d.kind, isNot(MotionKind.rotationIn));
    });

    test('angular travel is not net angle: out and back counts, a drift does not',
        () {
      // Out and back: net angle about zero, travel 280 degrees.
      expect(decide(outTwist()).kind, MotionKind.rotationOut);
      // A slow 90 degree turn over 3 s (30 dps) is below the motion floor.
      final slow = Scene().quiet(1).spin(outAxis, 30, 3).quiet(1);
      expect(decide(slow).kind, MotionKind.none);
    });

    test('a quick but weak twist is unknown, never a direction', () {
      final weak = Scene().quiet(1.5).pulse(outAxis, 120, 0.4).quiet(1);
      final d = decide(weak);
      expect(d.kind, MotionKind.unknown);
    });

    test('a gyro bias does not change the answer or create motion', () {
      final b = v3(6, -5, 4);
      expect(decide(outTwist(), bias: b).kind, MotionKind.rotationOut);
      expect(decide(Scene().quiet(4), bias: b).kind, MotionKind.none);
    });

    test('rails: a clipped twist is still read, in the right direction', () {
      final fast = Scene().quiet(1.5).flick(outAxis, angleDeg: 160, seconds: 0.07).quiet(1);
      final d = decide(fast, clipDps: 2000);
      expect(d.kind, MotionKind.rotationOut);
    });

    test('startup marker alone is not motion', () {
      expect(decide(Scene().quiet(3)).kind, MotionKind.none);
    });

    test('a twist cut by a missing stretch is never a confident direction', () {
      // The gap lands between the out lobe and the return.
      final s = Scene().quiet(0.9).flick(outAxis).quiet(1.0);
      final d = decide(s, gapBefore: {1});
      expect(d.kind, isNot(MotionKind.rotationIn));
    });

    test('the turn is about the wrist, not the world: a rotation about '
        'another axis is not a twist', () {
      final s = Scene().quiet(1.5).flick(unit(0, 1, 0)).quiet(1);
      expect(decide(s).kind, isNot(MotionKind.rotationOut));
      expect(decide(s).kind, isNot(MotionKind.rotationIn));
    });

    test('a calibration learns another mounting and the sign of "out"', () {
      final axis = unit(0.2, 0.9, -0.4); // band worn another way
      final cal = TwistCalibration.fromPackets(
          Scene().quiet(1.5).flick(axis).quiet(1).packets());
      expect(cal, isNotNull);
      expect(decide(Scene().quiet(1.5).flick(axis).quiet(1), calibration: cal)
          .kind, MotionKind.rotationOut);
      final back = v3(-axis.x, -axis.y, -axis.z);
      expect(decide(Scene().quiet(1.5).flick(back).quiet(1), calibration: cal)
          .kind, MotionKind.rotationIn);
      // The default axis does not read this band.
      expect(decide(Scene().quiet(1.5).flick(axis).quiet(1)).kind,
          isNot(MotionKind.rotationOut));
    });

    test('a calibration from a still recording is refused', () {
      expect(TwistCalibration.fromPackets(Scene().quiet(3).packets()), isNull);
    });
  });

  group('things that must not become a gesture', () {
    test('walking-like arm swing, sustained: unknown', () {
      final s = Scene().sine(unit(0, 1, 0.3), 260, 1.0, 9);
      final d = decide(s);
      expect(d.kind, MotionKind.unknown);
      expect(d.reason, MotionReason.sustained);
    });

    test('hammering-like repeated twists with no pause: unknown', () {
      final s = Scene();
      for (var i = 0; i < 20; i++) {
        s.flick(outAxis, angleDeg: 100, seconds: 0.1, backSeconds: 0.1).quiet(0.15);
      }
      final d = decide(s);
      expect(d.kind, MotionKind.unknown);
    });

    test('vibration: none', () {
      expect(decide(Scene().vibration(30, 5)).kind, MotionKind.none);
    });

    test('slow vehicle-like turns: none', () {
      final s = Scene().spin(unit(0, 0, 1), 18, 4).spin(unit(0, 0, 1), -18, 4);
      expect(decide(s).kind, MotionKind.none);
    });

    test('no data at all is unknown, not none', () {
      expect(recognizeMotion(const []).kind, MotionKind.unknown);
      expect(recognizeMotion(const []).reason, MotionReason.insufficientData);
    });

    test('missing samples through the motion: unknown, not a verdict', () {
      final s = Scene().quiet(0.5).flick(outAxis).quiet(0.5);
      final packets = s.packets(
          sentinelAt: {for (var i = 55; i < 70; i++) i});
      final d = recognizeMotion(packets);
      expect(d.kind, isNot(MotionKind.rotationOut));
      expect(d.kind, isNot(MotionKind.rotationIn));
    });
  });

  group('claps', () {
    Scene claps(int n) {
      final s = Scene().quiet(1.5);
      for (var i = 0; i < n; i++) {
        // Hands swing in, stop abruptly.
        s.pulse(unit(0, 1, 0), 40, 0.25).impulse(v3(0.5, 0.2, 5.5)).quiet(0.5);
      }
      return s.quiet(0.5);
    }

    test('one, two and three claps are counted', () {
      for (final n in [1, 2, 3]) {
        final d = decide(claps(n));
        expect(d.kind, MotionKind.clap, reason: '$n');
        expect(d.clapCount, n);
      }
    });

    test('an impulse with no approach (a knock on the band) is unknown', () {
      final s = Scene().quiet(2).impulse(v3(0, 0, 6)).quiet(1);
      final d = decide(s);
      expect(d.kind, isNot(MotionKind.clap));
    });

    test('a broad accel bump (a fast circle) is not a clap spike', () {
      final s = Scene().quiet(1.5).pulse(unit(0, 1, 0), 40, 0.25);
      final at = s.length;
      s.quiet(0.6);
      for (var i = 0; i < 30; i++) {
        s.dyn[at + 5 + i] = v3(0, 0, 3.6 * math.sin(math.pi * (i + 0.5) / 30));
      }
      final d = decide(s.quiet(0.5));
      expect(d.kind, isNot(MotionKind.clap));
    });

    test('a twist that throws accel to the rail is a rotation, not claps', () {
      final s = Scene().quiet(1.5);
      final at = s.length;
      s.flick(outAxis);
      for (var i = at + 8; i < at + 14; i++) {
        s.dyn[i] = v3(0, 0, 7);
      }
      final d = decide(s.quiet(1));
      expect(d.kind, MotionKind.rotationOut);
    });
  });

  group('segmentation', () {
    test('windows start at onset and end after a quiet hold', () {
      final series = ImuSeries.fromPackets(Scene()
          .quiet(1)
          .flick(outAxis)
          .quiet(1)
          .flick(outAxis)
          .quiet(1)
          .packets(deviceStartup: false));
      final w = segmentMotion(series);
      expect(w.length, 2);
      expect(w[0].start, inInclusiveRange(95, 105));
      expect(w[0].touchesStart, isFalse);
      expect(w[0].touchesEnd, isFalse);
    });

    test('a window running to the end of the data says so', () {
      final series = ImuSeries.fromPackets(
          Scene().quiet(1).sine(unit(0, 1, 0), 300, 1, 2).packets(deviceStartup: false));
      final w = segmentMotion(series);
      expect(w.single.touchesEnd, isTrue);
    });

    test('a window already running at the first valid sample says so', () {
      final series = ImuSeries.fromPackets(
          Scene().pulse(outAxis, 140, 0.15).quiet(1).packets());
      expect(segmentMotion(series).first.touchesStart, isTrue);
    });
  });
}
