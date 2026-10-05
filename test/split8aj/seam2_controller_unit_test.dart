// 8AJ seam 2: LiveStreamController in isolation, with fake collaborators. The
// same behaviours are pinned through AppState in the characterization tests;
// these prove the controller stands on its own and never reaches for AppState.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/live_stream_buffer.dart';
import 'package:openstrap_edge/state/live_stream_controller.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

import 'support/live_harness.dart';

/// A magnitude-only IMU frame, as AppState's debugFeedLiveAccel builds one.
proto.ImuFrame imuFrameOf(List<double> mags) => proto.ImuFrame(0, 0, mags);

/// A host for the controller: every collaborator is a recorder.
class FakeHost {
  bool background = false;
  String? workoutType;
  bool breathing = false;
  int reconciles = 0;
  int clearAndReconciles = 0;
  int notifies = 0;
  Completer<void>? reconcileGate;
  final buffer = LiveStreamBuffer();

  late final LiveStreamController controller = LiveStreamController(
    buffer: buffer,
    isBackground: () => background,
    activeWorkoutType: () => workoutType,
    breathing: () => breathing,
    reconcile: () async {
      reconciles++;
      await reconcileGate?.future;
    },
    clearRadioFallbackAndReconcile: () async => clearAndReconciles++,
    notify: () => notifies++,
  );
}

