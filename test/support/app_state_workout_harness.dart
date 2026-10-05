// Shared helpers for the 8AJ seam 4 (WorkoutController) tests. Everything goes
// through AppState's public and @visibleForTesting surface, so the same files
// serve the characterization tests before the move and after it.
//
// What the area talks to, and how the tests see it:
//   - the lock-screen / Dynamic Island activities, the display wake hold, the
//     geolocator plugin and the App-Group widget flags are platform channels;
//     [PlatformSpies] answers them and records every call.
//   - the 1 Hz workout tick and the 20 s breathing recompute are periodic
//     timers; [TimerProbe] replaces periodic timers made inside its zone with
//     ones the test fires by hand (so a tick is one explicit call, never a
//     wall-clock race) and records their period and whether they were
//     cancelled. One-shot timers still run for real.
//   - the session row, the live tally row and the breathing history are real
//     rows in a LocalDb over sqflite_ffi (deriveDbSetUp).
//   - the heart rate is set the way the existing tick tests set it: straight
//     on the engine's DeviceState with a connected link.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gps/screen_wake.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'app_state_derive_harness.dart' show settleMs;

export 'app_state_derive_harness.dart'
    show deriveDbSetUp, deriveDbTearDown, settleMs, until, TickCounter, TimerSpy;

int nowMs() => DateTime.now().millisecondsSinceEpoch;

/// One platform call the area made.
typedef PCall = ({String method, Object? args});

/// Answers (and records) the platform channels the workout / breathing area
/// reaches. Install in setUp, [dispose] in tearDown.
class PlatformSpies {
  PlatformSpies({
    this.locationServices = true,
    this.permission = 2, // LocationPermission.whileInUse
  }) {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    ScreenWake.resetForTest();
    ScreenWake.platformOverride = 'android';
    m.setMockMethodCallHandler(_live, (c) async {
      liveActivity.add((method: c.method, args: c.arguments));
      return null;
    });
    m.setMockMethodCallHandler(_breath, (c) async {
      breathingActivity.add((method: c.method, args: c.arguments));
      return null;
    });
    m.setMockMethodCallHandler(_tracking, (c) async {
      tracking.add((method: c.method, args: c.arguments));
      return c.method == 'keepAwake' ? true : null;
    });
    m.setMockStreamHandler(
      _geoUpdates,
      MockStreamHandler.inline(
        onListen: (args, sink) {
          geoListens++;
          _geoSink = sink;
        },
        onCancel: (args) {
          geoCancels++;
          _geoSink = null;
        },
      ),
    );
    m.setMockMethodCallHandler(_geo, (c) async {
      geolocator.add((method: c.method, args: c.arguments));
      if (geoGate != null) await geoGate!.future;
      switch (c.method) {
        case 'isLocationServiceEnabled':
          return locationServices;
        case 'checkPermission':
        case 'requestPermission':
          return permission;
      }
      return null;
    });
    m.setMockMethodCallHandler(_home, (c) async {
      final a = c.arguments is Map ? (c.arguments as Map) : const {};
      if (c.method == 'getWidgetData') {
        return widgetFlags[a['id']] ?? a['defaultValue'];
      }
      if (c.method == 'saveWidgetData') {
        widgetFlags[a['id'] as String] = a['data'];
        return true;
      }
      return null;
    });
    m.setMockMethodCallHandler(_ios, (c) async => null);
    m.setMockMethodCallHandler(_health, (c) async {
      health.add((method: c.method, args: c.arguments));
      return c.method == 'hasPermissions' ? false : true;
    });
  }

  static const _live = MethodChannel('openstrap/live_activity');
  static const _breath = MethodChannel('openstrap/breathing_live_activity');
  static const _tracking = MethodChannel('openstrap/edge_tracking');
  static const _geo = MethodChannel('flutter.baseflow.com/geolocator');
  static const _home = MethodChannel('home_widget');
  static const _ios = MethodChannel('openstrap/ios_config');
  static const _geoUpdates = EventChannel('flutter.baseflow.com/geolocator_updates');
  static const _health = MethodChannel('flutter_health');

  bool locationServices;
  int permission;

  /// When set, every geolocator method call waits for it (a permission dialog
  /// that is still open).
  Completer<void>? geoGate;

  /// Position-stream listens / cancels the app made, and whether it is
  /// listening now.
  int geoListens = 0;
  int geoCancels = 0;
  MockStreamHandlerEventSink? _geoSink;
  bool get geoListening => _geoSink != null;

  /// Deliver one GPS fix to whoever listens to the position stream.
  void emitFix(double lat, double lng,
      {double accuracy = 5, double? speed = 2.5, int? tsMs}) {
    _geoSink?.success(<String, dynamic>{
      'latitude': lat,
      'longitude': lng,
      'timestamp': tsMs ?? nowMs(),
      'accuracy': accuracy,
      'altitude': 10.0,
      'heading': 0.0,
      'speed': speed,
      'speed_accuracy': 1.0,
    });
  }

  final liveActivity = <PCall>[];
  final breathingActivity = <PCall>[];
  final tracking = <PCall>[];
  final geolocator = <PCall>[];

