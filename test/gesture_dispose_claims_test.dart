// A tap whose claim is still pending when the dispatcher is disposed (the app is
// going away) must start nothing when the claim lands: no action, no ECG
// session, no counting window. The claim is given back, so the same tap can run
// after a restart. Every route takes its claim before it acts, so each is held
// here with a completer, the dispatcher disposed, and the claim released.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');

final DateTime _t0 = DateTime.utc(2026, 10, 4, 8);

StrapEvent _tap() {
  final ts = _t0.millisecondsSinceEpoch ~/ 1000;
  return StrapEvent(
    eventId: 14,
    tsEpoch: ts,
    receivedAt: _t0.add(const Duration(seconds: 1)),
    hex: '',
    deviceId: 'band',
  );
}

Future<GestureSettings> _settings() async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

class _Rig {
  _Rig(this.settings, {this.mg = false}) {
    repeat = DoubleTapRepeatSession(
      maxTaps: () => settings.repeatTapMax,
      window: () => settings.repeatTapWindow,
      buzz: (id) async {
        started.add('repeat buzz');
        return true;
      },
      step: (_) {},
      onFinished: (_) {},
    );
    dispatcher = GestureDispatcher(
      settings: settings,
      // The claim answers only when the test lets it.
      claim: (key) async {
        claimed.add(key);
        await gate.future;
        return true;
      },
      release: (key) async => released.add(key),
      performNative: (id) async {
        started.add('native:$id');
        return true;
      },
      ecgSupported: () => mg,
      onEcgTap: (e) async => started.add('ecg session'),
      onCountTaps: (e) async {
        started.add('counting session');
        return 2;
      },
      repeatSession: repeat,
      onMarkMoment: (e) async => started.add('moment'),
      onWorkoutToggle: (e) async => started.add('workout'),
      tapClassifiersOn: () => true,
    );
  }

  final GestureSettings settings;
  final bool mg;
  late final DoubleTapRepeatSession repeat;
  late final GestureDispatcher dispatcher;
  final gate = Completer<void>();
  final claimed = <String>[];
  final released = <String>[];

  /// Everything that began: an action, a session, a window cue.
  final started = <String>[];

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The tap, its claim held; disposed; the claim lets go. Its outcomes.
  Future<List<GestureOutcome>> tapDisposedDuringClaim() async {
    final outcomes = dispatcher.handle(_tap());
    await settle();
    expect(claimed, isNotEmpty, reason: 'the claim is pending');
    dispatcher.dispose();
    gate.complete();
    return outcomes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  test('a workout toggle whose claim lands after dispose is not run, and the '
      'claim is given back', () async {
    final s = await _settings();
    await s.setDoubleTapActions({DeviceAction.workoutToggle});
    final r = _Rig(s);
    final outcomes = await r.tapDisposedDuringClaim();
    expect(outcomes, isEmpty);
    expect(r.started, isEmpty);
    expect(r.released, r.claimed, reason: 'a re-send can run it later');
  });

  test('of several mapped actions none runs after dispose, a native one '
      'included', () async {
    final s = await _settings();
    await s.setDoubleTapActions(
        {DeviceAction.mediaPlayPause, DeviceAction.workoutToggle});
    final r = _Rig(s);
    final outcomes = await r.tapDisposedDuringClaim();
    await r.settle();
    expect(outcomes, isEmpty);
    expect(r.started, isEmpty);
    expect(r.claimed, hasLength(1), reason: 'the second action never asked');
  });

  test('the ECG lab tap starts no session after dispose', () async {
    final s = await _settings();
    await s.setEcgOnDoubleTap(true);
    final r = _Rig(s, mg: true);
    await r.tapDisposedDuringClaim();
    await r.settle();
    expect(r.started, isEmpty);
    expect(r.released, r.claimed);
  });

  test('the touch counter starts no session after dispose, and its actions '
      'do not run', () async {
    final s = await _settings();
    await s.setDoubleTapActions({DeviceAction.workoutToggle});
    await s.setActionsForTaps(3, {DeviceAction.markMoment});
    final r = _Rig(s, mg: true);
    final outcomes = await r.tapDisposedDuringClaim();
    await r.settle();
    expect(outcomes, isEmpty);
    expect(r.started, isEmpty);
    expect(r.released, r.claimed);
  });

  test('the repeated-double-tap window never opens after dispose', () async {
    final s = await _settings();
    await s.setDoubleTapActions({DeviceAction.workoutToggle});
    await s.setActionsForTaps(3, {DeviceAction.markMoment});
    final r = _Rig(s);
    final outcomes = await r.tapDisposedDuringClaim();
    await r.settle();
    expect(outcomes, isEmpty);
    expect(r.repeat.open, isFalse);
    expect(r.started, isEmpty);
    expect(r.released, r.claimed);
  });
}
