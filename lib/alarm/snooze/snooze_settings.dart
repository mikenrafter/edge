// snooze_settings.dart — the wearer's snooze settings, the persisted snooze
// state, and the store for both (wake_meta).
//
// Snooze is OPT-IN ([SnoozeSettings.enabled], default false): an owner-safety
// decision. Off, the native alarm path is exactly what it was before the
// snooze existed.
//
// Pinned by test/alarm_snooze/snooze_settings_test.dart.

import 'dart:convert';

import '../../data/db.dart';
import 'snooze_schedule.dart';

const int kSnoozeTapsMin = 1;
const int kSnoozeTapsMax = 5;
const int kSnoozeTapsDefault = 2;

/// The dismiss window, in ms. Its own setting, not the gesture tap timing.
const int kSnoozeWindowMsMin = 1000;
const int kSnoozeWindowMsMax = 15000;
const int kSnoozeWindowMsDefault = 4000;

const int kSnoozeMinutesMin = 1;
const int kSnoozeMinutesMax = 30;
const int kSnoozeMinutesDefault = 5;

/// `wake_meta` keys.
const String kSnoozeSettingsKey = 'snooze_settings';
const String kSnoozeStateKey = 'snooze_state';
const String kSnoozeWindowKey = 'snooze_window';

class SnoozeSettings {
  const SnoozeSettings({
    this.enabled = false,
    this.requiredTaps = kSnoozeTapsDefault,
    this.windowMs = kSnoozeWindowMsDefault,
    this.minutes = kSnoozeMinutesDefault,
    this.cap = kSnoozeCapDefault,
  });

  /// The wearer switched snooze on. False until they do.
  final bool enabled;
  final int requiredTaps;
  final int windowMs;
  final int minutes;
  final int cap;

  /// Each field clamped into its range.
  factory SnoozeSettings.clamped({
    bool enabled = false,
    int requiredTaps = kSnoozeTapsDefault,
    int windowMs = kSnoozeWindowMsDefault,
    int minutes = kSnoozeMinutesDefault,
    int cap = kSnoozeCapDefault,
  }) =>
      SnoozeSettings(
        enabled: enabled,
        requiredTaps: requiredTaps.clamp(kSnoozeTapsMin, kSnoozeTapsMax),
        windowMs: windowMs.clamp(kSnoozeWindowMsMin, kSnoozeWindowMsMax),
        minutes: minutes.clamp(kSnoozeMinutesMin, kSnoozeMinutesMax),
        cap: cap.clamp(kSnoozeCapMin, kSnoozeCapMax),
      );

  /// Like a copy, with every field clamped.
  SnoozeSettings copyWith({
    bool? enabled,
    int? requiredTaps,
    int? windowMs,
    int? minutes,
    int? cap,
  }) =>
      SnoozeSettings.clamped(
        enabled: enabled ?? this.enabled,
        requiredTaps: requiredTaps ?? this.requiredTaps,
        windowMs: windowMs ?? this.windowMs,
        minutes: minutes ?? this.minutes,
        cap: cap ?? this.cap,
      );

  /// Never throws: anything unreadable gives the default of that field.
  factory SnoozeSettings.fromJson(Object? json) {
    if (json is! Map) return const SnoozeSettings();
    int field(String k, int d) {
      final v = json[k];
      return v is num ? v.toInt() : d;
    }

    return SnoozeSettings.clamped(
      // Only a stored `true` switches it on; anything else (absent, a legacy
      // record, a wrong type) is off.
      enabled: json['enabled'] == true,
      requiredTaps: field('requiredTaps', kSnoozeTapsDefault),
      windowMs: field('windowMs', kSnoozeWindowMsDefault),
      minutes: field('minutes', kSnoozeMinutesDefault),
      cap: field('cap', kSnoozeCapDefault),
    );
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'requiredTaps': requiredTaps,
        'windowMs': windowMs,
        'minutes': minutes,
        'cap': cap,
      };

  Duration get window => Duration(milliseconds: windowMs);
  Duration get snoozeFor => Duration(minutes: minutes);

  @override
  bool operator ==(Object other) =>
      other is SnoozeSettings &&
      other.enabled == enabled &&
      other.requiredTaps == requiredTaps &&
      other.windowMs == windowMs &&
      other.minutes == minutes &&
      other.cap == cap;

  @override
  int get hashCode =>
      Object.hash(enabled, requiredTaps, windowMs, minutes, cap);
}

/// A snooze waiting for its re-alarm (the only thing worth surviving a restart).
class SnoozeState {
  const SnoozeState(
      {required this.count, required this.reAlarmAt, this.fireAt});

  /// Snoozes set so far (>= 1): the index of the NEXT re-alarm.
  final int count;

  /// When the re-alarm is due (phone clock).
  final DateTime reAlarmAt;

  /// The native alarm's own fire stamp this chain answers (null for a state
  /// written before it was kept). A wake confirmation counts only if it is not
  /// older than this minus [kSnoozeConfirmLookback]. Not part of equality: a
  /// snooze is its count and its due time.
  final DateTime? fireAt;

  /// Throws [FormatException] on anything unreadable (count < 1, a bad
  /// instant); the store reads that as "no snooze pending".
  factory SnoozeState.fromJson(Object? json) {
    if (json is Map) {
      final c = json['count'], at = json['reAlarmAtMs'];
      final f = json['fireAtMs'];
      if (c is int && c >= 1 && at is int) {
        return SnoozeState(
            count: c,
            reAlarmAt: DateTime.fromMillisecondsSinceEpoch(at),
            fireAt: f is int ? DateTime.fromMillisecondsSinceEpoch(f) : null);
      }
    }
    throw FormatException('not a snooze state', json);
  }