void main() {
  test('no owner at rest; foreground alone owns nothing on gen5', () {
    final h = FakeHost();
    final o = h.controller.owners();
    expect(o.visibleLiveHrView, isFalse);
    expect(o.activeWorkout, isFalse);
    expect(o.foregroundGaitWorkout, isFalse);
    expect(o.breathing, isFalse);
    expect(o.movementSampling, isFalse);
    expect(o.passiveStrapSteps, isFalse);
    expect(o.developerLiveFeed, isFalse);
    expect(o.foreground, isTrue);
    h.background = true;
    expect(h.controller.owners().foreground, isFalse);
  });

  group('owners', () {
    test('a workout owns HR; a gait workout owns IMU only in the foreground',
        () {
      final h = FakeHost()..workoutType = 'running';
      var o = h.controller.owners();
      expect(o.activeWorkout, isTrue);
      expect(o.foregroundGaitWorkout, isTrue);
      h.background = true;
      o = h.controller.owners();
      expect(o.activeWorkout, isTrue);
      expect(o.foregroundGaitWorkout, isFalse);
      h.background = false;
      h.workoutType = 'yoga';
      o = h.controller.owners();
      expect(o.activeWorkout, isTrue);
      expect(o.foregroundGaitWorkout, isFalse);
    });

    test('overlapping owners all show at once and release independently', () {
      final h = FakeHost()
        ..workoutType = 'run'
        ..breathing = true;
      h.controller
        ..retainLiveHrView()
        ..setMovementSamplingWindow(true);
      var o = h.controller.owners();
      expect(
        [
          o.visibleLiveHrView,
          o.activeWorkout,
          o.breathing,
          o.movementSampling,
        ],
        everyElement(isTrue),
      );
      h.workoutType = null;
      h.controller.releaseLiveHrView();
      o = h.controller.owners();
      expect(o.visibleLiveHrView, isFalse);
      expect(o.activeWorkout, isFalse);
      expect(o.breathing, isTrue);
      expect(o.movementSampling, isTrue);
      h.controller.setMovementSamplingWindow(false);
      h.breathing = false;
      expect(h.controller.owners().breathing, isFalse);
      expect(h.controller.owners().movementSampling, isFalse);
    });

    test('a mounted live-HR view and the dev feed do not hold the stream '
        'behind a locked screen', () async {
      final h = FakeHost();
      h.controller.retainLiveHrView();
      await h.controller.startLiveFeed('');
      expect(h.controller.owners().visibleLiveHrView, isTrue);
      expect(h.controller.owners().developerLiveFeed, isTrue);
      h.background = true;
      expect(h.controller.owners().visibleLiveHrView, isFalse);
      expect(h.controller.owners().developerLiveFeed, isFalse);
      // The flags themselves survive backgrounding.
      h.background = false;
      expect(h.controller.owners().visibleLiveHrView, isTrue);
      expect(h.controller.isLiveFeedOn(''), isTrue);
    });

    test('viewers are counted: two retains need two releases; a stray '
        'release never goes negative', () {
      final h = FakeHost();
      h.controller
        ..retainLiveHrView()
        ..retainLiveHrView()
        ..releaseLiveHrView();
      expect(h.controller.owners().visibleLiveHrView, isTrue);
      h.controller
        ..releaseLiveHrView()
        ..releaseLiveHrView();
      expect(h.controller.owners().visibleLiveHrView, isFalse);
      h.controller.retainLiveHrView();
      expect(h.controller.owners().visibleLiveHrView, isTrue);
    });

    test('retain and release nudge once each and never notify', () {
      final h = FakeHost();
      h.controller.retainLiveHrView();
      expect(h.reconciles, 1);
      h.controller.releaseLiveHrView();
      expect(h.reconciles, 2);
      expect(h.notifies, 0);
    });

    test('the movement window nudges only on a real change and never notifies',
        () {
      final h = FakeHost();
      h.controller.setMovementSamplingWindow(false);
      expect(h.reconciles, 0);
      h.controller.setMovementSamplingWindow(true);
      h.controller.setMovementSamplingWindow(true);
      expect(h.reconciles, 1);
      h.controller.setMovementSamplingWindow(false);
      expect(h.reconciles, 2);
      expect(h.notifies, 0);
    });

    test('nudge is fire-and-forget: it returns while the engine is busy', () {
      final h = FakeHost()..reconcileGate = Completer<void>();
      h.controller.nudge();
      expect(h.reconciles, 1);
      h.reconcileGate!.complete();
    });
  });

  group('developer live feed', () {
    test('start notifies once per actual change and always reconciles', () async {
      final h = FakeHost();
      expect(h.controller.isLiveFeedOn(''), isFalse);
      await h.controller.startLiveFeed('');
      await h.controller.startLiveFeed('');
      expect(h.controller.isLiveFeedOn(''), isTrue);
      expect(h.notifies, 1);
      expect(h.clearAndReconciles, 2, reason: 'idempotent, but re-asserted');
      expect(h.reconciles, 0);
    });

    test('stop notifies once, clears before the first await, then reconciles',
        () async {
      final h = FakeHost()..reconcileGate = Completer<void>();
      await h.controller.startLiveFeed('');
      final done = h.controller.stopLiveFeed('');
      // Cleared synchronously, even though the reconcile is still pending.
      expect(h.controller.isLiveFeedOn(''), isFalse);
      expect(h.notifies, 2);
      expect(h.reconciles, 1);
      h.reconcileGate!.complete();
      await done;
      await h.controller.stopLiveFeed('');
      expect(h.notifies, 2);
      expect(h.reconciles, 1, reason: 'Stop without Start writes nothing');
    });

    test('a paired sensor id has no feed', () async {
      final h = FakeHost();
      await h.controller.startLiveFeed('aa:bb');
      expect(h.controller.isLiveFeedOn('aa:bb'), isFalse);
      expect(h.controller.isLiveFeedOn(''), isFalse);
      expect(h.notifies, 0);
      expect(h.clearAndReconciles, 0);
      await h.controller.stopLiveFeed('aa:bb');
      expect(h.reconciles, 0);
    });

    test('a throwing reconcile on stop still leaves the flag cleared', () async {
      final h = FakeHost();
      final c = LiveStreamController(
        buffer: h.buffer,
        isBackground: () => false,
        activeWorkoutType: () => null,
        breathing: () => false,
        reconcile: () async => throw StateError('band refused'),
        clearRadioFallbackAndReconcile: () async {},
        notify: () => h.notifies++,
      );
      await c.startLiveFeed('');
      await expectLater(c.stopLiveFeed(''), throwsStateError);
      expect(c.isLiveFeedOn(''), isFalse);
      expect(c.owners().developerLiveFeed, isFalse);
    });
  });

  group('buffer feeding', () {
    List<double> values(FakeHost h, String key) => [
          for (final s in h.buffer.retained('', key)) s.value,
        ];

    test('RR beats are stamped after the last stored; none is refused', () {
      final h = FakeHost();
      final frame = hexOf(hr28Inner(rr: [900, 900, 900]));
      h.controller.bufferLiveRr(frame);
      h.controller.bufferLiveRr(frame);
      expect(values(h, 'rr'), hasLength(6));
      final at = [for (final s in h.buffer.retained('', 'rr')) s.at];
      for (var i = 1; i < at.length; i++) {
        expect(at[i].isAfter(at[i - 1]), isTrue, reason: 'beat $i');
      }
    });

    test('a frame without beats adds no rr stream', () {
      final h = FakeHost();
      h.controller.bufferLiveRr(hexOf(hr28Inner(hr: 60)));
      h.controller.bufferLiveRr('zz');
      expect(h.buffer.streamKeys(''), isNot(contains('rr')));
    });

    test('hr goes to the device it came from, stamped with its own time', () {
      final h = FakeHost();
      h.controller.bufferLiveHr('aa:bb', 1790000000000, 61);
      expect(h.buffer.retained('aa:bb', 'hr').single.value, 61.0);
      expect(
        h.buffer.retained('aa:bb', 'hr').single.at,
        DateTime.fromMillisecondsSinceEpoch(1790000000000),
      );
      expect(h.buffer.streamKeys(''), isEmpty);
    });

    test('extras: a frame that does not decode adds nothing and never throws',
        () {
      final h = FakeHost();
      expect(() => h.controller.bufferLiveExtras(0x2B, 'zz'), returnsNormally);
      expect(h.buffer.streamKeys(''), isEmpty);
    });

    test('extras: an R17 frame lands ecg streams; the band HR is skipped at 0',
        () {
      final h = FakeHost();
      h.controller.bufferLiveExtras(
          0x2B, hexOf(r17LiveInnerWith(liveHr: 0, quality: 3)));
      expect(values(h, 'ecg_uv'), hasLength(100));
      expect(values(h, 'ecg_quality'), [3.0]);
      expect(h.buffer.streamKeys(''), isNot(contains('ecg_band_hr')));
      h.controller.bufferLiveExtras(
          0x2B, hexOf(r17LiveInnerWith(liveHr: 71, quality: 3)));
      expect(values(h, 'ecg_band_hr'), [71.0]);
    });

    test('IMU: a magnitude-only frame feeds accel_mag; an empty one adds nothing', () {
      final h = FakeHost();
      // Magnitude-only frame (no axes): one stream, in g.
      h.controller.bufferLiveImu(imuFrameOf([1.0, 1.0]));
      expect(values(h, 'accel_mag'), [1.0, 1.0]);
      // An empty frame adds nothing.
      h.controller.bufferLiveImu(imuFrameOf(const []));
      expect(values(h, 'accel_mag'), hasLength(2));
    });
  });

  test('the controller is free of AppState and persistence (invariant 14)', () {
    final src = File('lib/state/live_stream_controller.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(src, isNot(contains('app_state.dart')));
    expect(src, isNot(contains('insertRecord')));
    expect(src, isNot(contains('raw_records')));
  });
}
