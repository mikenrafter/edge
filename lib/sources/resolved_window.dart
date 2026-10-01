// The window the Resolved data screen looks at: the user's choice, kept apart
// from the resolver so the pure view can name the choices without reaching the
// database.

import 'package:shared_preferences/shared_preferences.dart';

// The user's choice: a few presets, or no cutoff. Three days is only the
// default. `null` means no cutoff everywhere below.

const int kDefaultResolvedWindowDays = 3;
const List<int?> kResolvedWindowChoices = [1, 3, 7, 14, 30, null];

const _kResolvedWindowKey = 'resolved_window_days';
// SharedPreferences has no null, so "no cutoff" is stored as 0.
const _kNoCutoff = 0;

/// The stored window in days, `null` for no cutoff. A stored value that is not
/// one of [kResolvedWindowChoices] falls back to the default.
Future<int?> loadResolvedWindowDays() async {
  final v = (await SharedPreferences.getInstance()).getInt(_kResolvedWindowKey);
  if (v == null) return kDefaultResolvedWindowDays;
  if (v == _kNoCutoff) return null;
  return kResolvedWindowChoices.contains(v) ? v : kDefaultResolvedWindowDays;
}

Future<void> saveResolvedWindowDays(int? days) async {
  await (await SharedPreferences.getInstance())
      .setInt(_kResolvedWindowKey, days ?? _kNoCutoff);
}

/// Epoch seconds the window starts at. [days] counts local calendar days
/// ending today, so the start is a local midnight (a day is 23 or 25 h across
/// DST). No cutoff starts at [earliest], the first second anything was
/// recorded; with nothing recorded the window is empty rather than reaching
/// back to 1970.
int resolvedWindowStart(DateTime now, int? days, {int? earliest}) {
  if (days == null) return earliest ?? now.millisecondsSinceEpoch ~/ 1000;
  return DateTime(now.year, now.month, now.day - (days - 1))
          .millisecondsSinceEpoch ~/
      1000;
}

String resolvedWindowLabel(int? days) => switch (days) {
      null => 'all recorded time',
      1 => 'today',
      final n => 'the last $n days',
    };

/// Rows drawn at most; a long window can hold thousands of stretches and a
/// screen of that many boxes helps nobody.
const int kResolvedRowCap = 200;

({List<Map<String, Object?>> rows, int total}) capResolvedRows(
  List<Map<String, Object?>> rows, {
  int cap = kResolvedRowCap,
}) =>
    (
      rows: rows.length <= cap ? rows : rows.sublist(rows.length - cap),
      total: rows.length,
    );
