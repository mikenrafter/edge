// snooze_controller.dart — the dismiss window, the pending snooze and the
// app-driven re-alarm loop. Everything is injected; nothing here can reach the
// band's native alarm (no arm, no disable: AGENTS 3.15, and arming is taxing).
//
// STUB (red phase): bodies throw. Pinned by
// test/alarm_snooze/snooze_controller_test.dart.
//
// Intended behaviour:
//   [onAlarmStopped]  the native wake alarm stopped. error: log only. Probe
//                     [confirmedWake] (a probe that throws reads "not
//                     confirmed": the wearer is woken, never assumed up);
//                     confirmed: nothing more. userDoubleTap with
//                     requiredTaps == 1: dismissed at once. userDoubleTap
//                     otherwise opens the window (the stopping tap is #1).
//                     expired: snooze at once.
//   [onBandDoubleTap] a band double tap while [consumesDoubleTaps]. The n-th
//                     tap dismisses early: alarm_acknowledged evidence + the
//                     alarm.dismiss.confirm slot. A tap within
//                     [kStopTapDedupe] after a native stop is that stop's own
//                     tap echoed as a gesture event, not tap #2.
//   snooze            plays alarm.snooze.confirm, persists
//                     SnoozeState(count, now + minutes), publishes [status].
//   [tick]            the 30 s keep-alive: closes a window that ended, checks
//                     [confirmedWake] (confirmed during a snooze cancels it and
//                     plays alarm.snooze.cancelled), and plays a due re-alarm.
//                     A one-shot timer from [scheduler] does the same on time
//                     while the process is alive; tick is the backstop.
//   re-alarm          plays alarm.snooze.realarm with
//                     SnoozeSchedule(cap).reAlarmNotes(count); listening window
//                     from the pattern's start until [settings.window] after it
//                     finished. n taps dismiss; fewer snoozes again (count+1,
//                     now + minutes). A failed delivery does not count: the
//                     re-alarm stays due and is retried next tick. Past the cap
//                     it keeps going every interval, unescalated, until
//                     dismissed or a wake is confirmed.
//   [resume]          reads the store after a restart; a re-alarm however late
//                     still plays (it is an alarm).
//   [dispose]         cancels every timer; nothing runs or plays afterwards,
//                     including a probe or delivery that finishes late.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../gestures/pattern_transcript.dart';
import '../../wake/wake_confirmation.dart';
import 'alarm_stop_policy.dart';
import 'snooze_settings.dart';

/// The haptic slots (also in lib/haptics/builtin_patterns.dart's keys).
/// Played through [SnoozeHapticPlay] by key; the re-alarm carries its notes.
typedef SnoozeHapticPlay = Future<bool> Function(
  String slotKey, {
  List<PatternEntry>? notes,
});

typedef SnoozeEvidence = Future<void> Function(
    WakeEvidenceKind kind, DateTime at);

abstract interface class SnoozeTimer {
  void cancel();
}

/// A one-shot timer; the default is dart:async's.
typedef SnoozeScheduler = SnoozeTimer Function(
    Duration after, void Function() fire);

SnoozeTimer defaultSnoozeScheduler(Duration after, void Function() fire) =>
    throw UnimplementedError();

/// A band double tap within this long after a native stop is that stop's own
/// tap echoed as a gesture event, and does not count as another.
const Duration kStopTapDedupe = Duration(milliseconds: 750);

enum SnoozePhase { idle, window, snoozed, reAlarming }

class SnoozeStatus {
  const SnoozeStatus(this.phase, {this.until, this.snoozeCount = 0});
  static const SnoozeStatus idle = SnoozeStatus(SnoozePhase.idle);

  final SnoozePhase phase;

  /// While snoozed: when the re-alarm is due.
  final DateTime? until;

  /// Snoozes set so far in this chain.
  final int snoozeCount;

  @override
  bool operator ==(Object other) =>
      other is SnoozeStatus &&
      other.phase == phase &&
      other.until == until &&
      other.snoozeCount == snoozeCount;

  @override
  int get hashCode => Object.hash(phase, until, snoozeCount);
}

class SnoozeController {
  SnoozeController({
    required this.now,
    required this.play,
    required this.confirmedWake,
    required this.recordEvidence,
    required this.store,
    required this.settings,
    this.scheduler = defaultSnoozeScheduler,
    this.log,
  });

  final DateTime Function() now;
  final SnoozeHapticPlay play;

  /// The double wake confirmation exists for the current sleep block.
  final Future<bool> Function() confirmedWake;
  final SnoozeEvidence recordEvidence;
  final SnoozeStore store;
  final SnoozeSettings Function() settings;
  final SnoozeScheduler scheduler;
  final void Function(String line)? log;

  /// What Home shows. Not idle while a window, a snooze or a re-alarm is live.
  ValueListenable<SnoozeStatus> get status => throw UnimplementedError();

  /// A band double tap belongs to the dismiss window or the re-alarm right
  /// now, so the wearer's gesture actions must not run for it.
  bool get consumesDoubleTaps => throw UnimplementedError();

  /// The native wake alarm stopped for [cause], at [at] (default now).
  Future<void> onAlarmStopped(AlarmStopCause cause, {DateTime? at}) =>
      throw UnimplementedError();

  /// A band double tap (gesture event 14) at [at]; only meaningful while
  /// [consumesDoubleTaps].
  Future<void> onBandDoubleTap(DateTime at) => throw UnimplementedError();

  /// The keep-alive tick (every ~30 s) and the backstop for the timers.
  Future<void> tick() => throw UnimplementedError();

  /// "I'm up": dismisses a window, a snooze or a re-alarm.
  Future<void> imUp() => throw UnimplementedError();

  /// Load a persisted snooze after a restart.
  Future<void> resume() => throw UnimplementedError();

  void dispose() => throw UnimplementedError();
}
