// The Gestures screen and settings for 2–5 taps. 3–5 are DRAFT, counted
// as ECG-sensor touches after a double tap (WHOOP MG only). No 1-tap row.
//
// NOTE: the text guard in test/band_gestures_view_test.dart keeps forbidding
// one/single/1 tap but allows "3 tap"/"4 tap". The `tapCount` symbol
// ban there stays: nothing pinned here uses that identifier.

import 'package:flutter/material.dart' show ValueKey;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
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

  group('GestureSettings: ECG tap thresholds', () {
    test('defaults until changed', () async {
      final s = await _boot({});
      expect(s.ecgTapThresholds, EcgTapThresholds());
    });

    test('persisted as three ints and restored', () async {
      final s = await _boot({});
      var notified = 0;
      s.addListener(() => notified++);
      await s.setEcgTapThresholds(
          EcgTapThresholds(startMs: 500, gapMs: 250, confirmMs: 400));
      expect(notified, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('gesture_ecg_start_ms'), 500);
      expect(prefs.getInt('gesture_ecg_gap_ms'), 250);
      expect(prefs.getInt('gesture_ecg_confirm_ms'), 400);
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.ecgTapThresholds,
          EcgTapThresholds(startMs: 500, gapMs: 250, confirmMs: 400));
    });

    test('extra sensitive detection: off until changed, persisted, restored',
        () async {
      final s = await _boot({});
      expect(s.ecgTapThresholds.extraSensitive, isFalse);
      await s.setEcgTapThresholds(
          EcgTapThresholds(startMs: 500, extraSensitive: true));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gesture_ecg_extra_sensitive'), isTrue);
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.ecgTapThresholds,
          EcgTapThresholds(startMs: 500, extraSensitive: true));
    });

    test('tolerant startup and the double-tap fallback: on until changed, '
        'persisted under their own keys, restored', () async {
      final s = await _boot({});
      expect(s.ecgTapThresholds.tolerantStartup, isTrue);
      expect(s.ecgTapThresholds.fallbackToDoubleTap, isTrue);
      var notified = 0;
      s.addListener(() => notified++);
      await s.setEcgTapThresholds(EcgTapThresholds(
          tolerantStartup: false, fallbackToDoubleTap: false));
      expect(notified, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gesture_ecg_tolerant_startup'), isFalse);
      expect(prefs.getBool('gesture_ecg_fallback'), isFalse);
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.ecgTapThresholds.tolerantStartup, isFalse);
      expect(again.ecgTapThresholds.fallbackToDoubleTap, isFalse);
      expect(again.ecgTapThresholds,
          EcgTapThresholds(tolerantStartup: false, fallbackToDoubleTap: false));
    });

    test('the two switches are stored independently', () async {
      final s = await _boot({});
      await s.setEcgTapThresholds(EcgTapThresholds(tolerantStartup: false));
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gesture_ecg_tolerant_startup'), isFalse);
      expect(prefs.getBool('gesture_ecg_fallback'), isTrue);
      await s.setEcgTapThresholds(EcgTapThresholds(fallbackToDoubleTap: false));
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gesture_ecg_tolerant_startup'), isTrue);
      expect(prefs.getBool('gesture_ecg_fallback'), isFalse);
    });

    test('a user from before these switches (the keys are missing) gets both on, '
        'whatever else was stored', () async {
      final s = await _boot({
        'gesture_ecg_start_ms': 500,
        'gesture_ecg_extra_sensitive': true,
      });
      expect(s.ecgTapThresholds.tolerantStartup, isTrue);
      expect(s.ecgTapThresholds.fallbackToDoubleTap, isTrue);
      expect(s.ecgTapThresholds,
          EcgTapThresholds(startMs: 500, extraSensitive: true));
    });

    test('a stored false for one key does not touch the other', () async {
      final a = await _boot({'gesture_ecg_tolerant_startup': false});
      expect(a.ecgTapThresholds.tolerantStartup, isFalse);
      expect(a.ecgTapThresholds.fallbackToDoubleTap, isTrue);
      final b = await _boot({'gesture_ecg_fallback': false});
      expect(b.ecgTapThresholds.tolerantStartup, isTrue);
      expect(b.ecgTapThresholds.fallbackToDoubleTap, isFalse);
    });

    test('an invalid stored value falls back to that field\'s default',
        () async {
      final s = await _boot({
        'gesture_ecg_start_ms': 5000, // out of range
        'gesture_ecg_gap_ms': 333, // off step
        'gesture_ecg_confirm_ms': 450, // valid
      });
      expect(s.ecgTapThresholds,
          EcgTapThresholds(startMs: 300, gapMs: 200, confirmMs: 450));
    });
  });

  group('BandGesturesView tabs', () {
    testWidgets('Double tap + 0–3 ECG taps; 3–5 draft; no 1-tap tab',
        (t) async {
      await pumpTall(
          t,
          const BandGesturesView(
            chosen: {},
            supported: _supported,
            ecgSupported: true,
            tapMethod: TapCountMethod.ecg,
          ));
      const names = {
        2: 'Double tap',
        3: 'Double tap + 1 ECG tap',
        4: 'Double tap + 2 ECG taps',
        5: 'Double tap + 3 ECG taps',
      };
      for (final e in names.entries) {
        await openGesturesTab(t, e.key);
        expect(gesturesTabName(t), e.value);
        expect(find.textContaining('Draft'), e.key == 2 ? findsNothing : findsOneWidget,
            reason: e.value);
        expect(isDimmed(t, find.byKey(const ValueKey('gestures-tab-name'))),
            isFalse,
            reason: 'enabled on a WHOOP MG');
      }
      expect(find.text('1 tap'), findsNothing);
      expect(find.byKey(const ValueKey('gestures-tab:1')), findsNothing);
    });

    testWidgets('not a WHOOP MG: the tabs count double taps and are enabled; '
        'only the ECG option is disabled, with the reason', (t) async {
      await pumpTall(
          t,
          const BandGesturesView(
              chosen: {}, supported: _supported, ecgSupported: false));
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
      expect(isDimmed(t, find.text('ECG sensor touches')), isTrue);
      expect(find.text('This band has no ECG sensor'), findsWidgets);
    });
  });
}