  Map<String, Object?> toJson() => {
        'count': count,
        'reAlarmAtMs': reAlarmAt.millisecondsSinceEpoch,
        if (fireAt != null) 'fireAtMs': fireAt!.millisecondsSinceEpoch,
      };

  @override
  bool operator ==(Object other) =>
      other is SnoozeState &&
      other.count == count &&
      other.reAlarmAt == reAlarmAt;

  @override
  int get hashCode => Object.hash(count, reAlarmAt);
}

/// Slack for clock skew: a wake confirmation counts for the alarm that fired at
/// F only when it is at or after F minus this. Anything earlier is another
/// sleep block's (the wearer was up, went back to sleep before this alarm), and
/// never suppresses the snooze: failing toward waking is fine.
const Duration kSnoozeConfirmLookback = Duration(seconds: 60);

/// A persisted window or snooze whose native fire is older than this is
/// dropped on resume, and a running chain ends this long after its fire: a
/// re-alarm days (or hours) later is a phantom.
const Duration kSnoozeMaxAge = Duration(hours: 3);

/// A persisted fire matches the alarm occurrence the app knows when the two
/// stamps are within this of each other (the 57 and 58 events of one fire).
const Duration kSnoozeFireMatch = Duration(minutes: 5);

/// The dismiss window after a native double-tap stop, kept while it is open so
/// a restart cannot lose it: the native alarm is already stopped, and nothing
/// but this window (or its snooze) will ever wake the wearer again.
class SnoozeWindow {
  const SnoozeWindow({
    required this.stoppedAt,
    this.fireAt,
    this.taps = const [],
    this.tapIds = const [],
  });

  /// When the native alarm stopped (the termination's own time, phone clock).
  final DateTime stoppedAt;

  /// The native fire stamp this stop answers.
  final DateTime? fireAt;

  /// The band double taps heard since the stop (their own times).
  final List<DateTime> taps;

  /// The identities of those taps (event identity strings), so the same event
  /// delivered again after a restart is not counted twice.
  final List<String> tapIds;

  /// Throws [FormatException] on anything unreadable.
  factory SnoozeWindow.fromJson(Object? json) {
    if (json is Map) {
      final s = json['stoppedAtMs'], f = json['fireAtMs'], t = json['tapsMs'];
      final ids = json['tapIds'];
      if (s is int && (t == null || t is List) && (ids == null || ids is List)) {
        return SnoozeWindow(
          stoppedAt: DateTime.fromMillisecondsSinceEpoch(s),
          fireAt: f is int ? DateTime.fromMillisecondsSinceEpoch(f) : null,
          taps: [
            for (final x in (t as List? ?? const []))
              if (x is int) DateTime.fromMillisecondsSinceEpoch(x),
          ],
          tapIds: [
            for (final x in (ids as List? ?? const []))
              if (x is String) x,
          ],
        );
      }
    }
    throw FormatException('not a snooze window', json);
  }

  Map<String, Object?> toJson() => {
        'stoppedAtMs': stoppedAt.millisecondsSinceEpoch,
        if (fireAt != null) 'fireAtMs': fireAt!.millisecondsSinceEpoch,
        'tapsMs': [for (final t in taps) t.millisecondsSinceEpoch],
        'tapIds': tapIds,
      };
}

abstract interface class SnoozeStore {
  Future<SnoozeSettings> loadSettings();
  Future<void> saveSettings(SnoozeSettings s);

  /// Null: no snooze pending (or the stored value was unreadable).
  Future<SnoozeState?> loadState();

  /// Null clears.
  Future<void> saveState(SnoozeState? s);

  /// The open dismiss window, or null (none open, or unreadable).
  Future<SnoozeWindow?> loadWindow();

  /// Null clears.
  Future<void> saveWindow(SnoozeWindow? w);
}

/// [SnoozeStore] over `LocalDb.wakeMetaGet/Set`.
class DbSnoozeStore implements SnoozeStore {
  const DbSnoozeStore();

  @override
  Future<SnoozeSettings> loadSettings() async {
    try {
      final raw = await LocalDb.wakeMetaGet(kSnoozeSettingsKey);
      return raw == null
          ? const SnoozeSettings()
          : SnoozeSettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return const SnoozeSettings();
    }
  }

  @override
  Future<void> saveSettings(SnoozeSettings s) => LocalDb.wakeMetaSet(
      kSnoozeSettingsKey,
      jsonEncode(SnoozeSettings.clamped(
              enabled: s.enabled,
              requiredTaps: s.requiredTaps,
              windowMs: s.windowMs,
              minutes: s.minutes,
              cap: s.cap)
          .toJson()));

  @override
  Future<SnoozeState?> loadState() async {
    try {
      final raw = await LocalDb.wakeMetaGet(kSnoozeStateKey);
      if (raw == null || raw.isEmpty) return null;
      return SnoozeState.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// A cleared state is stored as '' (wake_meta has no delete); it reads as
  /// none.
  @override
  Future<void> saveState(SnoozeState? s) => LocalDb.wakeMetaSet(
      kSnoozeStateKey, s == null ? '' : jsonEncode(s.toJson()));

  @override
  Future<SnoozeWindow?> loadWindow() async {
    try {
      final raw = await LocalDb.wakeMetaGet(kSnoozeWindowKey);
      if (raw == null || raw.isEmpty) return null;
      return SnoozeWindow.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveWindow(SnoozeWindow? w) => LocalDb.wakeMetaSet(
      kSnoozeWindowKey, w == null ? '' : jsonEncode(w.toJson()));
}
