// ecg_stream_readiness.dart — "is the ECG stream really up?" for the tap
// counter, and "where is now on the ECG sample clock?". Starting the stream only
// means a command was written; the band can take many seconds to begin sending,
// and a touch window opened before that asks the wearer to touch a sensor that
// is not listening yet.
//
// PACKET TIME. An R17 packet's strap time is when its NEWEST sample was taken:
// its samples run back from there, 10 ms apart. (Read as the first sample, every
// packet in the 2026-10-02 lab log reached the phone ~0.8 s before its last
// sample existed, on a strap clock that matched the phone's to ~20 ms, and the
// short 49-sample packet at stream start looked like a 510 ms hole.)
//
// READINESS (review finding F). Receipt time alone proves nothing: BLE can hold
// packets back and deliver a stale burst, and a burst looks exactly like a
// stream if the only test is "a second packet arrived soon after the first".
// The stream is steady when two consecutive packets
//  * are CONTIGUOUS on the sample clock (the second starts where the first
//    ended, within [contiguityTolerance]; a strap-clock jump or a hole is not
//    flow), AND
//  * advance on the sample clock IN STEP with the wall clock (within
//    [stepTolerance]; one second of samples delivered in 20 ms is a burst), AND
//  * arrive no more than [pairWindow] apart.
// One packet is never enough and the same packet twice is not flow.
//
// SAMPLE CLOCK. A packet's newest sample was acquired before the phone got it.
// [EcgSampleClock] maps phone wall time to sample time through the packet that
// was LEAST delayed, min(receipt - newest sample time) over recent packets. The
// true delay of the freshest packet is at least that, so the estimate never
// anchors a window BEHIND the real sample clock (the old "end of the last packet
// plus wall time since it arrived" did, by however late that packet was). What
// it cannot know is a delay shared by EVERY recent packet; the Device lab trace
// prints how far each packet sits behind the best one so that is visible.

class EcgStreamReadiness {
  /// The longest gap between two packets that still counts as a flowing stream.
  /// Packets come about once a second, so this allows one late packet.
  static const Duration pairWindow = Duration(milliseconds: 1500);

  /// How far a packet may start from where the previous one ended (a 100 Hz
  /// sample is 10 ms; the rest is timestamp jitter).
  static const Duration contiguityTolerance = Duration(milliseconds: 50);

  /// How far the sample clock may advance from the wall clock between two
  /// packets. Packets are about a second apart and BLE jitter is a few hundred
  /// milliseconds at worst; a buffered burst is off by nearly a whole packet.
  static const Duration stepTolerance = Duration(milliseconds: 600);

  static const int _samplePeriodUs = 10000; // 100 Hz

  DateTime? _lastAt;
  int? _lastEndUs;
  bool _ready = false;

  bool get ready => _ready;

  /// Offer a packet: [at] is when the phone received it, [strapTime] the
  /// packet's own time on the strap clock, in seconds (its newest sample; see
  /// PACKET TIME above), [sampleCount] how many 100 Hz samples it carries. True
  /// once steady (and on every later call).
  bool offer({
    required DateTime at,
    required double strapTime,
    int sampleCount = 100,
  }) {
    if (_ready) return true;
    final endUs = (strapTime * 1000000).round();
    final startUs = endUs - sampleCount * _samplePeriodUs;
    final prevAt = _lastAt, prevEndUs = _lastEndUs;
    if (prevAt != null && prevEndUs != null) {
      final wallUs = at.difference(prevAt).inMicroseconds;
      final contiguous =
          (startUs - prevEndUs).abs() <= contiguityTolerance.inMicroseconds;
      final inStep = ((endUs - prevEndUs) - wallUs).abs() <=
          stepTolerance.inMicroseconds;
      if (wallUs >= 0 &&
          wallUs <= pairWindow.inMicroseconds &&
          contiguous &&
          inStep) {
        _ready = true;
        return true;
      }
    }
    // Too late to pair with the last one, not contiguous, or a burst: this
    // packet is now the first of a new pair.
    _lastAt = at;
    _lastEndUs = endUs;
    return false;
  }

  void reset() {
    _lastAt = null;
    _lastEndUs = null;
    _ready = false;
  }
}

/// Phone wall time <-> ECG sample time, from the least-delayed recent packet.
/// All values are on the sample clock's own epoch (the strap clock); only
/// differences between them are meaningful.
class EcgSampleClock {
  EcgSampleClock({this.keep = 8});

  /// How many recent packets the minimum is taken over (~ that many seconds).
  final int keep;

  final List<int> _delaysUs = []; // receipt - newest sample time, microseconds

  bool get hasEstimate => _delaysUs.isNotEmpty;

  static int _delay(DateTime receivedAt, Duration sampleEnd) =>
      receivedAt.microsecondsSinceEpoch - sampleEnd.inMicroseconds;

  /// Record a packet: [receivedAt] when the phone got it, [sampleEnd] the
  /// sample-clock time just after its newest sample.
  void add({required DateTime receivedAt, required Duration sampleEnd}) {
    _delaysUs.add(_delay(receivedAt, sampleEnd));
    if (_delaysUs.length > keep) _delaysUs.removeAt(0);
  }

  int? get _minUs => _delaysUs.isEmpty
      ? null
      : _delaysUs.reduce((a, b) => a < b ? a : b);

  /// receipt - newest sample time of the least-delayed recent packet, or null.
  /// Only meaningful as the offset [sampleAt] applies.
  Duration? get baseline {
    final m = _minUs;
    return m == null ? null : Duration(microseconds: m);
  }

  /// The sample-clock time that corresponds to phone time [wall]: what the
  /// strap was sampling at that instant if the least-delayed packet was
  /// received the moment its newest sample was made. Null before any packet.
  Duration? sampleAt(DateTime wall) {
    final m = _minUs;
    return m == null ? null : Duration(microseconds: wall.microsecondsSinceEpoch - m);
  }

  /// How much later than the best recent packet this one was received.
  /// Zero for the best packet itself; null before any packet.
  Duration? excessOf({
    required DateTime receivedAt,
    required Duration sampleEnd,
  }) {
    final m = _minUs;
    if (m == null) return null;
    return Duration(microseconds: _delay(receivedAt, sampleEnd) - m);
  }

  void reset() => _delaysUs.clear();
}
