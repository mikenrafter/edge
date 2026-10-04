/// Which days a running derive pass has not finished yet. Screens that show a
/// day's last result read this to decide whether to say "As of <time>".
class RecalcState {
  const RecalcState({
    this.days = const <String>{},
    this.passStartedAt,
    this.crossDay = false,
  });

  /// Local day labels still being recalculated.
  final Set<String> days;

  /// When the scope became known; null when no pass is in progress.
  final DateTime? passStartedAt;

  /// The cross-day / baseline step is running.
  final bool crossDay;

  static const RecalcState idle = RecalcState();

  RecalcState copyWith({
    Set<String>? days,
    DateTime? passStartedAt,
    bool? crossDay,
  }) =>
      RecalcState(
        days: days ?? this.days,
        passStartedAt: passStartedAt ?? this.passStartedAt,
        crossDay: crossDay ?? this.crossDay,
      );

  // Value equality so a ValueNotifier does not tick when nothing changed
  // (idle -> idle).
  @override
  bool operator ==(Object other) =>
      other is RecalcState &&
      other.passStartedAt == passStartedAt &&
      other.crossDay == crossDay &&
      other.days.length == days.length &&
      other.days.containsAll(days);

  @override
  int get hashCode => Object.hash(passStartedAt, crossDay, days.length);
}

/// The time to print as "As of", or null for no label. Non-null only when the
/// shown row has a real computed time AND a newer result for it is on the way:
/// its day is in the running pass, or it is a cross-day card and the cross-day
/// step is running. Never invents a time.
DateTime? asOfFor({
  required String? shownDay,
  required DateTime? computedAt,
  required RecalcState recalc,
  bool dependsOnCrossDay = false,
}) {
  if (computedAt == null) return null;
  if (shownDay != null && recalc.days.contains(shownDay)) return computedAt;
  if (dependsOnCrossDay && recalc.crossDay) return computedAt;
  return null;
}
