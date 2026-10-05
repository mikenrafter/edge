// Normalized six-axis live IMU packets. The byte layouts and scales remain in
// the protocol package; this is the one edge-side adapter that fans decoded
// packets out to live consumers.
import 'dart:math' as math;

import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

/// One acceleration or angular-rate sample. Acceleration is in g; gyro is in
/// degrees per second.
class ImuVector {
  const ImuVector(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get magnitude => math.sqrt(x * x + y * y + z * z);
}

enum ImuPacketKind { gen4R10, gen5R21 }

/// Delivery and sample validity facts attached to one decoded block.
class ImuPacketQuality {
  const ImuPacketQuality({
    this.gapFromPrevious = false,
    this.accelClipped = false,
    this.gyroClipped = false,
    this.partialBlock = false,
  });

  final bool gapFromPrevious;
  final bool accelClipped;
  final bool gyroClipped;
  final bool partialBlock;

  bool get clipped => accelClipped || gyroClipped;
}

/// A decoded full six-axis packet from the live 0x2B stream.
///
/// Accel and gyro arrays intentionally stay separate. A gen5 packet can carry
/// different valid counts for the two sensors, so callers must not zip them
/// without choosing an explicit aligned prefix.
class ImuPacket {
  const ImuPacket({
    required this.deviceId,
    required this.connectionGeneration,
    required this.kind,
    required this.recordIndex,
    required this.deviceUnixSeconds,
    required this.deviceSubseconds,
    required this.receivedAt,
    required this.monotonicReceipt,
    required this.accelSamples,
    required this.gyroSamples,
    required this.accelSampleCount,
    required this.gyroSampleCount,
    required this.nominalSampleSpacing,
    required this.quality,
  });

  final String deviceId;
  final int connectionGeneration;
  final ImuPacketKind kind;
  final int? recordIndex;
  final int? deviceUnixSeconds;
  final int? deviceSubseconds;
  final DateTime receivedAt;
  final Duration monotonicReceipt;
  final List<ImuVector> accelSamples;
  final List<ImuVector> gyroSamples;
  final int accelSampleCount;
  final int gyroSampleCount;
  final Duration nominalSampleSpacing;
  final ImuPacketQuality quality;

  bool get hasSixAxis => accelSampleCount > 0 && gyroSampleCount > 0;

  /// The largest safely aligned prefix; it is not an instruction to zip it.
  int get alignedSampleCount => math.min(accelSampleCount, gyroSampleCount);

  /// Whether the older accel-only consumers (accel graph, pedometer, posture)
  /// take this packet. They have always skipped a gen4 R10 whose device clock
  /// is unset and always taken a gen5 buffer regardless; this keeps that.
  bool get feedsAccelConsumers =>
      accelSamples.isNotEmpty &&
      (kind == ImuPacketKind.gen5R21 || deviceUnixSeconds != null);

  /// The existing pedometer consumes magnitude in g and axes with a common
  /// sample count. Full six-axis packets always have internally consistent
  /// accel axes, independently of the gyro count. Magnitudes are bit-identical
  /// to protocol's `frameAccelForBand`; the axes are in g where that frame
  /// carries raw counts, a power-of-two difference the roll estimate (the only
  /// reader of the axes) is exactly invariant to.
  proto.ImuFrame toAccelFrame() => proto.ImuFrame(
        deviceUnixSeconds ?? 0,
        0,
        [for (final s in accelSamples) s.magnitude],
        [for (final s in accelSamples) s.x],
        [for (final s in accelSamples) s.y],
        [for (final s in accelSamples) s.z],
      );
}

/// Stopwatch-backed receipt clock. It is process-local and must only be used
/// for elapsed durations, never persisted or compared with wall-clock time.
class ImuReceiptClock {
  ImuReceiptClock() : _watch = Stopwatch()..start();

  final Stopwatch _watch;

  Duration get elapsed => _watch.elapsed;
}

/// The one adapter for full six-axis live packets. It delegates all byte
/// decoding and fixed scales to protocol, then remembers just enough ordering
/// state to mark a discontinuity on this connection generation.
class ImuPacketAdapter {
  ImuPacketAdapter({ImuReceiptClock? receiptClock})
      : _receiptClock = receiptClock ?? ImuReceiptClock();

  final ImuReceiptClock _receiptClock;
  final Map<(String, int), _PacketOrder> _previous = {};

  Duration get monotonicNow => _receiptClock.elapsed;

  /// How many 0x2B frames this adapter was asked to decode. Tests use it to
  /// pin one decode per frame.
  int decodeCalls = 0;

