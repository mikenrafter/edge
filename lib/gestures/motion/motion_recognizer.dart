// Threshold-first recognizer for the motion that follows the opening double
// tap: a signed wrist twist (out / in) and claps (counted). Everything else is
// "none" (nothing moved) or "unknown" (something moved and it is not a clear
// instance of a supported gesture, or the data cannot say). A caller that must
// not fire on a doubt treats both as no gesture; unknown additionally means a
// gesture failure is worth recording.
//
//   packets -> ImuSeries (invalid samples, gaps, rails)
//           -> gyro bias removed when a still interval measured it
//           -> motion windows (hysteresis), a start remnant skipped
//           -> the first attempt = windows within mergeGapSec of each other
//           -> too long: sustained; still open at the data's end: incomplete
//           -> twist lobes along the calibrated axis, or clap impulses
//
// Circle and shrug are not recognized: on the recordings available their
// angular-rate and accel features overlap each other and slow clap wind-ups,
// and circle direction held for only two of the four plane variants. See the
// phase-3 report.
//
// Pure Dart, isolate-safe.
import 'dart:math' as math;

import '../../state/imu_packet.dart';
import 'clap_impulses.dart';
import 'gravity.dart';
import 'gyro_bias.dart';
import 'imu_series.dart';
import 'motion_config.dart';
import 'motion_segments.dart';
import 'movement_energy.dart';
import 'twist_calibration.dart';
import 'twist_lobes.dart';

enum MotionKind { none, unknown, rotationOut, rotationIn, clap }

enum MotionReason {
  ok,
  noMotion,
  insufficientData,
  sustained,
  incomplete,
  offAxis,
  truncated,
  ambiguous,
  noPattern,
}

class MotionDecision {
  const MotionDecision(
    this.kind,
    this.reason, {
    this.clapCount,
    this.strongLobes = 0,
    this.twistConcentration,
    this.energy,
    this.attemptStart,
    this.attemptEnd,
    this.gyroBiasDps,
  });

  final MotionKind kind;
  final MotionReason reason;
  final int? clapCount;
  final int strongLobes;
  final double? twistConcentration;

  /// Movement energy over the whole observation (not just the attempt).
  final MovementEnergy? energy;

  /// Sample indexes of the first attempt, when there was one.
  final int? attemptStart;
  final int? attemptEnd;

  /// Measured gyro bias that was removed, when a still interval measured it.
  final ImuVector? gyroBiasDps;

  bool get isGesture =>
      kind == MotionKind.rotationOut ||
      kind == MotionKind.rotationIn ||
      kind == MotionKind.clap;

  /// `none`, `unknown`, `rotateOut`, `rotateIn`, `clap1`, `clap2`, ...
  String get label => switch (kind) {
        MotionKind.none => 'none',
        MotionKind.unknown => 'unknown',
        MotionKind.rotationOut => 'rotateOut',
        MotionKind.rotationIn => 'rotateIn',
        MotionKind.clap => 'clap$clapCount',
      };
}

