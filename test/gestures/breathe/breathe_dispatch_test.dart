// The Breathing exercise gesture end to end below AppState (RED): the
// GestureDispatcher hands the SLOT that fired to a BreathGesture, which reads
// that slot's own pattern and length and toggles a BreathPacer. Fake clock,
// fake session host, real GestureSettings and real dispatcher (claims faked,
// counted taps through the same ECG-touch counter seam slot_dispatch_test
// uses).
//
// Pinned:
//   * no session running: the gesture starts one with the slot's pattern and
//     length (defaults resonance / 3 min);
//   * a session running (this slot's, another slot's, or one the SCREEN
//     started): the gesture ends it early, banking through the host, with no
//     complete cue;
//   * settings are read when the gesture runs;
//   * the dispatcher call completes while the session runs (the action timeout
//     is 10 s) and reports the action as ran;
//   * a failed start (no band) is a FAILED outcome, so the claim is given back.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/breath_gesture.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/breath_pacer_fakes.dart';
import '../../support/double_tap_repeat_rig.dart' show repTap;

const _channel = MethodChannel('openstrap/device_actions');

Future<GestureSettings> _boot(Map<int, Set<DeviceAction>> actions) async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  await s.setTapMethod(TapCountMethod.ecg);
  for (final e in actions.entries) {
    if (e.key == 2) {
      await s.setDoubleTapActions(e.value);
    } else {
      await s.setActionsForTaps(e.key, e.value);
    }
  }
  return s;
}

class _Rig {
  _Rig(this.settings, {bool connected = true}) {
    host = FakeBreathHost(time, connected: connected);
    pacer = BreathPacer(host, now: time.read, timer: time.timer);
    breath = BreathGesture(settings: settings, pacer: pacer, host: host);
    dispatcher = GestureDispatcher(
      settings: settings,
      tapClassifiersOn: () => true,
      ecgSupported: () => true,
      onCountTaps: (e) async => count,
      performNative: (_) async => true,
      claim: (k) async => claims.add(k),
      release: (k) async => claims.remove(k),
      onSlotAction: (slot, action, e) async {
        calls.add((slot, action));
        if (action == DeviceAction.breathe) await breath.onSlot(slot);
      },
    );
  }

  final GestureSettings settings;
  final time = FakeTime();
  late final FakeBreathHost host;
  late final BreathPacer pacer;
  late final BreathGesture breath;
  late final GestureDispatcher dispatcher;
  int count = 2;
  final claims = <String>{};
  final calls = <(String, DeviceAction)>[];
  int _n = 0;

