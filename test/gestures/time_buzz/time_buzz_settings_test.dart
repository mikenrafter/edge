// GestureSettings for Tell the time: the persisted encoding mode, and the
// action's place in the stored mapping and the per-platform supported set.
//
//   timeBuzzMode      count until changed; persisted under the SharedPreferences
//                     key `gesture_time_buzz_mode` as the mode's name; a value
//                     that is not one of count / binary / morse reads as count;
//                     the setter notifies listeners only on a change.
//   supported         the in-app tellTime is offerable everywhere, whatever
//                     native capabilities answer (none here).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');
const _key = 'gesture_time_buzz_mode';

Future<GestureSettings> _boot([Map<String, Object> stored = const {}]) async {
  SharedPreferences.setMockInitialValues({...stored});
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'capabilities') return <String>[];
        return false;
      }));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('timeBuzzMode', () {
    test('defaults to count', () async {
      final s = await _boot();
      expect(s.timeBuzzMode, TimeBuzzMode.count);
    });

    test('a change is kept and persisted by name', () async {
      final s = await _boot();
      await s.setTimeBuzzMode(TimeBuzzMode.binary);
      expect(s.timeBuzzMode, TimeBuzzMode.binary);
      expect((await SharedPreferences.getInstance()).getString(_key), 'binary');
      await s.setTimeBuzzMode(TimeBuzzMode.morse);
      expect(s.timeBuzzMode, TimeBuzzMode.morse);
      expect((await SharedPreferences.getInstance()).getString(_key), 'morse');
    });

    test('round trip: a fresh GestureSettings reads what was set, for every '
        'mode', () async {
      for (final mode in TimeBuzzMode.values) {
        final s = await _boot();
        await s.setTimeBuzzMode(mode);
        // The same store, a new object: what an app restart does.
        final again = GestureSettings();
        await again.bootstrap();
        expect(again.timeBuzzMode, mode, reason: '$mode');
      }
    });

    test('the stored names are read as they are', () async {
      expect((await _boot({_key: 'count'})).timeBuzzMode, TimeBuzzMode.count);
      expect((await _boot({_key: 'binary'})).timeBuzzMode, TimeBuzzMode.binary);
      expect((await _boot({_key: 'morse'})).timeBuzzMode, TimeBuzzMode.morse);
    });

    test('a stored value that is not a mode reads as count', () async {
      expect((await _boot({_key: 'semaphore'})).timeBuzzMode,
          TimeBuzzMode.count);
      expect((await _boot({_key: ''})).timeBuzzMode, TimeBuzzMode.count);
    });

    test('listeners are told of a change, once, and not of a repeat',
        () async {
      final s = await _boot();
      var told = 0;
      s.addListener(() => told++);
      await s.setTimeBuzzMode(TimeBuzzMode.morse);
      expect(told, 1);
      await s.setTimeBuzzMode(TimeBuzzMode.morse);
      expect(told, 1, reason: 'the same mode again changes nothing');
      await s.setTimeBuzzMode(TimeBuzzMode.count);
      expect(told, 2);
    });

    test('the mode does not touch the action mapping', () async {
      final s = await _boot();
      await s.setDoubleTapActions({DeviceAction.logWater});
      await s.setTimeBuzzMode(TimeBuzzMode.binary);
      expect(s.doubleTapActions, {DeviceAction.logWater});
    });
  });

  group('Tell the time in the mapping', () {
    test('it is supported with no native capabilities (in-app)', () async {
      final s = await _boot();
      expect(s.supported, contains(DeviceAction.tellTime));
    });

    test('a mapping that includes it survives a restart', () async {
      final s = await _boot();
      await s.setDoubleTapActions({DeviceAction.tellTime});
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.doubleTapActions, {DeviceAction.tellTime});
    });

    test('it can be mapped to a counted tap too', () async {
      final s = await _boot();
      await s.setActionsForTaps(3, {DeviceAction.tellTime});
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.actionsForTaps(3), {DeviceAction.tellTime});
    });
  });
}
