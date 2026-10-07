// snooze_settings.dart — the wearer's snooze settings, the persisted snooze
// state, and the store for both (wake_meta).
//
// STUB (red phase). Pinned by test/alarm_snooze/snooze_settings_test.dart.

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
      throw UnimplementedError();

  /// Like a copy, with every field clamped.
  SnoozeSettings copyWith({
    int? requiredTaps,
    int? windowMs,
    int? minutes,
    int? cap,
  }) =>
      throw UnimplementedError();

  /// Never throws: anything unreadable gives the default of that field.
  factory SnoozeSettings.fromJson(Object? json) => throw UnimplementedError();

  Map<String, Object?> toJson() => throw UnimplementedError();

  Duration get window => throw UnimplementedError();
  Duration get snoozeFor => throw UnimplementedError();

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
  factory SnoozeState.fromJson(Object? json) => throw UnimplementedError();
  Map<String, Object?> toJson() => throw UnimplementedError();

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
  Future<SnoozeSettings> loadSettings() => throw UnimplementedError();
  @override
  Future<void> saveSettings(SnoozeSettings s) => throw UnimplementedError();
  @override
  Future<SnoozeState?> loadState() => throw UnimplementedError();
  @override
  Future<void> saveState(SnoozeState? s) => throw UnimplementedError();
}
