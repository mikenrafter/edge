// GestureSettings — double-tap mapping as an ordered SET of actions
// with a per-action "replay from history" flag.
//
// Persistence contract:
//   * `gesture_double_tap_actions` — int bitmask, bit i = DeviceAction.values[i].
//     Order is therefore always enum order, never the order the user tapped.
//   * `gesture_double_tap` (legacy single string id) is read ONCE as a one-bit
//     set when the new key is absent. It is NOT deleted: the one-time alert-rule
//     migration (lib/notify/notification_prefs.dart) still reads it.
//   * `gesture_replay_<action.id>` — bool, the user's explicit choice.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _maskKey = 'gesture_double_tap_actions';
const _legacyKey = 'gesture_double_tap';
const _channel = MethodChannel('openstrap/device_actions');

/// Answer `capabilities` with [native] ids (what the OS can do).
void _nativeCaps(List<String> native) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return native;
    return false;
  });
}

Future<GestureSettings> _boot(
  Map<String, Object> prefs, {
  List<String> native = const [
    'media_play_pause',
    'media_next',
    'media_prev',
    'volume_up',
    'volume_down',
    'ring_phone',
    'torch',
    'broadcast_to_tasker',
  ],
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  _nativeCaps(native);
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('the bitmask', () {
    test('bit positions are the enum positions, and they are frozen', () {
      // Persisted. Re-ordering the enum silently remaps every user's mapping.
      const frozen = {
        'none': 0,
        'media_play_pause': 1,
        'media_next': 2,
        'media_prev': 3,
        'volume_up': 4,
        'volume_down': 5,
        'ring_phone': 6,
        'torch': 7,
        'mark_moment': 8,
        'workout_toggle': 9,
        'log_water': 10,
        'broadcast_to_tasker': 11,
        'tell_time': 12,
      };
      expect(DeviceAction.values, hasLength(frozen.length));
      for (final a in DeviceAction.values) {
        expect(DeviceAction.values.indexOf(a), frozen[a.id], reason: a.id);
      }
      expect(GestureSettings.maskOf({DeviceAction.markMoment}), 1 << 8);
      expect(
          GestureSettings.maskOf(
              {DeviceAction.logWater, DeviceAction.markMoment}),
          (1 << 8) | (1 << 10));
    });

    test('none is the empty set: it never sets a bit', () {
      expect(GestureSettings.maskOf({DeviceAction.none}), 0);
      expect(GestureSettings.maskOf(const <DeviceAction>{}), 0);
      expect(GestureSettings.actionsOfMask(0), isEmpty);
      expect(GestureSettings.actionsOfMask(1), isEmpty,
          reason: 'bit 0 is none; it decodes to nothing');
    });

    test('every subset of the real actions round-trips', () {
      final real =
          DeviceAction.values.where((a) => a != DeviceAction.none).toList();
      for (var bits = 0; bits < (1 << real.length); bits++) {
        final subset = {
          for (var i = 0; i < real.length; i++)
            if (bits & (1 << i) != 0) real[i],
        };
        final mask = GestureSettings.maskOf(subset);
        expect(GestureSettings.actionsOfMask(mask), subset, reason: '$bits');
      }
    });

    test('decoding iterates in enum order and ignores bits it does not know',
        () {
      final decoded = GestureSettings.actionsOfMask((1 << 10) | (1 << 8) | (1 << 40));
      expect(decoded.toList(), [DeviceAction.markMoment, DeviceAction.logWater]);
    });
  });

  group('persistence', () {
    test('a fresh install maps nothing', () async {
      final s = await _boot({});
      expect(s.doubleTapActions, isEmpty);
      expect(s.hasActiveMapping, isFalse);
    });

    test('setDoubleTapActions persists the mask and survives a restart',
        () async {
      final s = await _boot({});
      await s.setDoubleTapActions(
          {DeviceAction.logWater, DeviceAction.markMoment});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_maskKey), (1 << 8) | (1 << 10));

      final restarted = GestureSettings();
      await restarted.bootstrap();
      expect(restarted.doubleTapActions,
          {DeviceAction.markMoment, DeviceAction.logWater});
      expect(restarted.hasActiveMapping, isTrue);
    });

    test('order is enum order, whatever order the user switched them on',
        () async {
      final a = await _boot({});
      await a.toggleDoubleTapAction(DeviceAction.logWater, true);
      await a.toggleDoubleTapAction(DeviceAction.torch, true);
      await a.toggleDoubleTapAction(DeviceAction.markMoment, true);
      final inA = (await SharedPreferences.getInstance()).getInt(_maskKey);

      final b = await _boot({});
      await b.toggleDoubleTapAction(DeviceAction.markMoment, true);
      await b.toggleDoubleTapAction(DeviceAction.torch, true);
      await b.toggleDoubleTapAction(DeviceAction.logWater, true);
      final inB = (await SharedPreferences.getInstance()).getInt(_maskKey);

      const expected = [
        DeviceAction.torch,
        DeviceAction.markMoment,
        DeviceAction.logWater,
      ];
      expect(a.doubleTapActions.toList(), expected);
      expect(b.doubleTapActions.toList(), expected);
      expect(inA, inB);
    });

    test('switching an action off removes it; the last one off is the empty set',
        () async {
      final s = await _boot({});
      await s.setDoubleTapActions({DeviceAction.markMoment, DeviceAction.torch});
      await s.toggleDoubleTapAction(DeviceAction.torch, false);
      expect(s.doubleTapActions, {DeviceAction.markMoment});
      await s.toggleDoubleTapAction(DeviceAction.markMoment, false);
      expect(s.doubleTapActions, isEmpty);
      expect(s.hasActiveMapping, isFalse);
      expect((await SharedPreferences.getInstance()).getInt(_maskKey), 0);
    });

    test('none can be neither switched on nor stored in the set', () async {
      final s = await _boot({});
      await s.toggleDoubleTapAction(DeviceAction.none, true);
      expect(s.doubleTapActions, isEmpty);
      await s.setDoubleTapActions({DeviceAction.none, DeviceAction.logWater});
      expect(s.doubleTapActions, {DeviceAction.logWater});
    });

    test('the exposed set cannot be mutated around the persistence', () async {
      final s = await _boot({});
      await s.setDoubleTapActions({DeviceAction.logWater});
      expect(() => s.doubleTapActions.add(DeviceAction.torch),
          throwsUnsupportedError);
    });

    test('listeners hear a real change once, and a no-op not at all', () async {
      final s = await _boot({});
      var n = 0;
      s.addListener(() => n++);
      await s.toggleDoubleTapAction(DeviceAction.logWater, true);
      expect(n, 1);
      await s.toggleDoubleTapAction(DeviceAction.logWater, true);
      expect(n, 1, reason: 'already on');
      await s.toggleDoubleTapAction(DeviceAction.torch, false);
      expect(n, 1, reason: 'already off');
    });
  });

  group('migration from the single-action key', () {
    test('an old string id becomes a one-bit set', () async {
      final s = await _boot({_legacyKey: 'log_water'});
      expect(s.doubleTapActions, {DeviceAction.logWater});
      expect(s.hasActiveMapping, isTrue);
      expect((await SharedPreferences.getInstance()).getInt(_maskKey), 1 << 10);
    });

    test('the legacy key is left in place for the alert-rule migration',
        () async {
      await _boot({_legacyKey: 'mark_moment'});
      expect((await SharedPreferences.getInstance()).getString(_legacyKey),
          'mark_moment');
    });

    test('after migrating, the new key alone is enough', () async {
      await _boot({_legacyKey: 'mark_moment'});
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyKey);
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.doubleTapActions, {DeviceAction.markMoment});
    });

    test('old "none" and unknown ids become the empty set', () async {
      expect((await _boot({_legacyKey: 'none'})).doubleTapActions, isEmpty);
      expect((await _boot({_legacyKey: 'not_an_action'})).doubleTapActions,
          isEmpty);
    });

    test('when both keys exist the new one wins', () async {
      final s = await _boot({
        _legacyKey: 'log_water',
        _maskKey: 1 << 8,
      });
      expect(s.doubleTapActions, {DeviceAction.markMoment});
    });

    test('an old native choice this phone cannot do is dropped, not kept',
        () async {
      final s = await _boot({_legacyKey: 'ring_phone'}, native: const []);
      expect(s.doubleTapActions, isEmpty);
    });
  });

  group('bootstrap drops what this phone cannot do', () {
    test('unsupported native actions leave the set and the stored mask', () async {
      final s = await _boot(
        {
          _maskKey: GestureSettings.maskOf({
            DeviceAction.ringPhone,
            DeviceAction.torch,
            DeviceAction.logWater,
          }),
        },
        native: const ['torch'],
      );
      expect(s.doubleTapActions, {DeviceAction.torch, DeviceAction.logWater});
      expect((await SharedPreferences.getInstance()).getInt(_maskKey),
          GestureSettings.maskOf({DeviceAction.torch, DeviceAction.logWater}));
    });

    test('in-app actions are supported with no native channel at all', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      SharedPreferences.setMockInitialValues({
        _maskKey: GestureSettings.maskOf({
          DeviceAction.markMoment,
          DeviceAction.workoutToggle,
          DeviceAction.logWater,
          DeviceAction.torch,
        }),
      });
      final s = GestureSettings();
      await s.bootstrap();
      expect(s.doubleTapActions, {
        DeviceAction.markMoment,
        DeviceAction.workoutToggle,
        DeviceAction.logWater,
      });
    });
  });

  group('supportsHistoricalReplay', () {
    test('only Mark moment may be replayed from history in this phase', () {
      for (final a in DeviceAction.values) {
        expect(a.supportsHistoricalReplay, a == DeviceAction.markMoment,
            reason: a.id);
      }
    });
  });

  group('replayHistorical', () {
    const replayKey = 'gesture_replay_mark_moment';

    test('Mark moment defaults to ON once selected, and to off before that',
        () async {
      final s = await _boot({});
      expect(s.replayHistorical(DeviceAction.markMoment), isFalse);
      await s.toggleDoubleTapAction(DeviceAction.markMoment, true);
      expect(s.replayHistorical(DeviceAction.markMoment), isTrue);
      await s.toggleDoubleTapAction(DeviceAction.markMoment, false);
      expect(s.replayHistorical(DeviceAction.markMoment), isFalse);
    });

    test('actions that cannot be replayed are never replayed', () async {
      final s = await _boot({});
      await s.setDoubleTapActions({
        DeviceAction.logWater,
        DeviceAction.torch,
        DeviceAction.workoutToggle,
      });
      for (final a in s.doubleTapActions) {
        expect(s.replayHistorical(a), isFalse, reason: a.id);
      }
      await s.setReplayHistorical(DeviceAction.logWater, true);
      expect(s.replayHistorical(DeviceAction.logWater), isFalse,
          reason: 'asking for it does not make it safe');
    });

    test('a stored "true" for a non-replayable action is ignored on load',
        () async {
      final s = await _boot({
        _maskKey: 1 << 10,
        'gesture_replay_log_water': true,
        'gesture_replay_torch': true,
      });
      expect(s.replayHistorical(DeviceAction.logWater), isFalse);
      expect(s.replayHistorical(DeviceAction.torch), isFalse);
    });

    test('the user can turn it off, and that survives a restart', () async {
      final s = await _boot({});
      await s.toggleDoubleTapAction(DeviceAction.markMoment, true);
      await s.setReplayHistorical(DeviceAction.markMoment, false);
      expect(s.replayHistorical(DeviceAction.markMoment), isFalse);
      expect((await SharedPreferences.getInstance()).getBool(replayKey), false);

      final restarted = GestureSettings();
      await restarted.bootstrap();
      expect(restarted.doubleTapActions, {DeviceAction.markMoment});
      expect(restarted.replayHistorical(DeviceAction.markMoment), isFalse);
    });

    test('deselect then reselect keeps the last EXPLICIT choice (off)', () async {
      final s = await _boot({});
      await s.toggleDoubleTapAction(DeviceAction.markMoment, true);
      await s.setReplayHistorical(DeviceAction.markMoment, false);
      await s.toggleDoubleTapAction(DeviceAction.markMoment, false);
      await s.toggleDoubleTapAction(DeviceAction.markMoment, true);
      expect(s.replayHistorical(DeviceAction.markMoment), isFalse);
    });

    test('deselect then reselect keeps the last EXPLICIT choice (on)', () async {
      final s = await _boot({});
      await s.toggleDoubleTapAction(DeviceAction.markMoment, true);
      await s.setReplayHistorical(DeviceAction.markMoment, false);
      await s.setReplayHistorical(DeviceAction.markMoment, true);
      await s.toggleDoubleTapAction(DeviceAction.markMoment, false);
      await s.toggleDoubleTapAction(DeviceAction.markMoment, true);
      expect(s.replayHistorical(DeviceAction.markMoment), isTrue);
    });

    test('replayActions is what the dispatcher and the UI both read', () async {
      final s = await _boot({});
      expect(s.replayActions, isEmpty);
      await s.setDoubleTapActions(
          {DeviceAction.markMoment, DeviceAction.logWater});
      expect(s.replayActions, {DeviceAction.markMoment});
      await s.setReplayHistorical(DeviceAction.markMoment, false);
      expect(s.replayActions, isEmpty);
    });

    test('a replay change notifies listeners', () async {
      final s = await _boot({});
      await s.toggleDoubleTapAction(DeviceAction.markMoment, true);
      var n = 0;
      s.addListener(() => n++);
      await s.setReplayHistorical(DeviceAction.markMoment, false);
      expect(n, 1);
    });
  });
}
