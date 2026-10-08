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
import 'package:openstrap_edge/sync/sync_policy.dart' show ClockRef;

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
  FakeHost({this.supported = true, bool wrist = true}) {
    band = FakeBand(order);
    haptics = HapticsService(port: band, allowLong: () => false);
    band.haptics = haptics;
    ecg = SpyEcg(order, remembersWrist: wrist);
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
      ecg: () => ecg,
      ecgSupported: () => supported,
      clockRef: () => clockRef,
      log: logged.add,
      onMarkMoment: (e) async => acted.add('mark'),
      onWorkoutToggle: (e) async {
        acted.add('workout');
        if (workoutThrows) throw StateError('no workout');
      },
      recordEcgSession: (r) async => sessions.add((r.finalCount, r.reason)),
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

  final bool supported;
  final order = <String>[];
  final logged = <String>[];
  final acted = <String>[];
  final sessions = <(int?, String?)>[];
  final written = <String>[];
  final settings = GestureSettings();
  final lab = DeviceLabLog();
  ClockRef? clockRef;
  int loads = 0;
  int assignmentReads = 0;
  bool loadThrows = false;
  bool workoutThrows = false;
  late final FakeBand band;
  late final HapticsService haptics;
  late final SpyEcg ecg;
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
    ecg.dispose();
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
  Future<FakeHost> newHost({bool supported = true, bool wrist = true}) async {
    h = FakeHost(supported: supported, wrist: wrist);
    addTearDown(h.dispose);
    // The app's default is repeated double taps; an ECG band here counts
    // touches, as one whose wearer chose them.
    if (supported) await h.settings.setTapMethod(TapCountMethod.ecg);
    return h;
  }

  group('route dispatch', () {
    test('an immediate double tap runs the mapped in-app action and nothing '
        'else, with no ECG and no cue', () async {
      await newHost(supported: false);
      await h.settings.setDoubleTapActions({DeviceAction.markMoment});
      final out = await h.controller.handle(h.doubleTap());
      expect(out.map((o) => o.status), [GestureStatus.ran]);
      expect(h.acted, ['mark']);
      expect(h.ecg.begins, isEmpty);
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

    test('with 3 taps mapped on an ECG band the tap is counted by the ECG '
        'route, and the action of the final count runs', () async {
      await newHost();
      await h.settings.setActionsForTaps(2, {DeviceAction.markMoment});
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      final done = h.controller.handle(h.doubleTap());
      await until(() => h.order.contains('ecg:start'));
      expect(h.controller.ecgTapActive, isTrue);
      // A steady stream with the finger on the sensor.
      await feedEcgOpening(h.controller.onEcgFrame);
      final out = await done.timeout(const Duration(seconds: 15));
      expect(out.single.taps, 3);
      expect(h.acted, ['workout']);
      expect(h.sessions.single.$1, 3);
      expect(h.sessions.single.$2, isNull);
      await until(() => !h.controller.ecgTapActive);
      await settleMs(50);
    });
  });

  group('the start cue plays before the ECG stream begins', () {
    test('the cue write is the first band write of the gesture and PREPARE '
        'follows it', () async {
      await newHost();
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      final done = h.controller.handle(h.doubleTap());
      await until(() => h.order.contains('ecg:start'));
      expect(h.order.first, 'cue');
      expect(h.order.indexOf('cue'), lessThan(h.order.indexOf('ecg:prepare')));
      // A steady stream with the finger on the sensor.
      await feedEcgOpening(h.controller.onEcgFrame);
      await done.timeout(const Duration(seconds: 15));
      // Start, one follow-up (2 to 3) and the confirm.
      await until(() => h.order.where((l) => l == 'cue').length == 3);
      expect(h.ecg.begins, [false], reason: 'never persisted');
      expect(h.ecg.prepares.single, isNot(contains('rawSaveOn')),
          reason: 'Keep waveform is off: no raw save for a gesture either');
      await until(() => !h.controller.ecgTapActive);
      await settleMs(50);
    });
  });

  group('failures', () {
    test('a gesture abandoned because the stream could not start is kept '
        'with the lab log, and the 2-tap action still runs', () async {
      await newHost(wrist: false);
      await h.settings.setActionsForTaps(2, {DeviceAction.markMoment});
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      final out = await h.controller.handle(h.doubleTap());
      expect(out.single.action, DeviceAction.markMoment);
      expect(h.acted, ['mark']);
      final f = h.controller.failures.all.single;
      expect(f.kind, GestureFailureKind.ecg);
      expect(f.reason, 'start_failed');
      expect(f.log, contains('start_failed'));
      await until(() => h.written.isNotEmpty);
      expect(h.written.last, contains('start_failed'));
      expect(h.sessions.single.$1, isNull);
      expect(h.sessions.single.$2, 'start_failed');
    });

    test('an action that fails is kept as a double-tap failure and the lab '
        'says so', () async {
      await newHost(supported: false);
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

    test('a cue that cannot be read is no failure: loadCues never throws and '
        'the cue still plays', () async {
      await newHost();
      h.loadThrows = true;
      await expectLater(h.controller.loadCues(), completes);
      expect(h.assignmentReads, 0);
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      final done = h.controller.handle(h.doubleTap());
      await until(() => h.order.contains('ecg:start'));
      // A steady stream with the finger on the sensor.
      await feedEcgOpening(h.controller.onEcgFrame);
      await done.timeout(const Duration(seconds: 15));
      expect(h.order, contains('cue'));
      await until(() => !h.controller.ecgTapActive);
      await settleMs(50);
    });

    test('every cue of a gesture reloads the wearer\'s assignments first',
        () async {
      await newHost();
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      final done = h.controller.handle(h.doubleTap());
      await until(() => h.order.contains('ecg:start'));
      // A steady stream with the finger on the sensor.
      await feedEcgOpening(h.controller.onEcgFrame);
      await done.timeout(const Duration(seconds: 15));
      await until(() => h.order.where((l) => l == 'cue').length == 3);
      expect(h.loads, 3, reason: 'the start, follow-up and confirm cues');
      await until(() => !h.controller.ecgTapActive);
      await settleMs(50);
    });
  });

  group('the pending tap count', () {
    test('a second double tap while one is being counted is ignored: it runs '
        'nothing and the first still completes with its own count', () async {
      await newHost();
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      final first = h.controller.handle(h.doubleTap());
      await until(() => h.order.contains('ecg:start'));
      final second = await h.controller.handle(h.doubleTap());
      expect(second, isEmpty);
      expect(h.controller.ecgTapActive, isTrue);
      // A steady stream with the finger on the sensor.
      await feedEcgOpening(h.controller.onEcgFrame);
      final out = await first.timeout(const Duration(seconds: 15));
      expect(out.single.taps, 3);
      expect(h.acted, ['workout']);
      await until(() => !h.controller.ecgTapActive);
      await settleMs(50);
    });

    test('a start that throws clears the pending count, so the next tap '
        'counts again', () async {
      await newHost(wrist: false);
      await h.settings.setActionsForTaps(2, {DeviceAction.markMoment});
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      await h.controller.handle(h.doubleTap());
      await until(() => !h.controller.ecgTapActive);
      await settleMs(50);
      final again = await h.controller.handle(h.doubleTap());
      expect(again.single.action, DeviceAction.markMoment);
      expect(h.acted, ['mark', 'mark']);
    });
  });

  group('the session starts refuse after dispose', () {
    test('the dispatcher\'s ECG start callback begins no gesture', () async {
      await newHost();
      h.controller.dispose();
      await h.controller.dispatcher.onEcgTap!(h.doubleTap());
      expect(h.controller.ecgTapActive, isFalse);
      expect(h.ecg.begins, isEmpty);
      expect(h.order, isEmpty, reason: 'no cue and no ECG write');
    });

    test('the dispatcher\'s touch-counting callback counts nothing', () async {
      await newHost();
      h.controller.dispose();
      expect(await h.controller.dispatcher.onCountTaps!(h.doubleTap()), isNull);
      expect(h.controller.ecgTapActive, isFalse);
      expect(h.ecg.begins, isEmpty);
      expect(h.order, isEmpty);
    });
  });
}
