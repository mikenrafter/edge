// Immutable persisted chart data. The read adapter owns construction; widgets only read it.
import 'package:flutter/material.dart' show Color, immutable;

/// One slot per minute. A sample's index IS its clock time, which is what
/// makes every lane share one axis without any of them being resampled.
const int kDayMinutes = 1440;

/// The day, drawn. All four lanes on one time base, built once.
@immutable
class DayGraph {
  const DayGraph({
    this.hr = const [],
    this.movement = const [],
    this.rest = const [],
    this.work = const [],
    this.dayStart,
  });

  /// Epoch second of slot 0 — local midnight for a whole day, the window's
  /// first minute for a [window]. The annotation domain runs `dayStart` ..
  /// `dayStart + slots * 60`. Null for a graph built without a day.
  final int? dayStart;

  /// Beats per minute, one slot per minute of the day, `null` where nothing
  /// was recorded.
  final List<double?> hr;

  /// Share of each minute spent moving, 0…1, `null` where nothing was
  /// recorded. Note the difference from a zero: 0 is a minute we watched you
  /// sit still, `null` is a minute we were not there for.
  final List<double?> movement;

  /// Asleep and naps, as (from, to) minute of the day. NOT drawn: the night is
  /// a chart annotation and a nap is its own annotation. Kept because a known
  /// night or nap is measured time ([unmeasured]) and the card's emptiness test.
  final List<(int, int, Color)> rest;

  /// Workouts, same units.
  final List<(int, int, Color)> work;

  int get slots => hr.length > movement.length ? hr.length : movement.length;

  bool get hasCurve => hr.any((v) => v != null);

  /// Minutes [lo, hi) of this graph, re-based so slot 0 is minute [lo]. Spans
  /// are clipped to the window, not dropped — a night that runs past the
  /// window's edge was still a night inside it.
  DayGraph window(int lo, int hi) {
    List<double?> cut(List<double?> l) =>
        l.sublist(lo.clamp(0, l.length), hi.clamp(0, l.length));
    List<(int, int, Color)> clip(List<(int, int, Color)> spans) => [
      for (final (a, b, col) in spans)
        if (b > lo && a < hi) (a.clamp(lo, hi) - lo, b.clamp(lo, hi) - lo, col),
    ];
    return DayGraph(
      hr: cut(hr),
      movement: cut(movement),
      rest: clip(rest),
      work: clip(work),
      dayStart: dayStart == null ? null : dayStart! + lo * 60,
    );
  }

  bool get isEmpty =>
      !hasCurve &&
      rest.isEmpty &&
      work.isEmpty &&
      !movement.any((v) => v != null);

  /// The stretches with nothing measured in them, as (from, to) minutes.
  ///
  /// EVERY lane has to be empty. A minute with movement but no heart rate was
  /// still a minute we were there for, and so was a minute inside a night or a
  /// workout — the span itself is the measurement, even where no curve was
  /// drawn over it. Marking those as unrecorded would put the two claims on
  /// top of each other and let the ground contradict the band.
  List<(int, int)> get unmeasured {
    final n = slots;
    final known = List<bool>.filled(n, false);
    for (final (a, b, _) in [...rest, ...work]) {
      for (var i = a; i < b && i < n; i++) {
        known[i] = true;
      }
    }
    final out = <(int, int)>[];
    int? from;
    for (var i = 0; i < n; i++) {
      final has =
          known[i] ||
          (i < hr.length && hr[i] != null) ||
          (i < movement.length && movement[i] != null);
      if (has) {
        if (from != null) out.add((from, i));
        from = null;
      } else {
        from ??= i;
      }
    }
    if (from != null) out.add((from, n));
    return out;
  }
}
