// One continuous six-axis series built from live packets, with what the
// processing needs to know about each sample: is it valid, was it pinned at a
// rail, and where does the stream break.
//
// Facts this encodes (from the owner's MG recordings and the phase-1 packet
// adapter):
// - 100 Hz, one 100-sample packet a second; the first packet of a stream is
//   one sample short.
// - The first four gyro samples of every stream read -2000 dps on all three
//   axes at once. That is the band's invalid marker (raw -32768), not motion.
//   Accel is real there.
// - Gyro and accel clip at +-2000 dps and +-8 g.
// - A packet flagged as following a gap, or a short packet after the first,
//   ends the run: samples are never joined across lost time or stretched.
//
// Pure Dart, isolate-safe.
import 'dart:typed_data';

import '../../state/imu_packet.dart';

/// Samples [start, end) with unbroken time.
class MotionRun {
  const MotionRun(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start;
}

class ImuSeries {
  ImuSeries._({
    required this.dt,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.flags,
    required this.breakBefore,
  }) : runs = _runsOf(flags, breakBefore);

  static const int _invalid = 1, _gyroClip = 2, _accelClip = 4;

  /// Raw -32768 at 2000/32768 dps per count.
  static const double _rail = 1999.9;
  static const double _accelRail = 7.99;

  final double dt;
  final Float64List ax, ay, az, gx, gy, gz;
  final Uint8List flags;
  final Uint8List breakBefore;

  /// Runs of valid samples with no break inside.
  final List<MotionRun> runs;

  int get length => ax.length;

  bool isValid(int i) => flags[i] & _invalid == 0;
  bool gyroClipped(int i) => flags[i] & _gyroClip != 0;
  bool accelClipped(int i) => flags[i] & _accelClip != 0;

  ImuVector accelAt(int i) => ImuVector(ax[i], ay[i], az[i]);
  ImuVector gyroAt(int i) => ImuVector(gx[i], gy[i], gz[i]);
  double speedAt(int i) => gyroAt(i).magnitude;

  int get validCount {
    var n = 0;
    for (var i = 0; i < length; i++) {
      if (isValid(i)) n++;
    }
    return n;
  }

  /// The same series with a constant subtracted from every gyro sample.
  ImuSeries withGyroBias(ImuVector b) {
    final nx = Float64List(length), ny = Float64List(length), nz = Float64List(length);
    for (var i = 0; i < length; i++) {
      nx[i] = gx[i] - b.x;
      ny[i] = gy[i] - b.y;
      nz[i] = gz[i] - b.z;
    }
    return ImuSeries._(
        dt: dt, ax: ax, ay: ay, az: az, gx: nx, gy: ny, gz: nz,
        flags: flags, breakBefore: breakBefore);
  }

  /// Packets in arrival order. A sample is taken from a packet's aligned
  /// prefix (the smaller of its accel and gyro counts).
  factory ImuSeries.fromPackets(Iterable<ImuPacket> packets) {
    final ax = <double>[], ay = <double>[], az = <double>[];
    final gx = <double>[], gy = <double>[], gz = <double>[];
    final flags = <int>[], brk = <int>[];
    var dt = 0.01;
    var first = true;
    var breakNext = false;
    for (final p in packets) {
      final n = [
        p.alignedSampleCount,
        p.accelSamples.length,
        p.gyroSamples.length,
      ].reduce((a, b) => a < b ? a : b);
      if (p.nominalSampleSpacing > Duration.zero) {
        dt = p.nominalSampleSpacing.inMicroseconds / 1e6;
      }
      for (var i = 0; i < n; i++) {
        final a = p.accelSamples[i], g = p.gyroSamples[i];
        final marker = g.x <= -_rail && g.y <= -_rail && g.z <= -_rail;
        var f = marker ? _invalid : 0;
        if (!marker &&
            (g.x.abs() >= _rail || g.y.abs() >= _rail || g.z.abs() >= _rail)) {
          f |= _gyroClip;
        }
        if (a.x.abs() >= _accelRail ||
            a.y.abs() >= _accelRail ||
            a.z.abs() >= _accelRail) {
          f |= _accelClip;
        }
        ax.add(a.x);
        ay.add(a.y);
        az.add(a.z);
        gx.add(g.x);
        gy.add(g.y);
        gz.add(g.z);
        flags.add(f);
        brk.add(i == 0 && (breakNext || (!first && p.quality.gapFromPrevious))
            ? 1
            : 0);
      }
      // Lost samples inside a short packet are unlocated: end the run. The
      // first packet of a stream is expected to be short.
      breakNext = !first && n < 100;
      if (n > 0) first = false;
    }
    return ImuSeries._(
      dt: dt,
      ax: Float64List.fromList(ax),
      ay: Float64List.fromList(ay),
      az: Float64List.fromList(az),
      gx: Float64List.fromList(gx),
      gy: Float64List.fromList(gy),
      gz: Float64List.fromList(gz),
      flags: Uint8List.fromList(flags),
      breakBefore: Uint8List.fromList(brk),
    );
  }

  static List<MotionRun> _runsOf(Uint8List flags, Uint8List brk) {
    final out = <MotionRun>[];
    int? start;
    for (var i = 0; i < flags.length; i++) {
      final ok = flags[i] & _invalid == 0;
      if (start != null && (!ok || brk[i] == 1)) {
        out.add(MotionRun(start, i));
        start = null;
      }
      if (ok && start == null) start = i;
    }
    if (start != null) out.add(MotionRun(start, flags.length));
    return out;
  }
}
