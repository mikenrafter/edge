// What the compiler gives up first when a pattern cannot be played as
// written. A small enum of its own so the stored sequence (plain Dart) and the
// compiler can both name it without importing each other.

/// [rhythm] keeps the timing and settles for a nearby loudness; [dynamics]
/// keeps the loudness and settles for timing a sixteenth or so off.
enum HapticPriority { rhythm, dynamics }
