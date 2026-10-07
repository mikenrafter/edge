// snooze_settings.dart — the wearer's snooze settings, the persisted snooze
// state, and the store for both (wake_meta).
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

class SnoozeSettings {
  const SnoozeSettings({
    this.requiredTaps = kSnoozeTapsDefault,
    this.windowMs = kSnoozeWindowMsDefault,
    this.minutes = kSnoozeMinutesDefault,
    this.cap = kSnoozeCapDefault,
  });

  final int requiredTaps;
  final int windowMs;
  final int minutes;
  final int cap;

  /// Each field clamped into its range.
  factory SnoozeSettings.clamped({
    int requiredTaps = kSnoozeTapsDefault,
    int windowMs = kSnoozeWindowMsDefault,
    int minutes = kSnoozeMinutesDefault,
    int cap = kSnoozeCapDefault,
  }) =>
      SnoozeSettings(
        requiredTaps: requiredTaps.clamp(kSnoozeTapsMin, kSnoozeTapsMax),
        windowMs: windowMs.clamp(kSnoozeWindowMsMin, kSnoozeWindowMsMax),
        minutes: minutes.clamp(kSnoozeMinutesMin, kSnoozeMinutesMax),
        cap: cap.clamp(kSnoozeCapMin, kSnoozeCapMax),
      );

  /// Like a copy, with every field clamped.
  SnoozeSettings copyWith({
    int? requiredTaps,
    int? windowMs,
    int? minutes,
    int? cap,
  }) =>
      SnoozeSettings.clamped(
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
      requiredTaps: field('requiredTaps', kSnoozeTapsDefault),
      windowMs: field('windowMs', kSnoozeWindowMsDefault),
      minutes: field('minutes', kSnoozeMinutesDefault),
      cap: field('cap', kSnoozeCapDefault),
    );
  }

  Map<String, Object?> toJson() => {
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
      other.requiredTaps == requiredTaps &&
      other.windowMs == windowMs &&
      other.minutes == minutes &&
      other.cap == cap;

  @override
  int get hashCode => Object.hash(requiredTaps, windowMs, minutes, cap);
}

/// A snooze waiting for its re-alarm (the only thing worth surviving a restart).
class SnoozeState {
  const SnoozeState({required this.count, required this.reAlarmAt});

  /// Snoozes set so far (>= 1): the index of the NEXT re-alarm.
  final int count;

  /// When the re-alarm is due (phone clock).
  final DateTime reAlarmAt;

  /// Throws [FormatException] on anything unreadable (count < 1, a bad
  /// instant); the store reads that as "no snooze pending".
  factory SnoozeState.fromJson(Object? json) {
    if (json is Map) {
      final c = json['count'], at = json['reAlarmAtMs'];
      if (c is int && c >= 1 && at is int) {
        return SnoozeState(
            count: c, reAlarmAt: DateTime.fromMillisecondsSinceEpoch(at));
      }
    }
    throw FormatException('not a snooze state', json);
  }

  Map<String, Object?> toJson() => {
        'count': count,
        'reAlarmAtMs': reAlarmAt.millisecondsSinceEpoch,
      };

  @override
  bool operator ==(Object other) =>
      other is SnoozeState &&
      other.count == count &&
      other.reAlarmAt == reAlarmAt;

  @override
  int get hashCode => Object.hash(count, reAlarmAt);
}

abstract interface class SnoozeStore {
  Future<SnoozeSettings> loadSettings();
  Future<void> saveSettings(SnoozeSettings s);

  /// Null: no snooze pending (or the stored value was unreadable).
  Future<SnoozeState?> loadState();

  /// Null clears.
  Future<void> saveState(SnoozeState? s);
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
}