  /// What reached the Health plugin (Apple Health / Health Connect export).
  final health = <PCall>[];

  /// The App-Group flags (`end_session`, `end_breathing_session`).
  final widgetFlags = <String, Object?>{};

  List<String> get liveActivityMethods => [for (final c in liveActivity) c.method];
  List<String> get breathingMethods =>
      [for (final c in breathingActivity) c.method];

  /// The display-wake requests that reached the platform, in order.
  List<bool> get keepAwake => [
        for (final c in tracking)
          if (c.method == 'keepAwake') (c.args as Map)['on'] as bool,
      ];

  void dispose() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final c in [_live, _breath, _tracking, _geo, _home, _ios, _health]) {
      m.setMockMethodCallHandler(c, null);
    }
    m.setMockStreamHandler(_geoUpdates, null);
    ScreenWake.resetForTest();
    ScreenWake.platformOverride = null;
  }
}

/// A periodic timer the test fires by hand.
class FakePeriodic implements Timer {
  FakePeriodic(this.period, this._f);
  final Duration period;
  final void Function(Timer) _f;
  bool cancelled = false;
  int fired = 0;

  /// Run the callback once, as the timer would.
  void fire() {
    if (cancelled) throw StateError('fired a cancelled timer');
    fired++;
    _f(this);
  }

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => fired;
}

/// Periodic timers made inside [run] are [FakePeriodic]s; one-shots are real
/// (and recorded). The two lists keep creation order.
class TimerProbe {
  final periodics = <FakePeriodic>[];
  final oneShots = <Duration>[];

  /// The periodic timers still active, oldest first.
  List<FakePeriodic> get livePeriodics =>
      [for (final t in periodics) if (!t.cancelled) t];

  /// The still-active periodic timers with this period.
  List<FakePeriodic> active(Duration period) =>
      [for (final t in livePeriodics) if (t.period == period) t];

  ZoneSpecification get spec => ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, d, f) {
          final t = FakePeriodic(d, f);
          periodics.add(t);
          return t;
        },
        createTimer: (self, parent, zone, d, f) {
          oneShots.add(d);
          return parent.createTimer(zone, d, f);
        },
      );

  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneSpecification: spec);
}

const Duration kTick = Duration(seconds: 1);
const Duration kBreathRecompute = Duration(seconds: 20);

/// A connected band reporting [hr] right now (null = no reading). The same
/// shape the existing tick tests use.
void setLiveHr(AppState app, int? hr, {int ageMs = 0}) {
  app.device.connection = 'connected';
  app.device.liveHr = hr;
  app.device.liveHrAt = hr == null ? null : nowMs() - ageMs;
}

/// The stored session row [id], or null.
Future<Map<String, dynamic>?> sessionRow(String id) => LocalDb.session(id);

/// Wait (up to [within]) for the live row startWorkout writes fire-and-forget
/// to land, so a test that disposes without stopping cannot have the database
/// closed under that write when the machine is slow.
Future<void> sessionLanded(String id,
    {Duration within = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(within);
  while (DateTime.now().isBefore(end)) {
    if (await LocalDb.session(id) != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Same for the tally snapshot a tick dispatches.
Future<void> tallyLanded(String id,
    {Duration within = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(within);
  while (DateTime.now().isBefore(end)) {
    if (await LocalDb.liveWorkoutTally(id) != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Stop whatever the test left running and let the fire-and-forget writes
/// land before the database is closed.
Future<void> finish(AppState app, {bool dispose = true}) async {
  if (app.activeWorkout != null) await app.stopWorkout();
  if (app.breathingActive) await app.stopBreathingSession();
  if (app.breathingWindowOpen) await app.closeBreathingWindow();
  await settleMs(250);
  if (dispose) app.dispose();
}

/// A walking-shaped accel frame (see test/live_step_runs_test.dart): 2 Hz gait
/// at 0.45 g over 1 g, phase-continuous across [frameIndex].
List<double> walkFrame(int frameIndex, int samples) => [
      for (var i = 0; i < samples; i++)
        1.0 +
            0.45 *
                math.sin(2 * math.pi * 2.0 *
                    ((frameIndex * samples + i) / 100.0)),
    ];

/// A repo that records what breathing hands it and answers on cue.
class BreathRepo extends LocalRepository {
  final coherenceCalls = <({List<String> frames, double? pacedHz})>[];
  Map<String, dynamic> result = {'ok': true, 'score': 72.0, 'confidence': 0.8};
  Object? throwsOnCoherence;
  Completer<void>? gate;

  @override
  Future<Map<String, dynamic>> breathingCoherence(List<String> records,
      {double? pacedHz}) async {
    coherenceCalls.add((frames: [...records], pacedHz: pacedHz));
    if (gate != null) await gate!.future;
    if (throwsOnCoherence != null) throw throwsOnCoherence!;
    return result;
  }

  @override
  Future<Map<String, dynamic>> spotCheck(List<String> records) async =>
      {'ok': true, 'rmssd': records.length.toDouble()};

  @override
  Future<Map<String, dynamic>> getToday() async => const {};
}
