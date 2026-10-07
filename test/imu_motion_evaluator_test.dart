import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_recording.dart';
import 'package:openstrap_edge/gestures/motion/gravity.dart';
import 'package:openstrap_edge/gestures/motion/gyro_bias.dart';
import 'package:openstrap_edge/gestures/motion/imu_series.dart';
import 'package:openstrap_edge/gestures/motion/motion_recognizer.dart';
import 'package:openstrap_edge/gestures/motion/recording_evaluator.dart';
import 'package:openstrap_edge/gestures/motion/twist_calibration.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

import 'support/imu_recording_fixtures.dart';
import 'support/motion_synth.dart';

ImuRecording rec(String label, Scene scene,
        {ImuRecordingKind kind = ImuRecordingKind.action}) =>
    ImuRecording(
      meta: labMeta(label: label, kind: kind),
      status: ImuRecordingStatus.completed,
      packets: scene.packets(),
      markers: const [],
    );

void main() {
  group('truth from the owner\'s labels', () {
    String t(String label, [ImuRecordingKind k = ImuRecordingKind.action]) =>
        defaultTruthOf(ImuRecording(
            meta: labMeta(label: label, kind: k),
            status: ImuRecordingStatus.completed,
            packets: const [],
            markers: const []));

    test('intended actions', () {
      expect(t('wrist rotate out 3x'), 'rotateOut');
      expect(t('wrist rotate in 2x'), 'rotateIn');
      expect(t('clap 2x'), 'clap2');
      expect(t('shrug 3x'), 'shrug3');
      expect(t('circle in->out->in CW'), 'circleCw');
      expect(t('circle in->out->in CCW'), 'circleCcw');
    });

    test('accidental activations, whatever the file says it is', () {
      expect(t('jogging'), 'accidental');
      expect(t('shaking something vertically'), 'accidental');
      expect(t('hammering'), 'accidental');
      expect(t('anything', ImuRecordingKind.unintendedTap), 'accidental');
    });
  });

  group('confusion table', () {
    final recs = [
      rec('wrist rotate out 3x', Scene().quiet(1.5).flick(outAxis).quiet(1)),
      rec('wrist rotate out 3x', Scene().quiet(1.5).flick(inAxis).quiet(1)),
      rec('shrug 1x', Scene().quiet(1.5).pulse(unit(0, 1, 0), 30, 0.4).quiet(1)),
      rec('jogging', Scene().sine(unit(0, 1, 0.3), 300, 2, 8),
          kind: ImuRecordingKind.unintendedTap),
      rec('still', Scene().quiet(3), kind: ImuRecordingKind.unintendedTap),
    ];

    test('counts every recording once, unknown and none included', () {
      final e = evaluateRecordings(recs);
      expect(e.cases.length, 5);
      expect(e.table['rotateOut'], {'rotateOut': 1, 'rotateIn': 1});
      expect(e.table['shrug1'], {'none': 1});
      expect(e.table['accidental'], {'unknown': 1, 'none': 1});
    });

    test('summary separates activations, wrong direction and missed', () {
      final e = evaluateRecordings(recs);
      expect(e.falseActivations, 0);
      expect(e.wrong, 1); // the mirrored twist labelled "out"
      expect(e.missed, 1); // the shrug
      expect(e.correct, 3); // out, jogging rejected, still rejected
    });

    test('a false activation is counted', () {
      final e = evaluateRecordings([
        rec('hammering', Scene().quiet(1.5).flick(outAxis).quiet(1),
            kind: ImuRecordingKind.unintendedTap),
      ]);
      expect(e.falseActivations, 1);
    });

    test('the text carries the table', () {
      final text = evaluateRecordings(recs).format();
      expect(text, contains('rotateOut'));
      expect(text, contains('unknown'));
      expect(text, contains('accidental'));
    });
  });

  group('starts at the gyro-ready marker', () {
    // 2 s of sustained turning, then 3 s still. The turning is before the
    // cue: the wearer was not yet told to move.
    final packets = Scene().spin(outAxis, 300, 2).quiet(3).packets();

    ImuRecording recordingWith(List<ImuMarker> markers) => ImuRecording(
          meta: labMeta(label: 'still', kind: ImuRecordingKind.action),
          status: ImuRecordingStatus.completed,
          packets: packets,
          markers: markers,
        );

    test('motion before the marker is not the attempt', () {
      final readyAt = packets[2].monotonicReceipt.inMilliseconds;
      final without = recordingWith(const []);
      final cued = recordingWith([labMarker(ImuMarkerKind.gyroReady, readyAt)]);
      expect(cued.motionPackets.length, packets.length - 2);
      final before = evaluateRecordings([without]).cases.single.decision;
      final after = evaluateRecordings([cued]).cases.single.decision;
      expect(before.kind, isNot(MotionKind.none),
          reason: 'with no marker the whole file is read, motion included');
      expect(after.kind, MotionKind.none);
      expect(after.reason, MotionReason.noMotion);
    });

    test('a marker at the first packet changes nothing', () {
      final first = packets.first.monotonicReceipt.inMilliseconds;
      final a = evaluateRecordings([recordingWith(const [])]).cases.single.decision;
      final b = evaluateRecordings([
        recordingWith([labMarker(ImuMarkerKind.gyroReady, first)])
      ]).cases.single.decision;
      expect([b.kind, b.reason], [a.kind, a.reason]);
    });

    test('an accidental recording is read the same way: no quality exclusion '
        'for starting or ending mid-motion', () {
      final r = ImuRecording(
        meta: labMeta(label: 'jogging', kind: ImuRecordingKind.unintendedTap),
        status: ImuRecordingStatus.completed,
        packets: Scene().sine(unit(0, 1, 0.3), 300, 2, 8).packets(),
        markers: const [],
      );
      final e = evaluateRecordings([r]);
      expect(e.cases, hasLength(1));
      expect(e.cases.single.truth, 'accidental');
    });
  });

  test('slices of a long recording are 5-packet windows, hopping by one', () {
    final packets = Scene().quiet(10).packets();
    final slices = packetSlices(packets, packets: 5, hop: 1);
    expect(slices.length, packets.length - 4);
    expect(slices.first.length, 5);
  });

  fixtureTests();
}

