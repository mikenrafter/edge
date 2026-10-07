// The dispatcher and gesture slots (RED).
//
//   Tell the time reads the mode of the SLOT that fired: a double tap plays
//   binary while a triple tap plays Morse (GestureSettings.timeBuzzModeFor),
//   read when the action runs, from the injected clock. A slot with no own
//   mode follows the global default.
//
//   Separate state per slot: an in-app action on two slots is run by the
//   dispatcher with the slot that fired it (GestureDispatcher.onSlotAction),
//   so a handler keeps one state per slot. Here the fake handler is a
//   per-slot workout timer: toggling it on the double tap must not touch the
//   triple tap's. The two slots also claim separately (the counted slots'
//   claim keys carry `t<count>:`), so one never swallows the other.
//
// Counted taps arrive through the ECG-touch counter seam (onCountTaps), which
// answers the count of each tap; that is how a triple tap reaches a slot.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/double_tap_repeat_rig.dart' show repTap;

const _channel = MethodChannel('openstrap/device_actions');

Future<GestureSettings> _boot(
    {Map<String, Object> stored = const {},
    Map<int, Set<DeviceAction>> actions = const {}}) async {
  SharedPreferences.setMockInitialValues({...stored});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
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
    dispatcher = GestureDispatcher(
      settings: settings,
      tapClassifiersOn: () => true,
      ecgSupported: () => true,
      onCountTaps: (e) async => count,
      performNative: (_) async => true,
      claim: (k) async => claims.add(k),
      release: (k) async => claims.remove(k),
      onTellTime: (e, elements) async => played.add(elements),
      onSlotAction: (slot, action, e) async {
        calls.add((slot, action));
        if (action == DeviceAction.workoutToggle) {
          running[slot] = !(running[slot] ?? false);
        }
      },
      now: () => clockNow,
    );
  }

  final GestureSettings settings;
  late final GestureDispatcher dispatcher;

  /// The count the next tap is counted as (2 = the plain double tap).
  int count = 2;
  DateTime clockNow = DateTime(2026, 10, 7, 15, 8);
  final claims = <String>{};
  final played = <List<TimeBuzzElement>>[];
  final calls = <(String, DeviceAction)>[];
  final running = <String, bool>{};

  int _n = 0;
  Future<List<GestureOutcome>> tap(int taps) {
    count = taps;
    return dispatcher.handle(repTap(sec: 10 * _n++));
  }
}

List<TimeBuzzElement> _at(DateTime t, TimeBuzzMode m) => encodeTime(t, m);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('Tell the time uses the mode of the slot that fired', () {
    test('double tap plays binary, triple tap plays Morse', () async {
      final s = await _boot(actions: {
        3: {DeviceAction.tellTime},
      });
      await s.setDoubleTapActions({DeviceAction.tellTime});
      await s.setTimeBuzzModeFor('double', TimeBuzzMode.binary);
      await s.setTimeBuzzModeFor('triple', TimeBuzzMode.morse);
      final r = _Rig(s);
      await r.tap(2);
      await r.tap(3);
      final binary = _at(r.clockNow, TimeBuzzMode.binary);
      final morse = _at(r.clockNow, TimeBuzzMode.morse);
      expect(binary, isNot(morse), reason: 'the test needs distinct encodings');
      expect(r.played, [binary, morse]);
    });

    test('a slot with no own mode follows the global default, read at run '
        'time; a slot with one ignores the global', () async {
      final s = await _boot(actions: {
        3: {DeviceAction.tellTime},
        4: {DeviceAction.tellTime},
      });
      await s.setTimeBuzzModeFor('triple', TimeBuzzMode.morse);
      final r = _Rig(s);
      await s.setTimeBuzzMode(TimeBuzzMode.binary);
      await r.tap(4);
      await r.tap(3);
      await s.setTimeBuzzMode(TimeBuzzMode.count);
      await r.tap(4);
      await r.tap(3);
      expect(r.played, [
        _at(r.clockNow, TimeBuzzMode.binary),
        _at(r.clockNow, TimeBuzzMode.morse),
        _at(r.clockNow, TimeBuzzMode.count),
        _at(r.clockNow, TimeBuzzMode.morse),
      ]);
    });

    test('the clock is still read when the action runs, per slot', () async {
      final s = await _boot(actions: {
        3: {DeviceAction.tellTime},
      });
      await s.setDoubleTapActions({DeviceAction.tellTime});
      await s.setTimeBuzzModeFor('double', TimeBuzzMode.binary);
      await s.setTimeBuzzModeFor('triple', TimeBuzzMode.binary);
      final r = _Rig(s);
      r.clockNow = DateTime(2026, 10, 7, 3, 0);
      await r.tap(2);
      r.clockNow = DateTime(2026, 10, 7, 15, 7);
      await r.tap(3);
      expect(r.played, [
        _at(DateTime(2026, 10, 7, 3, 0), TimeBuzzMode.binary),
        _at(DateTime(2026, 10, 7, 15, 7), TimeBuzzMode.binary),
      ]);
    });
  });

  group('two slots with the same action keep separate state', () {
    test('the handler is told which slot fired, and each slot\'s timer is '
        'its own', () async {
      final s = await _boot(actions: {
        3: {DeviceAction.workoutToggle},
      });
      await s.setDoubleTapActions({DeviceAction.workoutToggle});
      final r = _Rig(s);
      await r.tap(2); // double starts its timer
      expect(r.running, {'double': true});
      await r.tap(3); // triple starts its own, double's keeps running
      expect(r.running, {'double': true, 'triple': true});
      await r.tap(2); // double stops; triple is untouched
      expect(r.running, {'double': false, 'triple': true});
      expect(r.calls, [
        ('double', DeviceAction.workoutToggle),
        ('triple', DeviceAction.workoutToggle),
        ('double', DeviceAction.workoutToggle),
      ]);
    });

    test('both slots run Mark a moment: each tap runs it once, for its own '
        'slot, under its own claim', () async {
      final s = await _boot(actions: {
        3: {DeviceAction.markMoment},
      });
      await s.setDoubleTapActions({DeviceAction.markMoment});
      final r = _Rig(s);
      final a = await r.tap(2);
      final b = await r.tap(3);
      expect(a.map((o) => o.status), [GestureStatus.ran]);
      expect(b.map((o) => o.status), [GestureStatus.ran]);
      expect(r.calls, [
        ('double', DeviceAction.markMoment),
        ('triple', DeviceAction.markMoment),
      ]);
      expect(r.claims.where((k) => k.endsWith(':mark_moment')),
          hasLength(2));
      expect(r.claims.where((k) => k.contains(':t3:')), hasLength(1),
          reason: 'the triple tap\'s claim is its own');
    });

    test('a slot handler runs for every in-app action, not only one',
        () async {
      final s = await _boot(actions: {
        3: {DeviceAction.logWater, DeviceAction.markMoment},
      });
      final r = _Rig(s);
      await r.tap(3);
      expect(r.calls.toSet(), {
        ('triple', DeviceAction.logWater),
        ('triple', DeviceAction.markMoment),
      });
    });
  });
}
