// Gesture slots, the settings half (RED): per-slot options, the migration of
// the global Tell the time mode, overlaps(), and exclusive active modes
// enforced in the setters (not in the UI).
//
// Slot ids (stable, persisted): 'double', 'triple', 'quad', 'quint' = 2..5 taps.
// Per-slot options persist as a JSON object string under
// `gesture_slot_options_<slot>`, keyed `<action id>.<option id>`
// (`tell_time.mode` -> the mode's name). The global `gesture_time_buzz_mode`
// stays as the DEFAULT for every slot and is never deleted or rewritten by a
// slot change. The action bitmasks keep their keys:
// `gesture_double_tap_actions`, `gesture_tap_actions_3..5`.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/gesture_slots.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');
const _globalKey = 'gesture_time_buzz_mode';
String _slotKey(String slot) => 'gesture_slot_options_$slot';

// The exact texts the UI shows; pinned literally so a reword is a decision.
const _turnOthersOff =
    "ECG takes over the band while it records, so it can't share a gesture "
    'with other actions. Turn the others off first.';
const _turnEcgOff =
    "ECG takes over the band while it records, so it can't share a gesture "
    'with other actions. Turn ECG off first.';

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

Matcher _refused(String reason) => isA<ActionToggleRefusedExclusive>()
    .having((r) => r.reason, 'reason', reason)
    .having((r) => r.ok, 'ok', isFalse);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'capabilities') return <String>[];
        return false;
      }));
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('slot ids', () {
    test('the four slots and their stable ids', () {
      expect(GestureSlots.all, ['double', 'triple', 'quad', 'quint']);
      expect(GestureSlots.ecgSlot, 'double');
    });

    test('ofTaps / tapsOf map 2..5 both ways; anything else is an error', () {
      for (var n = 2; n <= 5; n++) {
        expect(GestureSlots.ofTaps(n), GestureSlots.all[n - 2]);
        expect(GestureSlots.tapsOf(GestureSlots.all[n - 2]), n);
      }
      for (final bad in [0, 1, 6]) {
        expect(() => GestureSlots.ofTaps(bad), throwsArgumentError);
      }
      expect(() => GestureSlots.tapsOf('sextuple'), throwsArgumentError);
    });

    test('display names, as the overlap warning says them', () {
      expect(GestureSlots.nameOf('double'), 'Double tap');
      expect(GestureSlots.nameOf('triple'), 'Triple tap');
      expect(GestureSlots.nameOf('quad'), 'Quadruple tap');
      expect(GestureSlots.nameOf('quint'), 'Quintuple tap');
    });
  });

  group('per-slot persistence', () {
    test('a slot keeps its own mode; the others stay on the default',
        () async {
      final s = await _boot();
      await s.setTimeBuzzModeFor('triple', TimeBuzzMode.morse);
      expect(s.timeBuzzModeFor('triple'), TimeBuzzMode.morse);
      expect(s.timeBuzzModeFor('double'), TimeBuzzMode.count);
      expect(s.timeBuzzModeFor('quad'), TimeBuzzMode.count);
      expect(s.timeBuzzModeFor('quint'), TimeBuzzMode.count);
    });

    test('stored as JSON under the slot key, keyed by the stable option id; '
        'other slots and the global key are not written', () async {
      final s = await _boot();
      await s.setTimeBuzzModeFor('triple', TimeBuzzMode.binary);
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(_slotKey('triple'))!),
          {'tell_time.mode': 'binary'});
      expect(prefs.containsKey(_slotKey('double')), isFalse);
      expect(prefs.containsKey(_globalKey), isFalse);
    });

    test('optionsFor exposes the stored values; a slot with none is empty',
        () async {
      final s = await _boot();
      await s.setTimeBuzzModeFor('quad', TimeBuzzMode.morse);
      expect(s.optionsFor('quad').values,
          {GestureSlotOptions.kTellTimeMode: 'morse'});
      expect(s.optionsFor('quad').timeBuzzMode, TimeBuzzMode.morse);
      expect(s.optionsFor('double').values, isEmpty);
      expect(s.optionsFor('double').timeBuzzMode, isNull,
          reason: 'no own choice: it follows the default');
    });

    test('round trip: every slot gets back its own mode after a restart',
        () async {
      final s = await _boot();
      const modes = {
        'double': TimeBuzzMode.binary,
        'triple': TimeBuzzMode.morse,
        'quad': TimeBuzzMode.count,
        'quint': TimeBuzzMode.binary,
      };
      for (final e in modes.entries) {
        await s.setTimeBuzzModeFor(e.key, e.value);
      }
      final again = await _restart();
      for (final e in modes.entries) {
        expect(again.timeBuzzModeFor(e.key), e.value, reason: e.key);
      }
    });

    test('listeners are told once per change, not for a repeat', () async {
      final s = await _boot();
      var told = 0;
      s.addListener(() => told++);
      await s.setTimeBuzzModeFor('double', TimeBuzzMode.morse);
      expect(told, 1);
      await s.setTimeBuzzModeFor('double', TimeBuzzMode.morse);
      expect(told, 1);
      await s.setTimeBuzzModeFor('triple', TimeBuzzMode.morse);
      expect(told, 2);
    });

    test('an unknown slot is an error', () async {
      final s = await _boot();
      expect(() => s.timeBuzzModeFor('sextuple'), throwsArgumentError);
      expect(() => s.optionsFor('sextuple'), throwsArgumentError);
      expect(() => s.setTimeBuzzModeFor('sextuple', TimeBuzzMode.binary),
          throwsArgumentError);
    });

    test('unreadable stored options read as no options, not a crash',
        () async {
      final s = await _boot({
        _globalKey: 'binary',
        _slotKey('double'): '{not json',
        _slotKey('triple'): '{"tell_time.mode":"semaphore"}',
        _slotKey('quad'): '[1,2]',
      });
      for (final slot in ['double', 'triple', 'quad']) {
        expect(s.timeBuzzModeFor(slot), TimeBuzzMode.binary, reason: slot);
      }
    });

    test('a slot mode does not touch the action mapping', () async {
      final s = await _boot();
      await s.setDoubleTapActions({DeviceAction.logWater});
      await s.setActionsForTaps(3, {DeviceAction.markMoment});
      await s.setTimeBuzzModeFor('double', TimeBuzzMode.morse);
      expect(s.doubleTapActions, {DeviceAction.logWater});
      expect(s.actionsForTaps(3), {DeviceAction.markMoment});
    });
  });

  group('migration of the global Tell the time mode', () {
    test('an existing user\'s global mode is every slot\'s default, with '
        'nothing rewritten', () async {
      final s = await _boot({_globalKey: 'morse'});
      for (final slot in GestureSlots.all) {
        expect(s.timeBuzzModeFor(slot), TimeBuzzMode.morse, reason: slot);
        expect(s.optionsFor(slot).values, isEmpty, reason: slot);
      }
      expect(s.timeBuzzMode, TimeBuzzMode.morse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_globalKey), 'morse',
          reason: 'the legacy key stays: it is still the default');
    });

    test('a slot override wins over the global default', () async {
      final s = await _boot({
        _globalKey: 'morse',
        _slotKey('triple'): '{"tell_time.mode":"binary"}',
      });
      expect(s.timeBuzzModeFor('triple'), TimeBuzzMode.binary);
      expect(s.timeBuzzModeFor('double'), TimeBuzzMode.morse);
      expect(s.timeBuzzModeFor('quint'), TimeBuzzMode.morse);
    });

    test('changing the global default moves the slots without an override '
        'and leaves the ones with one', () async {
      final s = await _boot({_globalKey: 'morse'});
      await s.setTimeBuzzModeFor('triple', TimeBuzzMode.binary);
      await s.setTimeBuzzMode(TimeBuzzMode.count);
      expect(s.timeBuzzModeFor('double'), TimeBuzzMode.count);
      expect(s.timeBuzzModeFor('triple'), TimeBuzzMode.binary);
      final again = await _restart();
      expect(again.timeBuzzModeFor('double'), TimeBuzzMode.count);
      expect(again.timeBuzzModeFor('triple'), TimeBuzzMode.binary);
    });

    test('setting a slot never rewrites the global key', () async {
      final s = await _boot({_globalKey: 'morse'});
      await s.setTimeBuzzModeFor('double', TimeBuzzMode.binary);
      expect((await SharedPreferences.getInstance()).getString(_globalKey),
          'morse');
      expect(s.timeBuzzMode, TimeBuzzMode.morse);
    });

    test('with no stored mode anywhere every slot is count', () async {
      final s = await _boot();
      for (final slot in GestureSlots.all) {
        expect(s.timeBuzzModeFor(slot), TimeBuzzMode.count, reason: slot);
      }
    });
  });

  group('overlaps()', () {
    test('nothing mapped, or every action on one slot only: empty', () async {
      final s = await _boot();
      expect(s.overlaps(), isEmpty);
      await s.setDoubleTapActions({DeviceAction.logWater});
      await s.setActionsForTaps(3, {DeviceAction.markMoment});
      expect(s.overlaps(), isEmpty);
    });

    test('an action on two slots lists both, in a map keyed by the action',
        () async {
      final s = await _boot();
      await s.setDoubleTapActions(
          {DeviceAction.markMoment, DeviceAction.logWater});
      await s.setActionsForTaps(3, {DeviceAction.markMoment});
      expect(s.overlaps(), {
        DeviceAction.markMoment: {'double', 'triple'},
      });
    });

    test('several overlapping actions and three-slot overlaps', () async {
      final s = await _boot();
      await s.setDoubleTapActions({DeviceAction.markMoment});
      await s.setActionsForTaps(3, {DeviceAction.markMoment});
      await s.setActionsForTaps(4,
          {DeviceAction.markMoment, DeviceAction.workoutToggle});
      await s.setActionsForTaps(5, {DeviceAction.workoutToggle});
      expect(s.overlaps(), {
        DeviceAction.markMoment: {'double', 'triple', 'quad'},
        DeviceAction.workoutToggle: {'quad', 'quint'},
      });
    });

    test('turning one side off clears the overlap', () async {
      final s = await _boot();
      await s.setDoubleTapActions({DeviceAction.markMoment});
      await s.setActionsForTaps(3, {DeviceAction.markMoment});
      expect(s.overlaps(), isNotEmpty);
      await s.setActionsForTaps(3, {});
      expect(s.overlaps(), isEmpty);
    });

    test('ECG on the double tap is a mode, not an action: never an overlap',
        () async {
      final s = await _boot();
      await s.setEcgOnDoubleTap(true);
      await s.setActionsForTaps(3, {DeviceAction.markMoment});
      expect(s.overlaps(), isEmpty);
    });
  });

  group('trySetAction', () {
    test('turns an action on and off for a slot, in the existing bitmask '
        'storage', () async {
      final s = await _boot();
      expect(await s.trySetAction('double', DeviceAction.logWater, true),
          isA<ActionToggleOk>());
      expect(await s.trySetAction('triple', DeviceAction.markMoment, true),
          isA<ActionToggleOk>());
      expect(s.doubleTapActions, {DeviceAction.logWater});
      expect(s.actionsForTaps(3), {DeviceAction.markMoment});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('gesture_double_tap_actions'),
          GestureSettings.maskOf({DeviceAction.logWater}));
      expect(prefs.getInt('gesture_tap_actions_3'),
          GestureSettings.maskOf({DeviceAction.markMoment}));
      expect(await s.trySetAction('double', DeviceAction.logWater, false),
          isA<ActionToggleOk>());
      expect(s.doubleTapActions, isEmpty);
      final again = await _restart();
      expect(again.actionsForTaps(3), {DeviceAction.markMoment});
    });

    test('two slots running the same action are independent switches',
        () async {
      final s = await _boot();
      await s.trySetAction('double', DeviceAction.markMoment, true);
      await s.trySetAction('triple', DeviceAction.markMoment, true);
      await s.trySetAction('double', DeviceAction.markMoment, false);
      expect(s.doubleTapActions, isEmpty);
      expect(s.actionsForTaps(3), {DeviceAction.markMoment});
    });

    test('an unknown slot is an error', () async {
      final s = await _boot();
      expect(() => s.trySetAction('sextuple', DeviceAction.logWater, true),
          throwsArgumentError);
    });
  });

  group('exclusive active modes (enforced in the setters)', () {
    test('no existing DeviceAction is an active mode: ECG is its own flag',
        () {
      for (final a in DeviceAction.values) {
        expect(a.isActiveMode, isFalse, reason: '$a');
      }
    });

    test('ECG on a slot with other actions is refused, with the reason, and '
        'nothing changes', () async {
      final s = await _boot();
      await s.trySetAction('double', DeviceAction.logWater, true);
      var told = 0;
      s.addListener(() => told++);
      final r = await s.trySetEcgOnDoubleTap(true);
      expect(r, _refused(_turnOthersOff));
      expect(r, _refused(kEcgExclusiveTurnOthersOff));
      expect(s.ecgOnDoubleTap, isFalse);
      expect(s.doubleTapActions, {DeviceAction.logWater});
      expect((await SharedPreferences.getInstance()).getBool(
          'gesture_ecg_on_double_tap'), isNull);
      expect(told, 0);
    });

    test('another action on a slot that has ECG is refused, with the reason, '
        'and nothing changes', () async {
      final s = await _boot();
      expect(await s.trySetEcgOnDoubleTap(true), isA<ActionToggleOk>());
      var told = 0;
      s.addListener(() => told++);
      final r = await s.trySetAction('double', DeviceAction.logWater, true);
      expect(r, _refused(_turnEcgOff));
      expect(r, _refused(kEcgExclusiveTurnEcgOff));
      expect(s.ecgOnDoubleTap, isTrue);
      expect(s.doubleTapActions, isEmpty);
      // bootstrap stores an empty mask (0); a refusal must leave it so.
      expect((await SharedPreferences.getInstance())
          .getInt('gesture_double_tap_actions') ?? 0, 0);
      expect(told, 0);
    });

    test('ECG on an empty double tap is fine, and survives a restart',
        () async {
      final s = await _boot();
      expect(await s.trySetEcgOnDoubleTap(true), isA<ActionToggleOk>());
      expect(s.ecgOnDoubleTap, isTrue);
      expect((await _restart()).ecgOnDoubleTap, isTrue);
    });

    test('turning ECG off, or an action off, is never refused', () async {
      final s = await _boot();
      await s.trySetEcgOnDoubleTap(true);
      expect(await s.trySetAction('double', DeviceAction.logWater, false),
          isA<ActionToggleOk>());
      expect(await s.trySetEcgOnDoubleTap(false), isA<ActionToggleOk>());
      expect(s.ecgOnDoubleTap, isFalse);
      expect(await s.trySetAction('double', DeviceAction.logWater, true),
          isA<ActionToggleOk>(),
          reason: 'with ECG off the slot takes actions again');
    });

    test('ECG is the double tap\'s: it does not block another slot, and '
        'another slot\'s actions do not block it', () async {
      final s = await _boot();
      await s.trySetAction('triple', DeviceAction.logWater, true);
      expect(await s.trySetEcgOnDoubleTap(true), isA<ActionToggleOk>());
      expect(await s.trySetAction('quad', DeviceAction.markMoment, true),
          isA<ActionToggleOk>());
      expect(s.actionsForTaps(3), {DeviceAction.logWater});
      expect(s.actionsForTaps(4), {DeviceAction.markMoment});
    });
  });
}
