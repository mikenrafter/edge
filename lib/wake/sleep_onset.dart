// sleep_onset.dart — the onset of the sleep that is in progress, for Natural
// Wake's main-sleep / nap decision when NO expected sleep schedule is saved.
//
// Where the onset comes from. The causal stager (`CausalStager`) has no
// sleep-onset detector by contract ("the API stages whatever it is given"), so
// it cannot say when tonight's sleep began. The derive pass can: its
// provisional `day_result` row carries the night's sleep WINDOW
// (`window_json`, a Metric envelope `{value: {onset_ms, offset_ms, ...}}`, or a
// bare `{onset_ms, offset_ms}` from an importer). That row is rewritten on
// every drain, so by the time the Natural window opens it holds this night's
// candidate. This file only READS it; nothing here derives, guesses or
// substitutes.
//
// Never fabricated. Any doubt returns null and [NaturalWakePlanner.classify]
// keeps answering `unknown`:
//   * no row, no window, a "—" (no sleep) value, unreadable JSON;
//   * an onset at or after the wake time, or not yet in the past;
//   * an onset more than [kMaxSleepLookback] before the wake time (an earlier
//     day's sleep, or a nap from yesterday afternoon);
//   * a window that ended more than [kOnsetWindowStaleness] ago: that sleep is
//     over, and a later one has not been derived yet.

import 'dart:convert';

import '../data/db.dart';

/// An onset further back than this from the wake time is not tonight's sleep.
const Duration kMaxSleepLookback = Duration(hours: 16);

/// A candidate window whose end is older than this relative to now describes a
/// sleep that already finished, not the one in progress.
const Duration kOnsetWindowStaleness = Duration(minutes: 90);

/// The onset of the sleep in progress at [now], bound for the alarm at
/// [wakeAt], from persisted `window_json` values ([windows], newest day first
/// or any order). Null when none qualifies.
DateTime? detectedSleepOnset({
  required Iterable<Object?> windows,
  required DateTime wakeAt,
  required DateTime now,
}) {
  DateTime? bestOnset;
  DateTime? bestEnd;
  for (final raw in windows) {
    final w = _windowOf(raw);
    if (w == null) continue;
    final onset = DateTime.fromMillisecondsSinceEpoch(w.onsetMs.round());
    if (!onset.isBefore(now) || !onset.isBefore(wakeAt)) continue;
    if (wakeAt.difference(onset) > kMaxSleepLookback) continue;
    final offMs = w.offsetMs;
    DateTime? end;
    if (offMs != null) {
      if (offMs <= w.onsetMs) continue; // corrupt: ends before it starts
      end = DateTime.fromMillisecondsSinceEpoch(offMs.round());
      if (now.difference(end) > kOnsetWindowStaleness) continue;
    }
    // The most recent sleep wins; an open-ended one counts as newest.
    final e = end ?? now;
    if (bestEnd == null || e.isAfter(bestEnd)) {
      bestEnd = e;
      bestOnset = onset;
    }
  }
  return bestOnset;
}

/// [detectedSleepOnset] over the stored windows of the most recent days.
/// Failures read as "not detectable".
Future<DateTime?> loadDetectedSleepOnset(DateTime wakeAt,
    {DateTime? now}) async {
  try {
    final rows = await LocalDb.sleepWindowRows(3);
    return detectedSleepOnset(
      windows: [for (final r in rows) r['window_json']],
      wakeAt: wakeAt,
      now: now ?? DateTime.now(),
    );
  } catch (_) {
    return null;
  }
}

class _Window {
  const _Window(this.onsetMs, this.offsetMs);
  final double onsetMs;
  final double? offsetMs;
}

_Window? _windowOf(Object? raw) {
  Object? decoded = raw;
  if (raw is String) {
    if (raw.isEmpty) return null;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
  if (decoded is! Map) return null;
  // The Metric envelope's `value` is the string '—' on a night with no sleep.
  final v = decoded['value'];
  final map = v is Map
      ? v
      : (decoded['onset_ms'] != null || decoded['offset_ms'] != null
          ? decoded
          : null);
  if (map == null) return null;
  final on = map['onset_ms'], off = map['offset_ms'];
  if (on is! num || !on.isFinite || on <= 0) return null;
  return _Window(on.toDouble(), off is num && off.isFinite ? off.toDouble() : null);
}