  Future<List<GestureOutcome>> tap(int taps) {
    count = taps;
    return dispatcher.handle(repTap(sec: 10 * _n++));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('the toggle', () {
    test('a tap starts a session with the defaults, the next tap ends it',
        () async {
      final r = _Rig(await _boot({2: {DeviceAction.breathe}}));
      final first = await r.tap(2);
      expect(first.single.status, GestureStatus.ran);
      expect(r.host.events.first, 'start:resonance:180');
      expect(r.pacer.running, isTrue);
      await r.time.advance(const Duration(seconds: 25));
      expect(r.host.cues.map((c) => c.kind),
          [BreathPhaseKind.inhale, BreathPhaseKind.exhale, BreathPhaseKind.inhale,
           BreathPhaseKind.exhale, BreathPhaseKind.inhale]);
      final second = await r.tap(2);
      expect(second.single.status, GestureStatus.ran);
      expect(r.pacer.running, isFalse);
      expect(r.host.stops, 1);
      expect(r.host.completes, 0);
      expect(r.host.pacedByBand, isFalse);
      await r.time.advance(const Duration(minutes: 5));
      expect(r.host.cues, hasLength(5), reason: 'no cue after the stop');
      expect(r.host.starts, 1);
    });

    test('a third tap starts a fresh session', () async {
      final r = _Rig(await _boot({2: {DeviceAction.breathe}}));
      await r.tap(2);
      await r.tap(2);
      await r.tap(2);
      expect(r.host.starts, 2);
      expect(r.pacer.running, isTrue);
    });

    test('the dispatcher call returns while the session is still running',
        () async {
      final r = _Rig(await _boot({2: {DeviceAction.breathe}}));
      await r.tap(2).timeout(const Duration(seconds: 2));
      expect(r.pacer.running, isTrue);
      expect(r.host.breathingActive, isTrue);
      expect(r.host.completes, 0);
    });

    test('a run to the end leaves the next tap a START, not a stop', () async {
      final s = await _boot({2: {DeviceAction.breathe}});
      await s.setBreatheMinutesFor('double', 1);
      final r = _Rig(s);
      await r.tap(2);
      await r.time.advance(const Duration(minutes: 1));
      expect(r.host.completes, 1);
      expect(r.host.breathingActive, isFalse);
      await r.tap(2);
      expect(r.host.starts, 2);
      expect(r.pacer.running, isTrue);
    });
  });

  group('each slot has its own pattern and length', () {
    test('the double tap and the triple tap start different sessions',
        () async {
      final s = await _boot({
        2: {DeviceAction.breathe},
        3: {DeviceAction.breathe},
      });
      await s.setBreathePatternFor('double', 'box');
      await s.setBreatheMinutesFor('double', 1);
      await s.setBreathePatternFor('triple', 'four_seven_eight');
      await s.setBreatheMinutesFor('triple', 10);
      final r = _Rig(s);
      await r.tap(2);
      expect(r.host.events.last, 'start:box:60');
      await r.tap(2); // stop
      await r.tap(3);
      expect(r.host.events.last, 'start:four_seven_eight:600');
      expect(r.host.target, const Duration(minutes: 10));
      expect(r.calls.map((c) => c.$1), ['double', 'double', 'triple']);
    });

    test('a slot with no choice of its own runs the defaults while another '
        'slot has one', () async {
      final s = await _boot({
        2: {DeviceAction.breathe},
        4: {DeviceAction.breathe},
      });
      await s.setBreathePatternFor('double', 'box');
      final r = _Rig(s);
      await r.tap(4);
      expect(r.host.events.last, 'start:resonance:180');
    });

    test('the settings are read when the gesture runs, not when it was '
        'mapped', () async {
      final s = await _boot({2: {DeviceAction.breathe}});
      final r = _Rig(s);
      await s.setBreathePatternFor('double', 'extended_exhale');
      await s.setBreatheMinutesFor('double', 2);
      await r.tap(2);
      expect(r.host.events.last, 'start:extended_exhale:120');
    });

    test('any slot\'s gesture ends the one running session (there is only '
        'one breathing session)', () async {
      final s = await _boot({
        2: {DeviceAction.breathe},
        5: {DeviceAction.breathe},
      });
      final r = _Rig(s);
      await r.tap(2);
      await r.tap(5);
      expect(r.host.starts, 1);
      expect(r.host.stops, 1);
      expect(r.pacer.running, isFalse);
    });
  });

  group('a session the pacer did not start', () {
    test('the gesture ends a session started by the screen: banked through '
        'the host, the pacer never armed, no cue', () async {
      final r = _Rig(await _boot({2: {DeviceAction.breathe}}));
      r.host.breathingActive = true; // the CalmBreathing screen started it
      await r.tap(2);
      expect(r.host.starts, 0);
      expect(r.host.stops, 1);
      expect(r.pacer.running, isFalse);
      expect(r.host.cues, isEmpty);
      expect(r.time.pending, 0);
      await r.tap(2);
      expect(r.host.starts, 1, reason: 'the tap after that starts one');
    });
  });

  group('failures', () {
    test('no band: the outcome is FAILED and its claim is given back, so the '
        'same tap can run again once there is a band', () async {
      final r = _Rig(await _boot({2: {DeviceAction.breathe}}),
          connected: false);
      final out = await r.tap(2);
      expect(out.single.status, GestureStatus.failed);
      expect(out.single.error, isA<StateError>());
      expect(r.claims, isEmpty);
      expect(r.host.pacedByBand, isFalse);
      expect(r.pacer.running, isFalse);
      expect(r.time.pending, 0);
    });

    test('a start that throws is a FAILED outcome and leaves no latch',
        () async {
      final r = _Rig(await _boot({2: {DeviceAction.breathe}}));
      r.host.startThrows = StateError('radio down');
      final out = await r.tap(2);
      expect(out.single.status, GestureStatus.failed);
      expect(r.host.pacedByBand, isFalse);
      expect(r.pacer.running, isFalse);
      r.host.startThrows = null;
      final again = await r.tap(2);
      expect(again.single.status, GestureStatus.ran);
      expect(r.pacer.running, isTrue);
    });
  });
}
