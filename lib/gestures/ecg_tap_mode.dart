// How an ECG tap gesture decides the finger is on the band (8AN). Accurate
// reads the signal and waits for it to settle; fast skips the band's warm-up
// packet and starts counting about a second sooner.

enum EcgTapMode {
  accurate('accurate'),
  fast('fast');

  const EcgTapMode(this.id);

  /// The value stored in the gesture settings.
  final String id;

  /// The mode stored under [id], or null for an unknown or missing value so the
  /// caller applies its own default.
  static EcgTapMode? fromId(String? id) {
    for (final m in values) {
      if (m.id == id) return m;
    }
    return null;
  }
}
