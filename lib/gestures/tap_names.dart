// tap_names.dart — the plain-English name of an ECG gesture count (8AK C): the
// opening double tap, then one ECG sensor touch per further count. For logs,
// cards and anything outside a widget tree; screens use the same text through
// AppLocalizations.gestureEcgTapName (a plural over the number of ECG taps).
// Pure Dart.

/// "Double tap" for [count] 2, "Double tap + 1 ECG tap" for 3, "Double tap + 2
/// ECG taps" for 4 and so on. [count] is the activation count (the double tap
/// itself is 2); anything below 2 reads as the double tap.
String ecgTapCountName(int count) {
  final n = count - 2;
  if (n <= 0) return 'Double tap';
  return n == 1 ? 'Double tap + 1 ECG tap' : 'Double tap + $n ECG taps';
}