// Real recordings from the owner's WHOOP MG (firmware 50.39.1.0, right wrist,
// logo toward the elbow), copied verbatim except for the band serial.
ImuRecording fixture(String name) =>
    ImuRecording.parse(File('test/fixtures/imu/$name.jsonl').readAsStringSync());

/// The recording as seen by a band mounted differently: every accel and gyro
/// vector multiplied by the rotation [q] (row-major 3x3).
ImuRecording remounted(ImuRecording r, List<List<double>> q) {
  ImuVector m(ImuVector v) => ImuVector(
      q[0][0] * v.x + q[0][1] * v.y + q[0][2] * v.z,
      q[1][0] * v.x + q[1][1] * v.y + q[1][2] * v.z,
      q[2][0] * v.x + q[2][1] * v.y + q[2][2] * v.z);
  // The band's invalid marker is firmware-level, not a measured vector.
  ImuVector g(ImuVector v) =>
      v.x <= -1999.9 && v.y <= -1999.9 && v.z <= -1999.9 ? v : m(v);
  return ImuRecording(
    meta: r.meta,
    status: r.status,
    markers: r.markers,
    packets: [
      for (final p in r.packets)
        ImuPacket(
          deviceId: p.deviceId,
          connectionGeneration: p.connectionGeneration,
          kind: p.kind,
          recordIndex: p.recordIndex,
          deviceUnixSeconds: p.deviceUnixSeconds,
          deviceSubseconds: p.deviceSubseconds,
          receivedAt: p.receivedAt,
          monotonicReceipt: p.monotonicReceipt,
          accelSamples: [for (final v in p.accelSamples) m(v)],
          gyroSamples: [for (final v in p.gyroSamples) g(v)],
          accelSampleCount: p.accelSampleCount,
          gyroSampleCount: p.gyroSampleCount,
          nominalSampleSpacing: p.nominalSampleSpacing,
          quality: p.quality,
        ),
    ],
  );
}

