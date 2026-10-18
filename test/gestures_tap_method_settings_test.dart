// How extra taps are counted, and the repeated-double-tap window. One mapping
// store (slot n = n taps) serves both methods; only the method choice and the
// window are new. Persisted in the existing gesture preferences; no migration.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');

Future<GestureSettings> _boot(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('method choice', () {
    test('default: repeated double taps on every band, an MG included',
        () async {
      final s = await _boot({});
      expect(s.tapMethodChoice, isNull);
      expect(s.tapMethodFor(ecgSupported: true), TapCountMethod.repeat);
      expect(s.tapMethodFor(ecgSupported: false), TapCountMethod.repeat);
    });

    test('a chosen method is kept on an MG, persisted, and restored', () async {
      final s = await _boot({});
      var notified = 0;
      s.addListener(() => notified++);
      await s.setTapMethod(TapCountMethod.ecg);
      expect(notified, 1);
      expect(s.tapMethodFor(ecgSupported: true), TapCountMethod.ecg);
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.tapMethodFor(ecgSupported: true), TapCountMethod.ecg);
      await s.setTapMethod(TapCountMethod.repeat);
      expect(s.tapMethodFor(ecgSupported: true), TapCountMethod.repeat);
    });

    test('a band without ECG always counts double taps, whatever is stored',
        () async {
      final s = await _boot({'gesture_tap_method': 'ecg'});
      expect(s.tapMethodFor(ecgSupported: false), TapCountMethod.repeat);
      expect(s.tapMethodFor(ecgSupported: true), TapCountMethod.ecg);
    });

    test('an unknown stored value follows the default', () async {
      final s = await _boot({'gesture_tap_method': 'telepathy'});
      expect(s.tapMethodChoice, isNull);
      expect(s.tapMethodFor(ecgSupported: true), TapCountMethod.repeat);
    });

    test('both methods share the one mapping store', () async {
      final s = await _boot({});
      await s.setActionsForTaps(3, {DeviceAction.logWater});
      await s.setTapMethod(TapCountMethod.repeat);
      expect(s.actionsForTaps(3), {DeviceAction.logWater});
      expect(s.maxMappedTaps, 3);
    });
  });

  group('ECG Fast mode is retired', () {
    test('GestureSettings has no tap-mode setting and ignores a stored one',
        () async {
      final s = await _boot({'gesture_ecg_tap_mode': 'fast'});
      expect(() => (s as dynamic).ecgTapMode, throwsNoSuchMethodError);
      expect(() => (s as dynamic).setEcgTapMode, throwsNoSuchMethodError);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gesture_ecg_tap_mode'), 'fast',
          reason: 'an orphaned value is left alone, not migrated');
    });
  });

  group('repeat window', () {
    test('defaults to 2500 ms; range 1000..5000 in 250 ms steps', () async {
      final s = await _boot({});
      expect(s.repeatTapWindowMs, 2500);
      expect(s.repeatTapWindow, const Duration(milliseconds: 2500));
      expect(GestureSettings.repeatWindowRange, (1000, 5000));
      expect(GestureSettings.repeatWindowStepMs, 250);
    });

    test('persisted and restored', () async {
      final s = await _boot({});
      await s.setRepeatTapWindowMs(4250);
      expect(s.repeatTapWindowMs, 4250);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('gesture_repeat_window_ms'), 4250);
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.repeatTapWindowMs, 4250);
    });

    test('a value off the grid or out of range is rejected, not clamped',
        () async {
      final s = await _boot({});
      for (final bad in [900, 5250, 2600, 0, -250]) {
        expect(() => s.setRepeatTapWindowMs(bad), throwsArgumentError,
            reason: '$bad');
      }
      expect(s.repeatTapWindowMs, 2500);
    });

    test('an invalid stored value falls back to the default', () async {
      expect((await _boot({'gesture_repeat_window_ms': 777})).repeatTapWindowMs,
          2500);
      expect(
          (await _boot({'gesture_repeat_window_ms': 9000})).repeatTapWindowMs,
          2500);
    });

    test('the ends of the range are valid', () async {
      final s = await _boot({});
      await s.setRepeatTapWindowMs(1000);
      expect(s.repeatTapWindowMs, 1000);
      await s.setRepeatTapWindowMs(5000);
      expect(s.repeatTapWindowMs, 5000);
    });
  });

  group('the lab can try double taps', () {
    test('off by default, persisted, and 5 taps wide while on', () async {
      final s = await _boot({});
      expect(s.repeatTapsLab, isFalse);
      expect(s.repeatTapMax, 2);
      await s.setRepeatTapsLab(true);
      expect(s.repeatTapMax, 5);
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.repeatTapsLab, isTrue);
      await s.setRepeatTapsLab(false);
      await s.setActionsForTaps(4, {DeviceAction.logWater});
      expect(s.repeatTapMax, 4);
    });

    test('the two lab switches are exclusive: turning one on turns off the '
        'other', () async {
      final s = await _boot({});
      await s.setEcgOnDoubleTap(true);
      await s.setRepeatTapsLab(true);
      expect(s.repeatTapsLab, isTrue);
      expect(s.ecgOnDoubleTap, isFalse);
      await s.setEcgOnDoubleTap(true);
      expect(s.ecgOnDoubleTap, isTrue);
      expect(s.repeatTapsLab, isFalse);
    });
  });
}
