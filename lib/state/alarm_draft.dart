// alarm_draft.dart — 8O: the alarm screen edits an in-memory DRAFT of the whole
// week, and Save is the only thing that persists it or touches the band.
//
// Before this, every row called AppState.setScheduleDay, which saved and re-armed
// at once, so switching and timing seven days could write the band 14 times.
// Now: [AlarmDraft] holds the edits (including the Natural and Gradual
// settings, which are phone-orchestrated and are NEVER sent to the band), and
// [saveAlarmSchedule] is the one Save path: one DB transaction, then ONE arm of
// the fixed must-be-up-by alarm at T, deduped against what the band already
// holds, then a short wait for the band's own confirmation.
//
// Pure: no DB, no BLE, no widgets. Everything it needs comes in as a callback,
// so the write budget is testable with a counting fake.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../wake/wake_settings.dart';
import 'alarm_schedule.dart';

// ── outcome ──────────────────────────────────────────────────────────────────

enum AlarmSaveStatus {
  /// Saved, written to the band, and the band confirmed it latched.
  sentToBand,

  /// Saved and written, but the band's confirmation did not arrive in time.
  sentUnconfirmed,

  /// Saved; the band already holds this occurrence (or there is nothing to
  /// arm), so nothing was written.
  bandAlreadyHasIt,

  /// Saved; the band is not connected. It updates on the next connect.
  savedOffline,

  /// Something failed. [AlarmSaveOutcome.persisted] says whether the schedule
  /// itself was saved (the band write failed) or not.
  failed,
}

class AlarmSaveOutcome {
  const AlarmSaveOutcome(this.status, {this.persisted = true, this.error});

  final AlarmSaveStatus status;

  /// The schedule reached the DB. False only for a [AlarmSaveStatus.failed]
  /// whose transaction did not commit.
  final bool persisted;
  final Object? error;

  bool get ok => status != AlarmSaveStatus.failed;

  /// One line for the header. Never claims more than is known.
  String get headline => switch (status) {
    AlarmSaveStatus.sentToBand => 'Saved and sent to the band',
    AlarmSaveStatus.sentUnconfirmed =>
      'Saved and sent. The band has not confirmed it yet',
    AlarmSaveStatus.bandAlreadyHasIt =>
      'Saved. The band already has this alarm',
    AlarmSaveStatus.savedOffline =>
      'Saved — the band updates when it next connects',
    AlarmSaveStatus.failed =>
      persisted
          ? 'Saved, but the band was not updated: ${_why(error)}'
          : 'Not saved: ${_why(error)}',
  };

  static String _why(Object? e) {
    final t = '${e ?? 'unknown error'}'
        .replaceFirst('Exception: ', '')
        .replaceFirst('Bad state: ', '');
    return t.isEmpty ? 'unknown error' : t;
  }
}

// ── the arm step ─────────────────────────────────────────────────────────────

/// What one pass of the arm logic did to the band.
class AlarmArmReport {
  const AlarmArmReport({
    this.wrote = false,
    this.awaitsConfirmation = false,
    this.error,
  });

  /// A SET_ALARM or DISABLE_ALARM went out.
  final bool wrote;

  /// The write was a SET, so the band's event 56 is the confirmation.
  final bool awaitsConfirmation;

  /// The band refused the arm, or the write threw.
  final Object? error;

  bool get failed => error != null;
}

/// Maps [armNextScheduledOccurrence]'s result onto a report.
AlarmArmReport armReportOf(AlarmArmResult r) {
  if (r.refused) {
    return const AlarmArmReport(
      error: 'the band did not take the alarm. Try again',
    );
  }
  if (r.disabled) return const AlarmArmReport(wrote: true);
  if (r.epoch != null) {
    return const AlarmArmReport(wrote: true, awaitsConfirmation: true);
  }
  return const AlarmArmReport();
}

/// How long Save waits for the band's ALARM_SET (event 56) after a write.
const Duration kAlarmConfirmWait = Duration(seconds: 5);

/// The one Save path. [entries] is the whole week.
///   1. [persist] — one transaction. A failure here stops everything.
///   2. Offline: stop; the band updates when it next connects.
///   3. [arm] — exactly once.
///   4. After a SET, wait up to [confirmWait] for the band's confirmation.
Future<AlarmSaveOutcome> saveAlarmSchedule({
  required List<AlarmScheduleEntry> entries,
  required bool Function() isConnected,
  required Future<void> Function(List<AlarmScheduleEntry> entries) persist,
  required Future<AlarmArmReport> Function() arm,
  required Future<bool> Function(Duration timeout) awaitConfirmed,
  Duration confirmWait = kAlarmConfirmWait,
}) async {
  try {
    await persist(entries);
  } catch (e) {
    return AlarmSaveOutcome(AlarmSaveStatus.failed, persisted: false, error: e);
  }
  if (!isConnected()) {
    return const AlarmSaveOutcome(AlarmSaveStatus.savedOffline);
  }
  final AlarmArmReport report;
  try {
    report = await arm();
  } catch (e) {
    return AlarmSaveOutcome(AlarmSaveStatus.failed, error: e);
  }
  if (report.failed) {
    return AlarmSaveOutcome(AlarmSaveStatus.failed, error: report.error);
  }
  if (!report.wrote) {
    return const AlarmSaveOutcome(AlarmSaveStatus.bandAlreadyHasIt);
  }
  if (!report.awaitsConfirmation) {
    return const AlarmSaveOutcome(AlarmSaveStatus.sentToBand); // a disable
  }
  final confirmed = await awaitConfirmed(confirmWait);
  return AlarmSaveOutcome(
    confirmed ? AlarmSaveStatus.sentToBand : AlarmSaveStatus.sentUnconfirmed,
  );
}

// ── the draft ────────────────────────────────────────────────────────────────

