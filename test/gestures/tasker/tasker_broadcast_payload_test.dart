// Gesture -> Tasker (RED): the Broadcast to Tasker action carries WHICH
// gesture fired it. Tasker profiles listen for one Android intent
// (wtf.openstrap.openstrap_edge.DOUBLE_TAP); without the slot and the tap
// count in its extras a profile cannot tell a double tap from a triple.
//
// The contract pinned here is the method-channel call the dispatcher makes
// (`openstrap/device_actions`, method `perform`): its arguments are the action
// id plus `slot` (the GestureSlots id: double, triple, quad, quint) and `taps`
// (2..5). NativeChannels.kt copies them into the broadcast as the string extra
// "slot" and the int extra "taps" (device-tested by hand, see the Kotlin notes
// in the phase report). Every other native action keeps its old, bare call.
//
// "Tasker connection" (Prefs.taskerConnection) gates it: off, the action does
// not broadcast. The platform gate stays: Android only is decided by the
// native `capabilities` answer (not in the list on iOS), which the settings
// screen already reads; see tasker_disabled_not_hidden_test.dart.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/gesture_slots.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/double_tap_repeat_rig.dart' show repTap;

const _channel = MethodChannel('openstrap/device_actions');

/// Every `perform` call the dispatcher made, as the arguments it sent.
final _performed = <Map<Object?, Object?>>[];

Future<GestureSettings> _boot(Map<int, Set<DeviceAction>> actions) async {
  SharedPreferences.setMockInitialValues({});
  await Prefs.ensureLoaded();
  _performed.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') {
      return ['media_play_pause', 'broadcast_to_tasker'];
    }
    if (call.method == 'perform') {
      _performed.add(Map<Object?, Object?>.of(call.arguments as Map));
      return true;
    }
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  await s.setTapMethod(TapCountMethod.ecg);
  for (final e in actions.entries) {
    await s.setActionsForTaps(e.key, e.value);
  }
  return s;
}

class _Rig {
  _Rig(this.settings) {
    // No `performNative`: the real DeviceActions.perform, over the mocked
    // channel, is what Tasker's broadcast goes through.
    dispatcher = GestureDispatcher(
      settings: settings,
      tapClassifiersOn: () => true,
      ecgSupported: () => true,
      onCountTaps: (e) async => count,
      claim: (k) async => claims.add(k),
      release: (k) async => claims.remove(k),
    );
  }

  final GestureSettings settings;
  late final GestureDispatcher dispatcher;
  int count = 2;
  final claims = <String>{};
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

  group('the broadcast carries the slot and the tap count', () {
    for (var taps = 2; taps <= 5; taps++) {
      final slot = GestureSlots.ofTaps(taps);
      test('${GestureSlots.nameOf(slot)}: slot "$slot", taps $taps', () async {
        final s = await _boot({taps: {DeviceAction.broadcastToTasker}});
        Prefs.setBool(Prefs.taskerConnection, true);
        final out = await _Rig(s).tap(taps);
        expect(out.single.status, GestureStatus.ran);
        expect(_performed, [
          {'action': 'broadcast_to_tasker', 'slot': slot, 'taps': taps},
        ]);
      });
    }

    test('a double and a triple tap send different extras', () async {
      final s = await _boot({
        2: {DeviceAction.broadcastToTasker},
        3: {DeviceAction.broadcastToTasker},
      });
      Prefs.setBool(Prefs.taskerConnection, true);
      final r = _Rig(s);
      await r.tap(2);
      await r.tap(3);
      expect(_performed, hasLength(2));
      expect(_performed[0]['slot'], 'double');
      expect(_performed[0]['taps'], 2);
      expect(_performed[1]['slot'], 'triple');
      expect(_performed[1]['taps'], 3);
    });

    test('the slot is the one that fired, not the one mapped first', () async {
      // Only the quad slot has the action: a triple tap must not broadcast.
      final s = await _boot({4: {DeviceAction.broadcastToTasker}});
      Prefs.setBool(Prefs.taskerConnection, true);
      final r = _Rig(s);
      await r.tap(3);
      expect(_performed, isEmpty);
      await r.tap(4);
      expect(_performed.single['slot'], 'quad');
      expect(_performed.single['taps'], 4);
    });

    test('every other native action keeps its bare call (no slot, no taps)',
        () async {
      final s = await _boot({3: {DeviceAction.mediaPlayPause}});
      Prefs.setBool(Prefs.taskerConnection, true);
      await _Rig(s).tap(3);
      expect(_performed, [
        {'action': 'media_play_pause'},
      ]);
    });
  });

  group('"Tasker connection" gates the broadcast', () {
    test('off: a mapped Broadcast to Tasker sends nothing and does not report '
        'that it ran', () async {
      final s = await _boot({3: {DeviceAction.broadcastToTasker}});
      Prefs.setBool(Prefs.taskerConnection, false);
      final out = await _Rig(s).tap(3);
      expect(_performed, isEmpty);
      expect(out.single.status, isNot(GestureStatus.ran));
    });

    test('off does not stop the other actions of the same gesture', () async {
      final s = await _boot({
        3: {DeviceAction.mediaPlayPause, DeviceAction.broadcastToTasker},
      });
      Prefs.setBool(Prefs.taskerConnection, false);
      await _Rig(s).tap(3);
      expect(_performed, [
        {'action': 'media_play_pause'},
      ]);
    });

    test('turned back on, the next tap broadcasts', () async {
      final s = await _boot({3: {DeviceAction.broadcastToTasker}});
      final r = _Rig(s);
      Prefs.setBool(Prefs.taskerConnection, false);
      await r.tap(3);
      expect(_performed, isEmpty);
      Prefs.setBool(Prefs.taskerConnection, true);
      await r.tap(3);
      expect(_performed.single['slot'], 'triple');
    });
  });
}
