// DeviceAction.breathe and its per-slot options (RED).
//
// Id stability: the enum order IS the persisted bitmask, so `breathe` is
// appended after tellTime (index 13) and its wire id 'breathe' never changes.
// Per-slot options persist as the slot's JSON object under
// `gesture_slot_options_<slot>`, keyed `breathe.pattern` (a BreathPattern.key,
// default 'resonance') and `breathe.minutes` (one of 1, 2, 3, 5, 10; default
// 3), beside any other option the slot holds (tell_time.mode).

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/gesture_slots.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');
String _slotKey(String slot) => 'gesture_slot_options_$slot';

Future<GestureSettings> _boot([Map<String, Object> stored = const {}]) async {
  SharedPreferences.setMockInitialValues({...stored});
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

Future<GestureSettings> _restart() async {
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

  group('the action', () {
    test('wire id, label, blurb and kind', () {
      expect(DeviceAction.breathe.id, 'breathe');
      expect(DeviceAction.breathe.label, 'Breathing exercise');
      expect(DeviceAction.breathe.blurb, isNotEmpty);
      expect(DeviceAction.breathe.isInApp, isTrue);
      expect(DeviceAction.breathe.isNative, isFalse);
      expect(DeviceAction.breathe.isActiveMode, isFalse);
      expect(DeviceAction.breathe.supportsHistoricalReplay, isFalse,
          reason: 'a late tap must never start a session');
      expect(DeviceActionX.fromId('breathe'), DeviceAction.breathe);
    });

    test('appended after tellTime: the persisted bit positions of every '
        'earlier action are untouched', () {
      expect(DeviceAction.values.indexOf(DeviceAction.tellTime), 12);
      expect(DeviceAction.values.indexOf(DeviceAction.breathe), 13);
      expect(DeviceAction.values.last, DeviceAction.breathe);
      expect(GestureSettings.maskOf({DeviceAction.breathe}), 1 << 13);
      expect(GestureSettings.maskOf({DeviceAction.tellTime}), 1 << 12);
      expect(GestureSettings.actionsOfMask(1 << 13), {DeviceAction.breathe});
    });

    test('it is offered on every platform (in-app) and survives a restart '
        'on the double tap and on a counted slot', () async {
      final s = await _boot();
      expect(s.supported, contains(DeviceAction.breathe));
      await s.setDoubleTapActions({DeviceAction.breathe});
      await s.setActionsForTaps(4, {DeviceAction.breathe, DeviceAction.tellTime});
      final again = await _restart();
      expect(again.doubleTapActions, {DeviceAction.breathe});
      expect(again.actionsForTaps(4),
          {DeviceAction.breathe, DeviceAction.tellTime});
    });
  });

  group('per-slot options', () {
    test('defaults: resonance, 3 minutes, on every slot', () async {
      final s = await _boot();
      for (final slot in GestureSlots.all) {
        expect(s.breathePatternFor(slot), 'resonance', reason: slot);
        expect(s.breatheMinutesFor(slot), 3, reason: slot);
        expect(s.optionsFor(slot).values, isEmpty, reason: slot);
      }
      expect(kBreatheDefaultPattern, 'resonance');
      expect(kBreatheDefaultMinutes, 3);
    });

    test('the choices are 1, 2, 3, 5 and 10 minutes', () {
      expect(kBreatheMinuteChoices, [1, 2, 3, 5, 10]);
    });

    test('every pattern key and every length can be chosen', () async {
      final s = await _boot();
      for (final p in kBreathPatterns) {
        await s.setBreathePatternFor('double', p.key);
        expect(s.breathePatternFor('double'), p.key);
      }
      for (final m in kBreatheMinuteChoices) {
        await s.setBreatheMinutesFor('double', m);
        expect(s.breatheMinutesFor('double'), m);
      }
    });

    test('a slot keeps its own pattern and length; the others stay on the '
        'defaults', () async {
      final s = await _boot();
      await s.setBreathePatternFor('triple', 'box');
      await s.setBreatheMinutesFor('quad', 10);
      expect(s.breathePatternFor('triple'), 'box');
      expect(s.breatheMinutesFor('triple'), 3);
      expect(s.breathePatternFor('quad'), 'resonance');
      expect(s.breatheMinutesFor('quad'), 10);
      for (final slot in ['double', 'quint']) {
        expect(s.breathePatternFor(slot), 'resonance', reason: slot);
        expect(s.breatheMinutesFor(slot), 3, reason: slot);
      }
    });

    test('stored as JSON under the slot key with the stable option ids; '
        'other slots are not written', () async {
      final s = await _boot();
      await s.setBreathePatternFor('triple', 'four_seven_eight');
      await s.setBreatheMinutesFor('triple', 5);
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(_slotKey('triple'))!),
          {'breathe.pattern': 'four_seven_eight', 'breathe.minutes': '5'});
      expect(GestureSlotOptions.kBreathePattern, 'breathe.pattern');
      expect(GestureSlotOptions.kBreatheMinutes, 'breathe.minutes');
      expect(prefs.containsKey(_slotKey('double')), isFalse);
      expect(s.optionsFor('triple').values, {
        'breathe.pattern': 'four_seven_eight',
        'breathe.minutes': '5',
      });
    });

    test('round trip: every slot gets back its own pattern and length after '
        'a restart', () async {
      final s = await _boot();
      const want = {
        'double': ('box', 1),
        'triple': ('extended_exhale', 2),
        'quad': ('four_seven_eight', 5),
        'quint': ('resonance', 10),
      };
      for (final e in want.entries) {
        await s.setBreathePatternFor(e.key, e.value.$1);
        await s.setBreatheMinutesFor(e.key, e.value.$2);
      }
      final again = await _restart();
      for (final e in want.entries) {
        expect(again.breathePatternFor(e.key), e.value.$1, reason: e.key);
        expect(again.breatheMinutesFor(e.key), e.value.$2, reason: e.key);
      }
    });

    test('they sit beside Tell the time\'s mode in the same slot and neither '
        'overwrites the other', () async {
      final s = await _boot();
      await s.setTimeBuzzModeFor('double', TimeBuzzMode.morse);
      await s.setBreathePatternFor('double', 'box');
      await s.setTimeBuzzModeFor('double', TimeBuzzMode.binary);
      await s.setBreatheMinutesFor('double', 2);
      final again = await _restart();
      expect(again.timeBuzzModeFor('double'), TimeBuzzMode.binary);
      expect(again.breathePatternFor('double'), 'box');
      expect(again.breatheMinutesFor('double'), 2);
    });

    test('listeners are told once per change, not for a repeat', () async {
      final s = await _boot();
      var told = 0;
      s.addListener(() => told++);
      await s.setBreathePatternFor('double', 'box');
      expect(told, 1);
      await s.setBreathePatternFor('double', 'box');
      expect(told, 1);
      await s.setBreatheMinutesFor('double', 5);
      expect(told, 2);
      await s.setBreatheMinutesFor('double', 5);
      expect(told, 2);
    });

    test('a choice that is not offered is an error and writes nothing',
        () async {
      final s = await _boot();
      await expectLater(
          s.setBreathePatternFor('double', 'wim_hof'), throwsArgumentError);
      await expectLater(s.setBreatheMinutesFor('double', 4), throwsArgumentError);
      await expectLater(s.setBreatheMinutesFor('double', 0), throwsArgumentError);
      await expectLater(s.setBreatheMinutesFor('double', 11), throwsArgumentError);
      expect(s.optionsFor('double').values, isEmpty);
      expect((await SharedPreferences.getInstance()).containsKey(_slotKey('double')),
          isFalse);
    });

    test('an unknown slot is an error', () async {
      final s = await _boot();
      expect(() => s.breathePatternFor('sextuple'), throwsArgumentError);
      expect(() => s.breatheMinutesFor('sextuple'), throwsArgumentError);
      await expectLater(
          s.setBreathePatternFor('sextuple', 'box'), throwsArgumentError);
      await expectLater(
          s.setBreatheMinutesFor('sextuple', 5), throwsArgumentError);
    });

    test('unreadable stored values read as the defaults, not a crash',
        () async {
      final s = await _boot({
        _slotKey('double'): '{"breathe.pattern":"wim_hof","breathe.minutes":"7"}',
        _slotKey('triple'): '{"breathe.minutes":"lots"}',
        _slotKey('quad'): '{not json',
      });
      for (final slot in ['double', 'triple', 'quad']) {
        expect(s.breathePatternFor(slot), 'resonance', reason: slot);
        expect(s.breatheMinutesFor(slot), 3, reason: slot);
      }
    });

    test('a valid stored half is kept when the other half is unreadable',
        () async {
      final s = await _boot({
        _slotKey('double'): '{"breathe.pattern":"box","breathe.minutes":"7"}',
      });
      expect(s.breathePatternFor('double'), 'box');
      expect(s.breatheMinutesFor('double'), 3);
    });

    test('a breathing option does not touch the action mapping', () async {
      final s = await _boot();
      await s.setDoubleTapActions({DeviceAction.breathe});
      await s.setActionsForTaps(3, {DeviceAction.logWater});
      await s.setBreathePatternFor('double', 'box');
      await s.setBreatheMinutesFor('triple', 10);
      expect(s.doubleTapActions, {DeviceAction.breathe});
      expect(s.actionsForTaps(3), {DeviceAction.logWater});
    });
  });
}