void fixtureTests() {
  group('owner recordings (committed fixtures)', () {
    final names = [
      'rotate_out_lying',
      'rotate_out_arm_raised',
      'clap_3x',
      'shrug_3x',
      'circle_in_out_in_cw',
      'hammering',
    ];
    final recs = [for (final n in names) fixture(n)];

    test('what the band sends: 100 Hz, 1 s packets, 4 invalid gyro samples',
        () {
      for (final r in recs) {
        final s = ImuSeries.fromPackets(r.packets);
        expect(s.dt, closeTo(0.01, 1e-9));
        expect(s.length, greaterThan(490));
        expect([for (var i = 0; i < 5; i++) s.isValid(i)],
            [false, false, false, false, true],
            reason: r.meta.id);
        expect(s.runs.length, 1, reason: r.meta.id);
      }
    });

    test('gravity is 1 g at rest and the gyro rests near zero', () {
      final s = ImuSeries.fromPackets(fixture('circle_in_out_in_cw').packets);
      final track = estimateGravity(s);
      final est = track.directionAt(300)!;
      // Accel at rest measures +1 g along the resting direction.
      expect(s.accelAt(300).magnitude, closeTo(1.0, 0.05));
      expect(est.magnitude, closeTo(1.0, 1e-9));
      final bias = estimateGyroBias(s)!;
      expect(bias.dps.magnitude, lessThan(3));
    });

    test('pinned confusion table', () {
      final e = evaluateRecordings(recs);
      expect(e.table, {
        'rotateOut': {'rotateOut': 2},
        'clap3': {'clap3': 1},
        'shrug3': {'unknown': 1},
        'circleCw': {'unknown': 1},
        'accidental': {'unknown': 1},
      });
      expect(
          (e.correct, e.missed, e.wrong, e.falseActivations), (4, 2, 0, 0));
    });

    test('the sustained recording is rejected as sustained, at every offset',
        () {
      final h = fixture('hammering');
      for (final slice in packetSlices(h.packets, packets: 6, hop: 1)) {
        final d = recognizeMotion(slice);
        expect(d.isGesture, isFalse);
      }
      expect(recognizeMotion(h.packets).reason, MotionReason.sustained);
    });

    test('a twist that begins before the stream does is still read', () {
      // rotate_out_lying starts mid-return: its first lobe is truncated.
      final d = recognizeMotion(fixture('rotate_out_lying').packets);
      expect(d.kind, MotionKind.rotationOut);
      expect(d.reason, MotionReason.ok);
    });

    test('another mounting: calibrate on one take, read the other', () {
      // 180 degrees about Z flips the sign of the twist axis (X); a 90 degree
      // turn about Z moves it to Y.
      final flip = [
        [-1.0, 0.0, 0.0],
        [0.0, -1.0, 0.0],
        [0.0, 0.0, 1.0],
      ];
      final quarter = [
        [0.0, -1.0, 0.0],
        [1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0],
      ];
      for (final q in [flip, quarter]) {
        final cal = TwistCalibration.fromPackets(
            remounted(fixture('rotate_out_lying'), q).packets);
        expect(cal, isNotNull);
        final other = remounted(fixture('rotate_out_arm_raised'), q);
        expect(recognizeMotion(other.packets, calibration: cal).kind,
            MotionKind.rotationOut);
        // Without a calibration the default reads the wrong axis or sign.
        expect(recognizeMotion(other.packets).kind,
            isNot(MotionKind.rotationOut));
        // The claps are claps in any mounting.
        final clap = remounted(fixture('clap_3x'), q);
        expect(recognizeMotion(clap.packets, calibration: cal).label, 'clap3');
      }
    });
  });
}
