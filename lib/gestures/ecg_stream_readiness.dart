// ecg_stream_readiness.dart — "is the ECG stream really up?" for the tap
// counter. Starting the stream only means a command was written; the band can
// take many seconds to begin sending, and an acknowledgement buzz sent before
// that tells the wearer to touch a sensor that is not listening yet.
//
// The rule, in one place so it can be tested and changed: the stream is steady
// when a second packet arrives no more than [pairWindow] after the previous
// one AND the strap clock moved forward. One packet is not enough (it can be
// a leftover), and the same packet twice is not flow.

class EcgStreamReadiness {
  /// The longest gap between two packets that still counts as a flowing stream.
  /// Packets come about once a second, so this allows one late packet.
  static const Duration pairWindow = Duration(milliseconds: 1500);

  DateTime? _lastAt;
  double? _lastStrapTime;
  bool _ready = false;

  bool get ready => _ready;

  /// Offer a packet: [at] is when the phone received it, [strapTime] the
  /// packet's own start on the strap clock, in seconds. True once steady (and
  /// on every later call).
  bool offer({required DateTime at, required double strapTime}) {
    if (_ready) return true;
    final prevAt = _lastAt, prevStrap = _lastStrapTime;
    if (prevAt != null &&
        prevStrap != null &&
        !at.difference(prevAt).isNegative &&
        at.difference(prevAt) <= pairWindow &&
        strapTime > prevStrap) {
      _ready = true;
      return true;
    }
    // Too late to pair with the last one, or not newer: this packet is now the
    // first of a new pair.
    _lastAt = at;
    _lastStrapTime = strapTime;
    return false;
  }

  void reset() {
    _lastAt = null;
    _lastStrapTime = null;
    _ready = false;
  }
}
