// Synthetic six-axis IMU streams for the motion-processing tests.
//
// A scene is a list of body-frame angular velocities (deg/s, 100 Hz) plus
// optional dynamic acceleration. The gravity direction in the sensor frame is
// transported through the scene with the same convention the real band follows
// (dv/dt = -w x v; checked on the owner's recordings), so accel and gyro stay
// consistent in any mounting orientation.
import 'dart:math' as math;

import 'package:openstrap_edge/state/imu_packet.dart';

ImuVector v3(double x, double y, double z) => ImuVector(x, y, z);

ImuVector unit(double x, double y, double z) {
  final n = math.sqrt(x * x + y * y + z * z);
  return ImuVector(x / n, y / n, z / n);
}

ImuVector _cross(ImuVector a, ImuVector b) => ImuVector(a.y * b.z - a.z * b.y,
    a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);

/// Twist "out" for the default MG right-wrist calibration is a negative turn
/// about the sensor X axis.
final ImuVector outAxis = v3(-1, 0, 0);
final ImuVector inAxis = v3(1, 0, 0);

class Scene {
  Scene({this.dt = 0.01});

  final double dt;
  final List<ImuVector> omega = [];
  final List<ImuVector> dyn = [];

  int get length => omega.length;

  Scene quiet(double seconds) {
    for (var i = 0; i < (seconds / dt).round(); i++) {
      _add(v3(0, 0, 0));
    }
    return this;
  }

  /// A half-sine turn of [angleDeg] about [axis] lasting [seconds].
  Scene pulse(ImuVector axis, double angleDeg, double seconds) {
    final n = (seconds / dt).round();
    // Sum of A*sin(pi*(i+.5)/n)*dt over n samples ~ A*2*seconds/pi.
    final amp = angleDeg * math.pi / (2 * seconds);
    for (var i = 0; i < n; i++) {
      final w = amp * math.sin(math.pi * (i + 0.5) / n);
      _add(v3(axis.x * w, axis.y * w, axis.z * w));
    }
    return this;
  }

  /// The owner's twist: a fast turn one way, an immediate return.
  Scene flick(ImuVector axis,
      {double angleDeg = 140, double seconds = 0.12, double backSeconds = 0.17}) {
    pulse(axis, angleDeg, seconds);
    return pulse(v3(-axis.x, -axis.y, -axis.z), angleDeg, backSeconds);
  }

  Scene sine(ImuVector axis, double ampDps, double hz, double seconds) {
    final n = (seconds / dt).round();
    for (var i = 0; i < n; i++) {
      final w = ampDps * math.sin(2 * math.pi * hz * i * dt);
      _add(v3(axis.x * w, axis.y * w, axis.z * w));
    }
    return this;
  }

  /// A one-sample acceleration spike (g, sensor frame) with no rotation.
  Scene impulse(ImuVector g) {
    _add(v3(0, 0, 0), dyn: g);
    return this;
  }

  /// Constant rotation [dps] about [axis] for [seconds].
  Scene spin(ImuVector axis, double dps, double seconds) {
    for (var i = 0; i < (seconds / dt).round(); i++) {
      _add(v3(axis.x * dps, axis.y * dps, axis.z * dps));
    }
    return this;
  }

  /// Random wobble of +-[dps] on every axis, a vibration stand-in.
  Scene vibration(double dps, double seconds, {int seed = 7}) {
    final r = math.Random(seed);
    for (var i = 0; i < (seconds / dt).round(); i++) {
      _add(v3((r.nextDouble() * 2 - 1) * dps, (r.nextDouble() * 2 - 1) * dps,
          (r.nextDouble() * 2 - 1) * dps));
    }
    return this;
  }

  void _add(ImuVector w, {ImuVector? dyn}) {
    omega.add(w);
    this.dyn.add(dyn ?? v3(0, 0, 0));
  }

