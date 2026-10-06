// "Gyro ready": when the live IMU stream is actually carrying motion data.
//
// Asking for the stream is not the same as having it. On the owner's 42 MG
// recordings the first packet arrives 1.3-2.6 s after the opening double tap,
// and the first four gyro samples of every stream read -2000 dps on all three
// axes at once: raw -32768, the band's invalid marker, not motion. A wearer who
// starts moving at the tap moves into a dead zone. The detector turns ready on
// the first packet that holds a valid gyro sample together with accel, so a
// caller can tell the wearer (a haptic) that moving now will be seen.
//
// It reports when it turned ready (the packet's monotonic receipt), how many
// gyro samples it skipped as invalid, and, if the stream never becomes valid,
// a legible reason. It is reset per connection generation: a new link is a new
// stream with its own invalid start.
//
// Pure Dart, isolate-safe: time comes from the packets and from [poll], never
// from a clock, and the caller owns any timer.
import '../state/imu_packet.dart';

/// Gyro at or past this on every axis at once is the invalid marker (raw
/// -32768 is -2000 dps); one axis at the rail alone is a clipped real sample.
const double kGyroInvalidRailDps = 1999.9;

/// Whether [g] is a real gyro reading: finite, and not the invalid marker.
bool isValidGyroSample(ImuVector g) {
  if (!g.x.isFinite || !g.y.isFinite || !g.z.isFinite) return false;
  return !(g.x <= -kGyroInvalidRailDps &&
      g.y <= -kGyroInvalidRailDps &&
      g.z <= -kGyroInvalidRailDps);
}

enum ImuReadyState {
  /// Not begun: packets are ignored.
  idle,

  /// Begun, no usable packet yet.
  waiting,

  /// A packet with a valid gyro sample and accel arrived.
  ready,

  /// The deadline passed first.
  timedOut,
}

class ImuReadiness {
  ImuReadiness({this.timeout = const Duration(seconds: 10)});

  /// How long after [begin] the stream may take to become usable.
  final Duration timeout;

  ImuReadyState _state = ImuReadyState.idle;
  Duration _startedAt = Duration.zero;
  Duration? _readyAt;
  int _skipped = 0;
  int? _generation;
  bool _sawPacket = false, _sawGyro = false, _sawValidGyro = false;

  ImuReadyState get state => _state;
  bool get isReady => _state == ImuReadyState.ready;

  /// When the wait times out: [begin]'s time plus [timeout].
  Duration get deadline => _startedAt + timeout;

  /// Monotonic receipt of the packet that made it ready; null until then.
  Duration? get readyAt => _readyAt;

  /// Gyro samples seen as invalid (the marker or NaN) on this connection
  /// generation before it turned ready, the ready packet's own included.
  int get skippedSamples => _skipped;

  /// The connection generation being judged; null before a packet.
  int? get generation => _generation;

  /// Why it is not ready, in a sentence a wearer can read. Null when ready or
  /// not begun. While waiting it describes progress; once timed out, the cause.
  String? get reason {
    switch (_state) {
      case ImuReadyState.idle:
      case ImuReadyState.ready:
        return null;
      case ImuReadyState.waiting:
        return _skipped > 0
            ? 'Waiting for valid gyro data ($_skipped invalid samples skipped).'
            : 'Waiting for motion data.';
      case ImuReadyState.timedOut:
        final secs = timeout.inSeconds;
        if (!_sawPacket) {
          return 'No motion data arrived within $secs s of asking for it.';
        }
        if (!_sawGyro) {
          return 'The band sent motion data with no gyro samples.';
        }
        if (!_sawValidGyro) {
          return 'The band\'s gyro never gave a valid reading '
              '($_skipped invalid samples skipped).';
        }
        return 'The band sent gyro data with no acceleration samples.';
    }
  }

  /// Start waiting at [now] (the caller's monotonic clock). Forgets everything.
  void begin(Duration now) {
    _clear();
    _state = ImuReadyState.waiting;
    _startedAt = now;
  }

  /// Back to idle, forgetting everything.
  void reset() {
    _clear();
    _state = ImuReadyState.idle;
  }

  /// Judge [p]. Returns true exactly when this packet turned the stream ready.
  /// A packet that arrives after the deadline times it out instead.
  bool packet(ImuPacket p) {
    if (_state == ImuReadyState.idle || _state == ImuReadyState.timedOut) {
      return false;
    }
    poll(p.monotonicReceipt);
    if (_state == ImuReadyState.timedOut) return false;
    if (_generation != null && p.connectionGeneration != _generation) {
      // A new link is a new stream, with its own invalid start: judge it afresh.
      _state = ImuReadyState.waiting;
      _readyAt = null;
      _skipped = 0;
      _sawPacket = _sawGyro = _sawValidGyro = false;
    }
    _generation = p.connectionGeneration;
    if (_state == ImuReadyState.ready) return false;
    _sawPacket = true;
    if (p.gyroSamples.isNotEmpty) _sawGyro = true;
    var valid = false;
    for (final g in p.gyroSamples) {
      if (isValidGyroSample(g)) {
        valid = true;
        break;
      }
      _skipped++;
    }
    if (valid) _sawValidGyro = true;
    if (!valid || p.accelSamples.isEmpty) return false;
    _state = ImuReadyState.ready;
    _readyAt = p.monotonicReceipt;
    return true;
  }

  /// Time the wait out at [now]. Returns true when this call did.
  bool poll(Duration now) {
    if (_state != ImuReadyState.waiting || now - _startedAt < timeout) {
      return false;
    }
    _state = ImuReadyState.timedOut;
    return true;
  }

  void _clear() {
    _readyAt = null;
    _skipped = 0;
    _generation = null;
    _sawPacket = _sawGyro = _sawValidGyro = false;
  }
}
