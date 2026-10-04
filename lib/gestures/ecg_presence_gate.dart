// The band's contact flag as a per-packet veto on the sample contact mask
// (8AN fast path). Counting stays sample-timed; the band's debounced presence
// bit only stops noisy packets (the early ones the sensor settle used to
// protect against) from counting as a touch. If the band never reports
// presence while the samples keep showing contact, the flag is not usable on
// this strap and the veto is lifted for the rest of the gesture. Pure.

/// Consecutive presence-false packets with sample contact, with presence never
/// seen, before the veto is lifted.
const int kEcgPresenceFallbackPackets = 4;

class EcgPresenceGate {
  EcgPresenceGate({this.fallbackPackets = kEcgPresenceFallbackPackets});

  final int fallbackPackets;

  bool _everPresent = false;
  bool _fellBack = false;
  int _suspectRun = 0;

  /// A packet with presence true was seen this gesture.
  bool get everPresent => _everPresent;

  /// The veto is lifted for the rest of the gesture (sticky).
  bool get fellBack => _fellBack;

  /// Consecutive presence-false packets with sample contact, counted only
  /// while presence was never seen and the veto is still in force.
  int get suspectRun => _suspectRun;

  /// The session must not let the first touch window close on these packets:
  /// the samples say touch and the band has not yet said whether to believe it.
  bool get holdsFirstWindow => !_fellBack && !_everPresent && _suspectRun > 0;

  /// The mask the counter should see for one packet; advances the state.
  List<bool> filter(List<bool> mask, {required bool presence}) {
    if (_fellBack) return mask;
    if (presence) {
      _everPresent = true;
      _suspectRun = 0;
      return mask;
    }
    if (!_everPresent) {
      if (mask.any((c) => c)) {
        _suspectRun++;
        if (_suspectRun >= fallbackPackets) {
          _fellBack = true;
          _suspectRun = 0;
          return mask;
        }
      } else {
        _suspectRun = 0;
      }
    }
    return List<bool>.filled(mask.length, false);
  }
}