  /// Samples as the sensor reports them: gravity transported by the true
  /// rotation, plus dynamic acceleration, bias and noise on the gyro.
  (List<ImuVector>, List<ImuVector>) samples({
    ImuVector gravity = const ImuVector(0, 0, 1),
    ImuVector bias = const ImuVector(0, 0, 0),
    double noiseDps = 0.6,
    double noiseG = 0.005,
    double clipDps = 2000,
    int seed = 3,
  }) {
    final r = math.Random(seed);
    double n(double a) => (r.nextDouble() * 2 - 1) * a;
    var g = gravity;
    final accel = <ImuVector>[], gyro = <ImuVector>[];
    for (var i = 0; i < length; i++) {
      final w = omega[i];
      final d = dyn[i];
      accel.add(v3(
        (g.x + d.x + n(noiseG)).clamp(-7.99976, 7.99976),
        (g.y + d.y + n(noiseG)).clamp(-7.99976, 7.99976),
        (g.z + d.z + n(noiseG)).clamp(-7.99976, 7.99976),
      ));
      gyro.add(v3(
        (w.x + bias.x + n(noiseDps)).clamp(-clipDps, clipDps - 0.06),
        (w.y + bias.y + n(noiseDps)).clamp(-clipDps, clipDps - 0.06),
        (w.z + bias.z + n(noiseDps)).clamp(-clipDps, clipDps - 0.06),
      ));
      g = _transport(g, w);
    }
    return (accel, gyro);
  }

  ImuVector _transport(ImuVector g, ImuVector wDps) {
    final w = v3(wDps.x * math.pi / 180, wDps.y * math.pi / 180,
        wDps.z * math.pi / 180);
    final angle = w.magnitude * dt;
    if (angle < 1e-12) return g;
    // Rodrigues rotation of g by -angle about w.
    final k = v3(w.x / w.magnitude, w.y / w.magnitude, w.z / w.magnitude);
    final c = math.cos(-angle), s = math.sin(-angle);
    final kxg = _cross(k, g);
    final kdg = k.x * g.x + k.y * g.y + k.z * g.z;
    return v3(g.x * c + kxg.x * s + k.x * kdg * (1 - c),
        g.y * c + kxg.y * s + k.y * kdg * (1 - c),
        g.z * c + kxg.z * s + k.z * kdg * (1 - c));
  }

  /// Packets of 100 samples a second as the MG sends them. With
  /// [deviceStartup] the first packet is one sample short and its first four
  /// gyro samples hold the band's -2000 dps invalid marker, as every owner
  /// recording does. [gapBefore] lists packet indexes flagged as following a
  /// gap; [shortPackets] maps a packet index to how many samples it carries.
  List<ImuPacket> packets({
    ImuVector gravity = const ImuVector(0, 0, 1),
    ImuVector bias = const ImuVector(0, 0, 0),
    double noiseDps = 0.6,
    double clipDps = 2000,
    bool deviceStartup = true,
    Set<int> gapBefore = const {},
    Map<int, int> shortPackets = const {},
    Set<int> sentinelAt = const {},
  }) {
    final (accel, gyro) = samples(
        gravity: gravity, bias: bias, noiseDps: noiseDps, clipDps: clipDps);
    var a = deviceStartup ? accel.sublist(1) : accel;
    var gy = deviceStartup ? gyro.sublist(1) : gyro;
    if (deviceStartup) {
      gy = [
        for (var i = 0; i < gy.length; i++)
          i < 4 ? v3(-2000, -2000, -2000) : gy[i],
      ];
    }
    if (sentinelAt.isNotEmpty) {
      gy = [
        for (var i = 0; i < gy.length; i++)
          sentinelAt.contains(i) ? v3(-2000, -2000, -2000) : gy[i],
      ];
    }
    final out = <ImuPacket>[];
    var at = 0, index = 0;
    while (at < a.length) {
      final want = index == 0 && deviceStartup
          ? 99
          : (shortPackets[index] ?? 100);
      final end = math.min(a.length, at + want);
      final pa = a.sublist(at, end), pg = gy.sublist(at, end);
      out.add(ImuPacket(
        deviceId: 'sim',
        connectionGeneration: 0,
        kind: ImuPacketKind.gen5R21,
        recordIndex: 9000 + index,
        deviceUnixSeconds: 1790000000 + index,
        deviceSubseconds: 16000,
        receivedAt: DateTime.utc(2026, 10, 6, 12, 0, index + 1),
        monotonicReceipt: Duration(seconds: index + 1),
        accelSamples: pa,
        gyroSamples: pg,
        accelSampleCount: pa.length,
        gyroSampleCount: pg.length,
        nominalSampleSpacing: const Duration(milliseconds: 10),
        quality: ImuPacketQuality(
          gapFromPrevious: gapBefore.contains(index),
          partialBlock: pa.length != 100,
        ),
      ));
      at = end;
      index++;
    }
    return out;
  }
}
