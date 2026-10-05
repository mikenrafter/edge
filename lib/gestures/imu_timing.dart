// Startup timing for a future IMU gesture session. This keeps elapsed times in
// RAM and deliberately makes no decision about a gesture.
import '../state/imu_packet.dart';

class ImuStartupLatency {
  const ImuStartupLatency({
    this.bandEventAge,
    this.tapToImuOn,
    this.imuOnToFirstPacket,
    this.firstPacketToUsableSamples,
    this.tapToAction,
  });

  final Duration? bandEventAge;
  final Duration? tapToImuOn;
  final Duration? imuOnToFirstPacket;
  final Duration? firstPacketToUsableSamples;
  final Duration? tapToAction;

  List<String> toLabLines() => [
        if (bandEventAge != null)
          'IMU timing: tap event age ${_ms(bandEventAge!)}.',
        if (tapToImuOn != null)
          'IMU timing: tap receipt to IMU ON ${_ms(tapToImuOn!)}.',
        if (imuOnToFirstPacket != null)
          'IMU timing: IMU ON to first valid packet '
              '${_ms(imuOnToFirstPacket!)}.',
        if (firstPacketToUsableSamples != null)
          'IMU timing: first packet to usable samples '
              '${_ms(firstPacketToUsableSamples!)}.',
        if (tapToAction != null)
          'IMU timing: tap receipt to action ${_ms(tapToAction!)}.',
      ];

  static String _ms(Duration value) => '${value.inMilliseconds} ms';
}

/// Records one candidate gesture startup. Callers provide monotonic times so a
/// wall-clock adjustment cannot change a latency measurement.
class ImuTimingRecorder {
  ImuTimingRecorder({
    this.usableSampleTarget = 1,
    this.onLine,
  }) : assert(usableSampleTarget > 0);

  final int usableSampleTarget;
  final void Function(String line)? onLine;

  Duration? _tapAt;
  Duration? _imuOnAt;
  Duration? _firstPacketAt;
  Duration? _usableAt;
  Duration? _actionAt;
  Duration? _bandEventAge;
  int _usableSamples = 0;
  int? _generation;
  final Set<String> _reportedLines = {};

  ImuStartupLatency get latency => ImuStartupLatency(
        bandEventAge: _bandEventAge,
        tapToImuOn: _between(_tapAt, _imuOnAt),
        imuOnToFirstPacket: _between(_imuOnAt, _firstPacketAt),
        firstPacketToUsableSamples: _between(_firstPacketAt, _usableAt),
        tapToAction: _between(_tapAt, _actionAt),
      );

  /// [bandEventAge] is null when the band's clock does not say how old the tap
  /// was; no event-age line is then reported.
  void begin({required Duration receivedAt, Duration? bandEventAge}) {
    _tapAt = receivedAt;
    _bandEventAge = bandEventAge;
    _imuOnAt = _firstPacketAt = _usableAt = _actionAt = null;
    _usableSamples = 0;
    _generation = null;
    _reportedLines.clear();
    _report();
  }

  void imuOnWriteIssued(Duration at) {
    if (_tapAt == null || _imuOnAt != null) return;
    _imuOnAt = at;
    _report();
  }

  void packet(ImuPacket packet) {
    if (_tapAt == null || !packet.hasSixAxis) return;
    if (_generation != null && packet.connectionGeneration != _generation) return;
    _generation ??= packet.connectionGeneration;
    _firstPacketAt ??= packet.monotonicReceipt;
    if (_usableAt == null && !packet.quality.gapFromPrevious) {
      _usableSamples += packet.alignedSampleCount;
      if (_usableSamples >= usableSampleTarget) {
        _usableAt = packet.monotonicReceipt;
      }
    }
    _report();
  }

  void actionRan(Duration at) {
    if (_tapAt == null || _actionAt != null) return;
    _actionAt = at;
    _report();
  }

  void reset() {
    _tapAt = _imuOnAt = _firstPacketAt = _usableAt = _actionAt = null;
    _bandEventAge = null;
    _usableSamples = 0;
    _generation = null;
    _reportedLines.clear();
  }

  static Duration? _between(Duration? earlier, Duration? later) =>
      earlier == null || later == null ? null : later - earlier;

  void _report() {
    for (final line in latency.toLabLines()) {
      if (_reportedLines.add(line)) onLine?.call(line);
    }
  }
}
