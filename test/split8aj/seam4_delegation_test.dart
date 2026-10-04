// 8AJ seam 4: every AppState member in the workout / breathing area is still
// there with its original type, the helper types other code reaches through
// app_state.dart are still exported from it, and the collaborators the area is
// wired to keep their shape. The annotations are compile-time checks of the
// public surface; the source guard lists the names and the callbacks other
// controllers take from this area. Passes before and after the
// WorkoutController move.
//
// Public AppState members in scope today (name -> kind):
//   activeWorkout            LiveWorkoutState?  mutable field (screens + tests assign)
//   startWorkout             void ({targetKcal, workoutId, type})
//   stopWorkout              Future<void>
//   deleteWorkout            Future<void> (String)
//   workoutStepsMeasured     int? getter
//   liveZone                 int? getter
//   liveDistanceKm           double? getter
//   routeTracking            bool getter
//   routeTracker             RouteTracker? getter
//   routeLocationIssue       GpsPermissionStatus? mutable field
//   retryRouteTracking       Future<void>
//   maybeFinishFromLiveActivity            Future<void>
//   maybeStopBreathingFromLiveActivity     Future<void>
//   liveStepsAbsentReason    String? getter (reads activeWorkout and the pedometer)
//   exportWorkoutToHealth    Future<bool> (String?) (forwards to HealthExporter)
//   breathingActive / breathingWindowOpen  bool mutable fields
//   breathingPattern         BreathPattern mutable field
//   breathingStartedAt / breathingTarget   DateTime? / Duration? getters
//   breathingResult          Map<String, dynamic>? mutable field
//   breathingError           String? mutable field
//   openBreathingWindow / closeBreathingWindow / startBreathingSession /
//   stopBreathingSession     Future<void>
//   breathingHistory         Future<List<Map<String, dynamic>>> ({limit})
//   buzzBreathPhase / buzzSessionComplete  void
// @visibleForTesting: debugTickWorkout, debugReconcileOrphanedLiveWorkout,
//   debugArmOwnedTimers (also arms the backfill and alarm timers),
//   debugFinalizeLivePedometer / debugFeedLiveAccel (pedometer, which stays).
// Shared with other concerns (stay on AppState, the controller is handed them):
//   zoneAlertTargetZone (a pref), liveHr, isConnected, device, repo, user,
//   healthSyncEnabled, bumpInsights, forceResync, logLines, engine.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gps/gps_source.dart';
import 'package:openstrap_edge/gps/route_tracker.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every member in the workout and breathing area is present with its '
      'original type', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final LiveWorkoutState? active = app.activeWorkout;
    final void Function({double targetKcal, String? workoutId, String type})
        start = app.startWorkout;
    final Future<void> Function() stop = app.stopWorkout;
    final Future<void> Function(String) delete = app.deleteWorkout;
    final int? steps = app.workoutStepsMeasured;
    final int? zone = app.liveZone;
    final double? km = app.liveDistanceKm;
    final bool tracking = app.routeTracking;
    final RouteTracker? tracker = app.routeTracker;
    final GpsPermissionStatus? issue = app.routeLocationIssue;
    final Future<void> Function() retry = app.retryRouteTracking;
    final Future<void> Function() finishFromLa = app.maybeFinishFromLiveActivity;
    final Future<void> Function() stopBreathFromLa =
        app.maybeStopBreathingFromLiveActivity;
    final String? absent = app.liveStepsAbsentReason;
    final Future<bool> Function(String?) export = app.exportWorkoutToHealth;
    final bool breathing = app.breathingActive;
    final bool window = app.breathingWindowOpen;
    final BreathPattern pattern = app.breathingPattern;
    final DateTime? startedAt = app.breathingStartedAt;
    final Duration? target = app.breathingTarget;
    final Map<String, dynamic>? result = app.breathingResult;
    final String? error = app.breathingError;
    final Future<void> Function() open = app.openBreathingWindow;
    final Future<void> Function() close = app.closeBreathingWindow;
    final Future<void> Function({BreathPattern? pattern, Duration? target})
        startBreathing = app.startBreathingSession;
    final Future<void> Function() stopBreathing = app.stopBreathingSession;
    final Future<List<Map<String, dynamic>>> Function({int limit}) history =
        app.breathingHistory;
    final void Function(BreathPhaseKind) phase = app.buzzBreathPhase;
    final void Function() complete = app.buzzSessionComplete;
    final void Function() tick = app.debugTickWorkout;
    final Future<void> Function() reconcile =
        app.debugReconcileOrphanedLiveWorkout;
    final void Function() arm = app.debugArmOwnedTimers;
    expect([
      start, stop, delete, retry, finishFromLa, stopBreathFromLa, export,
      open, close, startBreathing, stopBreathing, history, phase, complete,
      tick, reconcile, arm,
    ], everyElement(isNotNull));
    expect([active, steps, zone, km, tracker, issue, absent, startedAt,
      target, result, error], everyElement(isNull));
    expect([tracking, breathing, window], everyElement(isFalse));
    expect(pattern, same(kBreathPatterns.first));
  });

  test('the field-style members are assignable (screens and tests set them)',
      () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.activeWorkout = LiveWorkoutState(
        startTime: DateTime.now(), targetKcal: 100, type: 'strength');
    app.activeWorkout = null;
    app.routeLocationIssue = GpsPermissionStatus.denied;
    app.routeLocationIssue = null;
    app.breathingActive = true;
    app.breathingActive = false;
    app.breathingWindowOpen = true;
    app.breathingWindowOpen = false;
    app.breathingPattern = kBreathPatterns.last;
    app.breathingResult = {'ok': true};
    app.breathingError = 'x';
    expect(app.breathingPattern, same(kBreathPatterns.last));
  });

  test('LiveWorkoutState is still reachable through app_state.dart and keeps '
      'the surface the screens and the tally restore read', () {
    final w = LiveWorkoutState(
      startTime: DateTime.now(),
      targetKcal: 250,
      workoutId: 'w4-d',
      type: 'running',
    );
    expect(w.zoneSeconds, hasLength(6));
    expect(w.maxHrSeen, 0);
    expect(w.caloriesOrNull, isNull);
    expect(w.strain, isNull);
    expect(w.currentHr, isNull);
    expect(w.elapsed, Duration.zero);
    expect(w.idleWatch, isNotNull);
    expect(w.perMinuteHr(), isEmpty);
    expect(w.zoneMinutes(), hasLength(5));
    w.restoreTally(
      minuteHr: const [100.0, 110.0],
      zoneSecondsIn: const [0, 60, 60, 0, 0, 0],
      secondsByBpm: const {100: 60, 110: 60},
      maxHrSeenIn: 111,
    );
    expect(w.maxHrSeen, 111);
    expect(w.perMinuteHr(), [100.0, 110.0]);
  });

  group('source guard', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();

    test('AppState still declares every public name in the area', () {
      for (final name in const [
        'activeWorkout', 'startWorkout', 'stopWorkout', 'deleteWorkout',
        'workoutStepsMeasured', 'liveZone', 'liveDistanceKm', 'routeTracking',
        'routeTracker', 'routeLocationIssue', 'retryRouteTracking',
        'maybeFinishFromLiveActivity', 'maybeStopBreathingFromLiveActivity',
        'liveStepsAbsentReason', 'exportWorkoutToHealth', 'breathingActive',
        'breathingWindowOpen', 'breathingPattern', 'breathingStartedAt',
        'breathingTarget', 'breathingResult', 'breathingError',
        'openBreathingWindow', 'closeBreathingWindow',
        'startBreathingSession', 'stopBreathingSession', 'breathingHistory',
        'buzzBreathPhase', 'buzzSessionComplete', 'debugTickWorkout',
        'debugReconcileOrphanedLiveWorkout', 'debugArmOwnedTimers',
      ]) {
        expect(RegExp('\\b$name\\b\\s*(=>|\\(|;|=|\\{)|get $name\\b')
            .hasMatch(src), isTrue, reason: 'AppState lost `$name`');
      }
    });

    // The wiring may move into a controller's own file with the seam, so the
    // checks below read every file under lib/state/ and look for the tokens
    // that make the wiring, not for one formatting of it.
    final all = [
      for (final f in Directory('lib/state').listSync().whereType<File>())
        if (f.path.endsWith('.dart')) f.readAsStringSync(),
    ].join('\n');

    test('the callbacks other controllers take from this area are wired at '
        'construction', () {
      // LiveStreamController: the workout's type and "breathing".
      expect(RegExp(r'activeWorkoutType:\s*\(\)\s*=>').hasMatch(src), isTrue);
      expect(RegExp(r'breathing:\s*\(\)\s*=>').hasMatch(src), isTrue);
      // DeriveCoordinator: a live session holds the artifact warmer.
      expect(
          RegExp(r'warmHeld:\s*\(\)\s*=>[^,]*_liveSessionActive').hasMatch(src),
          isTrue);
      // GestureController: the band double tap's workout toggle.
      expect(RegExp(r'onWorkoutToggle:\s*_toggleWorkoutFromGesture').hasMatch(src),
          isTrue);
      // EcgController: "workout" beats "breathing" as the busy reason.
      final busy = RegExp(r"busyReason:[\s\S]{0,260}?'workout'[\s\S]{0,160}?'breathing'")
          .hasMatch(src);
      expect(busy, isTrue);
    });

    test('the feature-session predicate is still workout, breathing session '
        'or window, ECG capture (the VACUUM gate and the warmer hold read it)',
        () {
      final at = src.indexOf('bool get _liveSessionActive');
      expect(at, greaterThan(0));
      final body = src.substring(at, at + 260);
      for (final term in const [
        'activeWorkout != null',
        'breathingActive',
        'breathingWindowOpen',
        'isCapturing',
      ]) {
        expect(body, contains(term));
      }
    });

    test('the derive scheduler\'s workout hold is taken at every start path '
        'and given back at every end path', () {
      final holds = 'setWorkoutActive(true)'.allMatches(all).length;
      final releases = 'setWorkoutActive(false)'.allMatches(all).length;
      expect(holds, 2, reason: 'startWorkout and the reconcile resume');
      expect(releases, 2, reason: 'stopWorkout and the delete teardown');
    });

    test('_dispatchBandAlert stays in AppState (older source guards read its '
        'body there); the zone-crossing alert and the breathing cues both '
        'still name their rules', () {
      expect(src, contains('Future<AlertDeliveryOutcome> _dispatchBandAlert('));
      expect(RegExp(r"_dispatchBandAlert\('zone'\)|dispatchBandAlert\('zone'\)")
          .hasMatch(all), isTrue);
      expect(RegExp(r"ispatchBandAlert\('breath', pattern: pattern\)")
          .hasMatch(all), isTrue);
      expect(RegExp(r"ispatchBandAlert\('breath', pattern: 4\)").hasMatch(all),
          isTrue);
    });
  });
}