MotionDecision recognizeMotion(
  Iterable<ImuPacket> packets, {
  MotionConfig config = const MotionConfig(),
  TwistCalibration? calibration,
}) {
  calibration ??= TwistCalibration.mgRightWrist;
  var s = ImuSeries.fromPackets(packets);
  final longest = s.runs.fold<int>(0, (m, r) => r.length > m ? r.length : m);
  if (s.length == 0 ||
      longest * s.dt < config.minRunSec ||
      s.validCount < s.length * config.minValidFraction) {
    return const MotionDecision(MotionKind.unknown, MotionReason.insufficientData);
  }
  final bias = estimateGyroBias(s, config: config);
  if (bias != null) s = s.withGyroBias(bias.dps);
  final energy = measureMovementEnergy(s,
      from: 0,
      to: s.length,
      gravity: estimateGravity(s, config: config),
      config: config);
  MotionDecision done(MotionKind k, MotionReason r,
          {int? clapCount,
          int lobes = 0,
          double? concentration,
          MotionWindow? first,
          MotionWindow? last}) =>
      MotionDecision(k, r,
          clapCount: clapCount,
          strongLobes: lobes,
          twistConcentration: concentration,
          energy: energy,
          attemptStart: first?.start,
          attemptEnd: last?.end,
          gyroBiasDps: bias?.dps);

  var windows = segmentMotion(s, config: config);
  // A short window open at the first sample is the tail of motion that began
  // before the stream: not the gesture.
  final remnantMax = (config.maxRemnantSec / s.dt).round();
  if (windows.isNotEmpty &&
      windows.first.touchesStart &&
      windows.first.run.start == s.runs.first.start &&
      windows.first.length <= remnantMax &&
      !windows.first.touchesEnd) {
    windows = windows.sublist(1);
  }
  if (windows.isEmpty) return done(MotionKind.none, MotionReason.noMotion);

  final group = groupWindows(windows, s, config: config).first;
  final first = group.first, last = group.last;
  if ((last.end - first.start) * s.dt > config.maxGroupSec) {
    return done(MotionKind.unknown, MotionReason.sustained, first: first, last: last);
  }
  if (last.touchesEnd) {
    return done(MotionKind.unknown, MotionReason.incomplete, first: first, last: last);
  }

  // Twist lobes and concentration over the attempt.
  final axis = calibration.axis;
  final lobes = <Lobe>[];
  var along = 0.0, total = 0.0;
  for (final w in group) {
    lobes.addAll(findLobes(s, axis, w.run,
        from: w.start, to: w.end, edgeDps: config.lobeEdgeDps));
    for (var i = w.start; i < w.end; i++) {
      final g = s.gyroAt(i);
      final sp = g.magnitude;
      if (sp < config.concentrationFloorDps) continue;
      final v = g.x * axis.x + g.y * axis.y + g.z * axis.z;
      along += v * v;
      total += sp * sp;
    }
  }
  final concentration = total == 0 ? 0.0 : along / total;
  final strong = lobes
      .where((l) =>
          l.angleDeg.abs() >= config.strongAngleDeg &&
          l.peakDps.abs() >= config.strongPeakDps)
      .toList();
  // A clap's spike can land just after the swing's speed drops below the
  // window's offset, so look through the closing quiet hold as well.
  final impulses = findClapImpulses(s,
      from: first.start,
      to: math.min(last.run.end, last.end + (config.quietHoldSec / s.dt).round()),
      config: config);

  MotionDecision unknown(MotionReason r) => done(MotionKind.unknown, r,
      lobes: strong.length, concentration: concentration, first: first, last: last);

  if (strong.isNotEmpty) {
    if (strong.length > config.maxStrongLobes) return unknown(MotionReason.sustained);
    if (concentration < config.minTwistConcentration) {
      return unknown(MotionReason.offAxis);
    }
    if (impulses.isNotEmpty) return unknown(MotionReason.ambiguous);
    final usable = strong.where((l) => !l.truncated).toList();
    if (usable.length < config.minStrongLobes) {
      return unknown(strong.any((l) => l.truncated)
          ? MotionReason.truncated
          : MotionReason.noPattern);
    }
    return done(
      usable.first.sign > 0 ? MotionKind.rotationOut : MotionKind.rotationIn,
      MotionReason.ok,
      lobes: strong.length,
      concentration: concentration,
      first: first,
      last: last,
    );
  }

  if (impulses.isNotEmpty) {
    if (impulses.any((c) => !c.hasApproach)) return unknown(MotionReason.noPattern);
    if (impulses.length > config.maxClaps) return unknown(MotionReason.sustained);
    return done(MotionKind.clap, MotionReason.ok,
        clapCount: impulses.length,
        concentration: concentration,
        first: first,
        last: last);
  }
  return unknown(MotionReason.noPattern);
}
