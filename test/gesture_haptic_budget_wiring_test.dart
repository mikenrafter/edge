// The haptic budget rules at the real gesture seams: GestureController (the
// dispatcher, the sessions and their cues) and AppState (the tap ack, the
// limit setting). The queue and the dispatcher have their own files
// (band_queue_haptic_budget_test.dart, gesture_haptic_gate_test.dart); this one
// pins that the real gesture path is wired to them.
//
// Gesture haptics are exactly these jobs of the band queue:
//   * GestureController._gestureCue: the start, follow-up, "gyro ready",
//     confirm and failure cues of the ECG touch counter and of repeated double
//     taps (gesture_controller.dart);
//   * AppState._onLiveEvent's tap ack: the confirm cue (or, with no haptic
//     vocabulary, one plain buzz) after a plain double tap's action ran.
// Each must be queued inside `HapticsService.asGesture(gestureId, ...)`, the
// same id for every cue of one gesture (the cue event ids all start with the
// gesture's own base id). Breathing cues, alerts, previews and the like are
// not gestures.
//
// Pinned:
//   * rule 4 at the controller and at AppState: the budget spent, a live double
//     tap is not acted on (no action, no cue, no ECG stream, no failure);
//   * rules 1 and 5 through the real ECG route: with 2 commands left, a
//     counted gesture's three cues (start, follow-up, confirm) are all written
//     and the ledger counts only the 2 it had room for;
//   * rule 6 at AppState: the limit comes from Prefs.hapticCommandLimit, read
//     on every use, and a gesture follows a changed limit at once.
//
// Real clock, as the neighbouring gesture tests (their cues answer in 2 ms).

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart'
    show GestureOutcome, GestureStatus;
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/state/gesture_controller.dart';
import 'package:openstrap_edge/state/prefs.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'gesture_haptic_budget_wiring.db';

/// A band with no haptic profile: every cue is one plain pulse (one command),
/// answered with the band's "ended" event 2 ms later.
class _Band implements BandHapticsPort {
  _Band(this.order);
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

class _Host {
  _Host({this.supported = true}) {
    band = _Band(order);
    haptics = HapticsService(port: band, allowLong: () => false);
    band.haptics = haptics;
    ecg = SpyEcg(order);
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
      clockRef: () => null,
      log: (_) {},
      onMarkMoment: (e) async => acted.add('mark'),
      onWorkoutToggle: (e) async => acted.add('workout'),
      recordEcgSession: (r) async {},
      loadPatterns: () async => HapticPatternStore.decodeSeeded(null),
      readCueAssignments: () => '',
      readFailures: () => '',
      writeFailures: (json) async {},
    );
  }

  final bool supported;
  final order = <String>[];
  final acted = <String>[];
  final settings = GestureSettings();
  final lab = DeviceLabLog();
  late final _Band band;
  late final HapticsService haptics;
  late final SpyEcg ecg;
  late final AlertDispatcher dispatcher;
  late final GestureController controller;
  int _seq = 0;

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

