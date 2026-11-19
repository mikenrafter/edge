// GestureController in isolation, with fake collaborators. The same
// behaviours are also pinned through AppState in the other gesture tests; these
// prove the controller stands on its own and never reaches for AppState. The
// dispatcher's claim ledger is still the real LocalDb (it is not injectable),
// so the tests share the temporary database the AppState tests use.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/state/gesture_controller.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'gesture_controller_unit.db';

/// A band with no haptic profile: every cue is one plain pulse, written into
/// [order] as `cue`, and answered with the band's "ended" event 2 ms later so
/// the queue moves at test speed.
class FakeBand implements BandHapticsPort {
  FakeBand(this.order);
  final List<String> order;
  late HapticsService haptics;
  bool _gone = false;

  @override
  bool get isConnected => true;
  @override
  String? get generation => null;

  @override
  Future<bool> buzzBand({int holdMs = 0}) async {
    order.add('cue');
    Timer(const Duration(milliseconds: 2), () {
      if (_gone) return;
      final now = DateTime.now();
      haptics.onBandEvent(StrapEvent(
        eventId: 100,
        tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
        receivedAt: now,
        hex: '',
        deviceId: '',
      ));
    });
    return true;
  }

  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) async => false;

  void dispose() => _gone = true;
}

/// Every collaborator of the controller, as a recorder.
class FakeHost {
  FakeHost() {
    band = FakeBand(order);
    haptics = HapticsService(port: band, allowLong: () => false);
    band.haptics = haptics;
    dispatcher = AlertDispatcher(
      phone: () async => false,
      band: () async => true,
      isConnected: () => true,
      bandQueueWait: const Duration(seconds: 5),
      ledger: MemoryAlertDeliveryLedger(),
    );
    controller = GestureController(
      settings: settings,
      haptics: haptics,
      deviceLab: lab,
      alertDispatcher: () => dispatcher,

      log: logged.add,
      onMarkMoment: (e) async => acted.add('mark'),
      onWorkoutToggle: (e) async {
        acted.add('workout');
        if (workoutThrows) throw StateError('no workout');
      },

      loadPatterns: () async {
        loads++;
        if (loadThrows) throw StateError('no patterns');
        return HapticPatternStore.decodeSeeded(null);
      },
      readCueAssignments: () {
        assignmentReads++;
        return '';
      },
      readFailures: () => '',
      writeFailures: (json) async => written.add(json),
    );
  }

  final order = <String>[];
  final logged = <String>[];
  final acted = <String>[];
  final written = <String>[];
  final settings = GestureSettings();
  final lab = DeviceLabLog();
  int loads = 0;
  int assignmentReads = 0;
  bool loadThrows = false;
  bool workoutThrows = false;
  late final FakeBand band;
  late final HapticsService haptics;
  late final AlertDispatcher dispatcher;
  late final GestureController controller;

  int _seq = 0;

  /// A live double tap, each its own strap second so no claim is shared.
  StrapEvent doubleTap() {
    final now = DateTime.now();
    return StrapEvent(
      eventId: 14,
      tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
      tsSubsec: 100 + 37 * ++_seq,
      receivedAt: now,
      hex: '',
      deviceId: 'band',
    );
  }

  void dispose() {
    band.dispose();
    settings.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
  });
  tearDown(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  late FakeHost h;
  Future<FakeHost> newHost() async {
    h = FakeHost();
    addTearDown(h.dispose);
    return h;
  }

  group('route dispatch', () {
    test('an immediate double tap runs the mapped in-app action and nothing '
        'else, with no cue', () async {
      await newHost();
      await h.settings.setDoubleTapActions({DeviceAction.markMoment});
      final out = await h.controller.handle(h.doubleTap());
      expect(out.map((o) => o.status), [GestureStatus.ran]);
      expect(h.acted, ['mark']);
      expect(h.order, isNot(contains('cue')));
    });

    test('an event that is not a double tap is ignored', () async {
      await newHost();
      await h.settings.setDoubleTapActions({DeviceAction.markMoment});
      final now = DateTime.now();
      final out = await h.controller.handle(StrapEvent(
          eventId: 9,
          tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
          receivedAt: now,
          hex: '',
          deviceId: 'band'));
      expect(out, isEmpty);
      expect(h.acted, isEmpty);
    });

  });

  group('failures', () {
    test('an action that fails is kept as a double-tap failure and the lab '
        'says so', () async {
      await newHost();
      h.workoutThrows = true;
      await h.settings.setDoubleTapActions({DeviceAction.workoutToggle});
      final out = await h.controller.handle(h.doubleTap());
      expect(out.single.status, GestureStatus.failed);
      final f = h.controller.failures.all.single;
      expect(f.kind, GestureFailureKind.doubleTap);
      expect(f.reason, startsWith('workout_toggle'));
      expect(h.lab.toPlainText(withPackets: false), contains('Gesture failed ('));
    });

    test('the store and the cues are one object each, built on first use',
        () async {
      await newHost();
      expect(identical(h.controller.failures, h.controller.failures), isTrue);
      expect(identical(h.controller.cues, h.controller.cues), isTrue);
      expect(identical(h.controller.cues.haptics, h.haptics), isTrue);
    });
  });

  group('cue reload', () {
    test('loadCues reads the patterns and the assignments each time it is '
        'asked', () async {
      await newHost();
      await h.controller.loadCues();
      await h.controller.loadCues();
      expect(h.loads, 2);
      expect(h.assignmentReads, 2);
    });

  });

}
