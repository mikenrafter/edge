// Shared fakes for the main-alarm snooze tests. Nothing here touches BLE,
// SQLite or a real timer: the controller is driven through its injected seams.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart' show pumpEventQueue;
import 'package:openstrap_edge/alarm/snooze/alarm_stop_policy.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/wake/wake_confirmation.dart';

import '../support/wake_fakes.dart' show TestClock;

/// 06:00 on the day of the alarm.
final DateTime kT0 = DateTime(2026, 10, 7, 6, 0);

class MemorySnoozeStore implements SnoozeStore {
  MemorySnoozeStore({this.state, SnoozeSettings? settings})
      : settings = settings ?? const SnoozeSettings();

  SnoozeSettings settings;
  SnoozeState? state;
  SnoozeWindow? window;

  /// Every saveState call, in order (null = a clear).
  final List<SnoozeState?> stateWrites = [];

  @override
  Future<SnoozeSettings> loadSettings() async => settings;
  @override
  Future<void> saveSettings(SnoozeSettings s) async => settings = s;
  @override
  Future<SnoozeState?> loadState() async => state;
  @override
  Future<void> saveState(SnoozeState? s) async {
    stateWrites.add(s);
    state = s;
  }

  @override
  Future<SnoozeWindow?> loadWindow() async => window;
  @override
  Future<void> saveWindow(SnoozeWindow? w) async => window = w;
}

class FakeTimer implements SnoozeTimer {
  FakeTimer(this.after, this._fire);
  final Duration after;
  final void Function() _fire;
  bool cancelled = false;
  bool fired = false;

  @override
  void cancel() => cancelled = true;

  void fire() {
    fired = true;
    _fire();
  }
}

class FakeScheduler {
  final List<FakeTimer> timers = [];

  SnoozeTimer call(Duration after, void Function() fire) {
    final t = FakeTimer(after, fire);
    timers.add(t);
    return t;
  }

  Iterable<FakeTimer> get live => timers.where((t) => !t.cancelled && !t.fired);
}

class Play {
  Play(this.slot, this.notes, this.at);
  final String slot;
  final List<PatternEntry>? notes;
  final DateTime at;
}

/// One controller over fakes. Defaults: 2 taps, 4 s window, 5 min snooze, cap 6.
class SnoozeRig {
  SnoozeRig({this.settings = const SnoozeSettings(), SnoozeState? stored})
      : clock = TestClock(kT0),
        store = MemorySnoozeStore(state: stored) {
    controller = build();
  }

  final TestClock clock;
  SnoozeSettings settings;
  final MemorySnoozeStore store;
  final FakeScheduler scheduler = FakeScheduler();
  final List<Play> plays = [];
  final List<(WakeEvidenceKind, DateTime)> evidence = [];
  final List<String> logs = [];

  /// The double wake confirmation exists.
  bool confirmed = false;

  /// The probe throws / waits on a gate.
  Object? probeThrows;
  Completer<bool>? probeGate;

  /// The band takes the haptic (false: the delivery is refused).
  bool playOk = true;

  /// Holds a delivery open until completed.
  Completer<void>? playGate;

  late SnoozeController controller;

  /// A fresh controller over the same fakes and store: a restart.
  SnoozeController build() => SnoozeController(
        now: clock.call,
        play: (slot, {notes, void Function()? onFirstWrite}) async {
          plays.add(Play(slot, notes, clock.now));
          final gate = playGate;
          if (gate != null) await gate.future;
          return playOk;
        },
        confirmedWake: () async {
          final g = probeGate;
          if (g != null) return g.future;
          if (probeThrows != null) throw probeThrows!;
          return confirmed;
        },
        recordEvidence: (k, at) async => evidence.add((k, at)),
        store: store,
        settings: () => settings,
        scheduler: scheduler.call,
        log: logs.add,
      );

  List<String> get slots => [for (final p in plays) p.slot];
  List<Play> playsOf(String slot) => [for (final p in plays) if (p.slot == slot) p];

  Future<void> settle() => pumpEventQueue();
  void advance(Duration d) => clock.advance(d);

  Future<void> stop(AlarmStopCause cause) =>
      controller.onAlarmStopped(cause, at: clock.now);

  /// A band double tap [after] the current instant.
  Future<void> tapAfter(Duration after) {
    advance(after);
    return controller.onBandDoubleTap(clock.now);
  }
}

const kSlotSnoozeConfirm = kAlarmSnoozeConfirmKey;
const kSlotDismissConfirm = kAlarmDismissConfirmKey;
const kSlotCancelled = kAlarmSnoozeCancelledKey;
const kSlotReAlarm = kAlarmReAlarmKey;