  ImuPacket? decode({
    required int packetType,
    required String hex,
    required String deviceId,
    required int connectionGeneration,
    DateTime? receivedAt,
    Duration? monotonicReceipt,
  }) {
    if (packetType != 0x2B) return null;
    decodeCalls++;
    final wall = receivedAt ?? DateTime.now();
    final monotonic = monotonicReceipt ?? _receiptClock.elapsed;
    try {
      final bytes = proto.hexToBytes(hex);
      final gen5 = proto.parseGen5ImuBuffer(bytes);
      if (gen5 != null) {
        final accel = _vectors(gen5.accelXg, gen5.accelYg, gen5.accelZg);
        final gyro = _vectors(gen5.gyroXdps, gen5.gyroYdps, gen5.gyroZdps);
        return _finish(
          deviceId: deviceId,
          connectionGeneration: connectionGeneration,
          kind: ImuPacketKind.gen5R21,
          recordIndex: gen5.recordIndex,
          unix: gen5.unix,
          subseconds: gen5.tsSubsec,
          receivedAt: wall,
          monotonicReceipt: monotonic,
          accel: accel,
          gyro: gyro,
          accelCount: gen5.countA,
          gyroCount: gen5.countB,
        );
      }

      final r10 = proto.decodeR10Imu(hex);
      if (r10 == null) return null;
      return _finish(
        deviceId: deviceId,
        connectionGeneration: connectionGeneration,
        kind: ImuPacketKind.gen4R10,
        unix: r10.ts,
        receivedAt: wall,
        monotonicReceipt: monotonic,
        accel: _vectors(r10.accelX, r10.accelY, r10.accelZ),
        gyro: _vectors(r10.gyroX, r10.gyroY, r10.gyroZ),
        accelCount: r10.accelX.length,
        gyroCount: r10.gyroX.length,
      );
    } catch (_) {
      // Live frames are optional RAM-only telemetry. A malformed one is absent.
      return null;
    }
  }

  ImuPacket _finish({
    required String deviceId,
    required int connectionGeneration,
    required ImuPacketKind kind,
    int? recordIndex,
    required int unix,
    int? subseconds,
    required DateTime receivedAt,
    required Duration monotonicReceipt,
    required List<ImuVector> accel,
    required List<ImuVector> gyro,
    required int accelCount,
    required int gyroCount,
  }) {
    final key = (deviceId, connectionGeneration);
    _previous.removeWhere((prior, _) =>
        prior.$1 == deviceId && prior.$2 != connectionGeneration);
    final previous = _previous[key];
    final gap = previous != null && _hasGap(
      previous,
      kind: kind,
      recordIndex: recordIndex,
      unix: unix,
    );
    _previous[key] = _PacketOrder(kind, recordIndex, unix);
    return ImuPacket(
      deviceId: deviceId,
      connectionGeneration: connectionGeneration,
      kind: kind,
      recordIndex: recordIndex,
      deviceUnixSeconds: unix > 0 ? unix : null,
      deviceSubseconds: subseconds,
      receivedAt: receivedAt,
      monotonicReceipt: monotonicReceipt,
      accelSamples: List.unmodifiable(accel),
      gyroSamples: List.unmodifiable(gyro),
      accelSampleCount: accelCount,
      gyroSampleCount: gyroCount,
      nominalSampleSpacing: const Duration(milliseconds: 10),
      quality: ImuPacketQuality(
        gapFromPrevious: gap,
        accelClipped: _clipped(accel, 32767 * proto.kGen5AccelScaleG),
        gyroClipped: _clipped(gyro, 32767 * proto.kGen5GyroScaleDps),
        partialBlock: accelCount != 100 || gyroCount != 100,
      ),
    );
  }

  static List<ImuVector> _vectors(
      List<double> x, List<double> y, List<double> z) {
    final count = math.min(x.length, math.min(y.length, z.length));
    return List<ImuVector>.generate(count, (i) => ImuVector(x[i], y[i], z[i]));
  }

  static bool _clipped(List<ImuVector> samples, double limit) => samples.any(
      (s) => s.x.abs() >= limit || s.y.abs() >= limit || s.z.abs() >= limit);

  static bool _hasGap(
    _PacketOrder previous, {
    required ImuPacketKind kind,
    required int? recordIndex,
    required int unix,
  }) {
    if (previous.kind != kind) return true;
    if (recordIndex != null && previous.recordIndex != null) {
      return recordIndex > previous.recordIndex! + 1;
    }
    return unix > 0 && previous.unix > 0 && unix > previous.unix + 1;
  }
}

class _PacketOrder {
  const _PacketOrder(this.kind, this.recordIndex, this.unix);

  final ImuPacketKind kind;
  final int? recordIndex;
  final int unix;
}