class AlarmDraft extends ChangeNotifier {
  AlarmDraft(List<AlarmScheduleEntry> saved)
    : _saved = List.unmodifiable(fillDefaultAlarmSchedule(saved)),
      _entries = fillDefaultAlarmSchedule(saved);

  List<AlarmScheduleEntry> _saved;
  List<AlarmScheduleEntry> _entries;
  AlarmSaveOutcome? _outcome;
  Future<void>? _inFlight;
  bool _sending = false;
  bool _disposed = false;

  /// Always 7 entries in weekday order.
  List<AlarmScheduleEntry> get entries => List.unmodifiable(_entries);
  List<AlarmScheduleEntry> get saved => _saved;
  AlarmScheduleEntry entry(int weekday) => _entries[_check(weekday)];

  bool get dirty {
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i] != _saved[i]) return true;
    }
    return false;
  }

  /// A Save is in flight (persisting or waiting on the band).
  bool get sending => _sending;

  /// Completes when the in-flight save does; null when none is.
  Future<void>? get inFlight => _inFlight;

  AlarmSaveOutcome? get outcome => _outcome;

  /// Save is live when there is something unsaved, or the last attempt failed
  /// (Retry). Never while a save is already going.
  bool get canSave =>
      !_sending && (dirty || _outcome?.status == AlarmSaveStatus.failed);

  /// Cancel only means something while there is an unsaved edit.
  bool get canCancel => !_sending && dirty;

  // ── edits (memory only) ────────────────────────────────────────────────────

  void setEnabled(int weekday, bool enabled) =>
      _edit(weekday, (e) => e.copyWith(enabled: enabled));

  void setTime(int weekday, int hour, int minute) =>
      _edit(weekday, (e) => e.copyWith(hour: hour, minute: minute));

  void setNaturalWindow(int weekday, int minutes) {
    _checkWindow(minutes);
    _edit(weekday, (e) => e.copyWith(naturalWindowMinutes: minutes));
  }

  void setGradualWindow(int weekday, int minutes) {
    _checkWindow(minutes);
    _edit(weekday, (e) => e.copyWith(gradualWindowMinutes: minutes));
  }

  void setGradualPattern(int weekday, GradualPattern pattern) =>
      _edit(weekday, (e) => e.copyWith(gradualPattern: pattern));

  void setGradualCadence(int weekday, int seconds) {
    if (!isValidGradualCadence(seconds)) {
      throw ArgumentError.value(
        seconds,
        'seconds',
        '$kGradualCadenceMinSec..$kGradualCadenceMaxSec s in '
            '${kGradualCadenceStepSec}s steps',
      );
    }
    _edit(weekday, (e) => e.copyWith(gradualCadenceSec: seconds));
  }

  /// Cancel: back to the saved schedule. Touches nothing outside this object.
  void discard() {
    _entries = List.of(_saved);
    _outcome = null;
    _notify();
  }

  /// The saved schedule changed underneath the screen (a Siri shortcut, the
  /// upgrade explanation). Days the user has not touched follow it; days they
  /// have edited keep their edit. No notification when nothing changed, so it
  /// is safe to call from build.
  void rebase(List<AlarmScheduleEntry> next) {
    final fresh = fillDefaultAlarmSchedule(next);
    var changed = false;
    final merged = <AlarmScheduleEntry>[];
    for (var i = 0; i < 7; i++) {
      final untouched = _entries[i] == _saved[i];
      merged.add(untouched ? fresh[i] : _entries[i]);
      if (merged[i] != _entries[i] || fresh[i] != _saved[i]) changed = true;
    }
    if (!changed) return;
    _saved = List.unmodifiable(fresh);
    _entries = merged;
  }

  // ── save ───────────────────────────────────────────────────────────────────

  /// Hands the whole draft to [send] (see [saveAlarmSchedule]). Returns null
  /// when a save is already running. A throw from [send] is a failure that
  /// persisted nothing, never an unhandled error.
  Future<AlarmSaveOutcome?> save(
    Future<AlarmSaveOutcome> Function(List<AlarmScheduleEntry> entries) send,
  ) {
    if (_sending) return Future.value(null);
    final snapshot = List<AlarmScheduleEntry>.of(_entries);
    _sending = true;
    _outcome = null;
    _notify();
    final done = Completer<void>();
    _inFlight = done.future;
    return () async {
      AlarmSaveOutcome out;
      try {
        out = await send(snapshot);
      } catch (e) {
        out = AlarmSaveOutcome(
          AlarmSaveStatus.failed,
          persisted: false,
          error: e,
        );
      } finally {
        _sending = false;
        _inFlight = null;
      }
      if (out.persisted) _saved = List.unmodifiable(snapshot);
      _outcome = out;
      _notify();
      done.complete();
      return out;
    }();
  }

  // ── internals ──────────────────────────────────────────────────────────────

  void _edit(int weekday, AlarmScheduleEntry Function(AlarmScheduleEntry) f) {
    final i = _check(weekday);
    final next = f(_entries[i]);
    if (next == _entries[i]) return;
    _entries = List.of(_entries)..[i] = next;
    _outcome = null;
    _notify();
  }

  static int _check(int weekday) {
    if (weekday < 0 || weekday > 6) {
      throw ArgumentError.value(weekday, 'weekday', '0=Mon..6=Sun');
    }
    return weekday;
  }

  static void _checkWindow(int minutes) {
    if (!isValidWakeWindow(minutes)) {
      throw ArgumentError.value(
        minutes,
        'minutes',
        '0 (off) or $kWakeWindowStepMinutes..$kWakeWindowMaxMinutes in '
            '$kWakeWindowStepMinutes-minute steps',
      );
    }
  }

  /// A save can finish after its screen is gone (the user chose Leave).
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
