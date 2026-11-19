// The Gestures screen and settings for 2–5 taps. 3–5 are counted
// as ECG-sensor touches after a double tap (WHOOP MG only). No 1-tap row.
//
// NOTE: the text guard in test/band_gestures_view_test.dart keeps forbidding
// one/single/1 tap but allows "3 tap"/"4 tap". The `tapCount` symbol
// ban there stays: nothing pinned here uses that identifier.

import 'package:flutter/material.dart' show ValueKey;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settings_sections.dart';

const _channel = MethodChannel('openstrap/device_actions');

Future<GestureSettings> _boot(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>['torch'];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
  DeviceAction.torch,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('GestureSettings: actions per tap count', () {
    test('2 taps is the existing double-tap mapping', () async {
      final s = await _boot({'gesture_double_tap_actions': 1 << 8});
      expect(s.actionsForTaps(2), {DeviceAction.markMoment});
      expect(s.actionsForTaps(2), s.doubleTapActions);
    });

    test('3–5 start empty; max mapped is 2', () async {
      final s = await _boot({});
      for (final n in [3, 4, 5]) {
        expect(s.actionsForTaps(n), isEmpty);
      }
      expect(s.maxMappedTaps, 2);
    });

    test('mapping 4 taps makes max 4, persisted across a restart', () async {
      final s = await _boot({});
      await s.setActionsForTaps(4, {DeviceAction.torch});
      expect(s.maxMappedTaps, 4);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('gesture_tap_actions_4'),
          GestureSettings.maskOf({DeviceAction.torch}));
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.actionsForTaps(4), {DeviceAction.torch});
      expect(again.maxMappedTaps, 4);
    });

    test('only 2..5 exist', () async {
      final s = await _boot({});
      for (final bad in [0, 1, 6]) {
        expect(() => s.actionsForTaps(bad), throwsArgumentError);
      }
    });
  });

  group('BandGesturesView tabs', () {

    testWidgets('the tabs count double taps on every band without an ECG option', (t) async {
      await pumpTall(
          t,
          const BandGesturesView(
              chosen: {},
              supported: _supported,

              devMode: true));
      for (final (n, label) in const [
        (3, '2 double taps'),
        (4, '3 double taps'),
        (5, '4 double taps'),
      ]) {
        await openGesturesTab(t, n);
        expect(gesturesTabName(t), label);
        expect(isDimmed(t, find.byKey(const ValueKey('gestures-tab-name'))),
            isFalse,
            reason: label);
      }
      expect(find.text('ECG sensor touches'), findsNothing);
      expect(find.text('This band has no ECG sensor'), findsNothing);
    });
  });
}