  /// Leave the band [left] commands in the window (written [ago] ago).
  void spend({required int left, Duration ago = Duration.zero}) {
    final n = haptics.commandsLeft - left;
    if (n > 0) haptics.ledger.record(n, clock.now().subtract(ago));
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

  group('GestureController', () {
    late _Host h;
    Future<_Host> host({bool supported = true}) async {
      h = _Host(supported: supported);
      addTearDown(h.dispose);
      addTearDown(h.controller.dispose); // first: ends a session left running
      if (supported) await h.settings.setTapMethod(TapCountMethod.ecg);
      return h;
    }

    test('rule 4, plain double tap: no budget left means no action and no '
        'band write', () async {
      await host(supported: false);
      await h.settings.setDoubleTapActions({DeviceAction.markMoment});
      h.spend(left: 0);
      // Not awaited to the end: a gesture that did start would wait for
      // packets that never come.
      List<GestureOutcome>? out;
      unawaited(h.controller.handle(h.doubleTap()).then((o) => out = o));
      await settleMs(400);
      expect(out, isEmpty, reason: 'answered at once, with nothing');
      expect(h.acted, isEmpty);
      expect(h.order, isEmpty);
      expect(h.controller.failures.all, isEmpty);
    });

    test('with a command left the same tap acts as before (control)',
        () async {
      await host(supported: false);
      await h.settings.setDoubleTapActions({DeviceAction.markMoment});
      h.spend(left: 1);
      final out = await h.controller.handle(h.doubleTap());
      expect(out.single.status, GestureStatus.ran);
      expect(h.acted, ['mark']);
    });

    test('rule 4, ECG touch counter: no budget left means no stream, no start '
        'cue and no action', () async {
      await host();
      await h.settings.setActionsForTaps(2, {DeviceAction.markMoment});
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      h.spend(left: 0);
      // Not awaited to the end: a gesture that did start would wait for
      // packets that never come.
      List<GestureOutcome>? out;
      unawaited(h.controller.handle(h.doubleTap()).then((o) => out = o));
      await settleMs(400);
      expect(out, isEmpty, reason: 'answered at once, with nothing');
      expect(h.controller.ecgTapActive, isFalse);
      expect(h.ecg.begins, isEmpty);
      expect(h.order, isEmpty, reason: 'no cue and no ECG write');
      expect(h.acted, isEmpty);
      expect(h.controller.failures.all, isEmpty);
    });

    test('rules 1 and 5 through the real route: 2 commands left, a counted '
        'gesture still plays its start, follow-up and confirm, and the ledger '
        'counts only 2', () async {
      await host();
      await h.settings.setActionsForTaps(3, {DeviceAction.workoutToggle});
      // 28 written a minute ago: they leave the window a minute from now.
      h.spend(left: 2, ago: const Duration(seconds: 60));
      final t0 = clock.now();
      final done = h.controller.handle(h.doubleTap());
      await until(() => h.order.contains('ecg:start'));
      await feedEcgOpening(h.controller.onEcgFrame);
      final out = await done.timeout(const Duration(seconds: 15));
      expect(out.single.taps, 3);
      expect(h.acted, ['workout']);
      // Start, one follow-up (2 to 3) and the confirm: three commands against
      // two left. All three are written (the old queue drops the third).
      await until(() => h.order.where((l) => l == 'cue').length == 3,
          what: 'the third cue (the confirm) was written');
      expect(h.haptics.commandsLeft, 0, reason: 'the limit, not more');
      // The 28 are gone 61 s from the start; the gesture's writes (all made
      // after it) are still in the window. Counted: 2. An overdraw that
      // counted all 3 would leave 27.
      expect(h.haptics.ledger.commandsLeft(t0.add(const Duration(seconds: 61))),
          28);
      await until(() => !h.controller.ecgTapActive);
      await settleMs(50);
    });
  });

  group('AppState', () {
    late ActionChannel channel;
    late List<String> order;
    Future<GestureRig> rig({bool mg = false}) async {
      order = <String>[];
      channel = ActionChannel(order: order);
      addTearDown(channel.dispose);
      final r = GestureRig(mg: mg, order: order);
      addTearDown(r.dispose);
      await r.measureCues();
      return r;
    }

    // The limit is a static preference: put the default back after a test.
    tearDown(() => Prefs.setInt(Prefs.hapticsCommandLimit, 30));

    void spendAll(GestureRig r) =>
        r.app.haptics.ledger.record(r.app.haptics.commandsLeft, clock.now());

    test('rule 4, plain double tap: the budget spent, no action, no tap ack, '
        'no failure', () async {
      final r = await rig();
      await r.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      spendAll(r);
      r.doubleTap();
      await settleMs(500);
      expect(channel.performed, isEmpty);
      expect(order, isEmpty);
      expect(r.app.gestureFailures.all, isEmpty);
    });

    test('rule 4, repeated double taps: the budget spent, no window, no '
        'start cue, no action', () async {
      final r = await rig();
      await mapActions(r.app, [2, 3]);
      spendAll(r);
      r.doubleTap();
      await settleMs(600);
      expect(labCount(r, 'Double tap 1 received'), 0,
          reason: 'no window was opened');
      expect(order, isEmpty);
      expect(channel.performed, isEmpty);
      expect(r.app.gestureFailures.all, isEmpty);
    });

    test('with budget the same tap opens the window (control for the probe)',
        () async {
      final r = await rig();
      await mapActions(r.app, [2, 3]);
      r.doubleTap();
      await settleMs(600);
      expect(labCount(r, 'Double tap 1 received'), 1);
      await settleMs(2800); // let the window run out
    });

    test('with budget a plain double tap acts and is acknowledged (control)',
        () async {
      final r = await rig();
      await r.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      r.doubleTap();
      await until(() => r.cues.isNotEmpty);
      await settleMs(100);
      expect(channel.performed, ['media_play_pause']);
      expect(order, ['action:media_play_pause', 'cue:confirm']);
    });

    test('tap ack with one command left (holds today, must keep holding): the '
        'action runs and its whole confirm cue is written, never counted past '
        'the limit', () async {
      final r = await rig();
      await r.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      final ledger = r.app.haptics.ledger;
      final used = 30 - r.app.haptics.commandsLeft; // measureCues' own cues
      final t0 = clock.now();
      ledger.record(r.app.haptics.commandsLeft - 1,
          t0.subtract(const Duration(seconds: 60)));
      r.doubleTap();
      await until(() => r.cues.isNotEmpty);
      await settleMs(150);
      expect(channel.performed, ['media_play_pause']);
      expect(r.cues, everyElement('confirm'));
      expect(r.app.haptics.commandsLeft, 0, reason: 'the limit, not more');
      // The 60-second-old writes are gone 61 s on; the confirm's writes are
      // not, and only the one that had room was counted.
      expect(ledger.commandsLeft(t0.add(const Duration(seconds: 61))),
          30 - used - 1);
    });

    test('rule 6: the service takes its limit from Prefs, read on every use',
        () async {
      final r = await rig();
      final ledger = r.app.haptics.ledger;
      final spent = 30 - r.app.haptics.commandsLeft; // what measureCues used
      Prefs.setHapticCommandLimit(20);
      expect(r.app.haptics.commandsLeft, 20 - spent);
      Prefs.setHapticCommandLimit(60);
      expect(r.app.haptics.commandsLeft, 60 - spent);
      Prefs.setHapticCommandLimit(5); // clamped to 10
      expect(r.app.haptics.commandsLeft, 10 - spent);
      expect(identical(ledger, r.app.haptics.ledger), isTrue,
          reason: 'one ledger, its limit changes under it');
    });

    test('rule 6: a gesture follows a changed limit at once', () async {
      final r = await rig();
      await r.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      // Lower the limit and spend what it allows: the budget is gone.
      Prefs.setHapticCommandLimit(10);
      spendAll(r);
      expect(r.app.haptics.commandsLeft, 0);
      r.doubleTap();
      await settleMs(400);
      expect(channel.performed, isEmpty, reason: 'no room at a limit of 10');
      // Raise it: the next tap acts and is acknowledged.
      Prefs.setHapticCommandLimit(60);
      r.doubleTap();
      await until(() => r.cues.isNotEmpty);
      await settleMs(100);
      expect(channel.performed, ['media_play_pause']);
    });
  });
}
