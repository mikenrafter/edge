// "Tell the time" through the GestureDispatcher, DeviceAction and the tap ack.
//
// New API pinned:
//   GestureDispatcher(onTellTime: TellTimeHandler?, now: DateTime Function()?)
//     A live double tap with DeviceAction.tellTime mapped runs the in-app action
//     like the others (stale rule, once-ever claim, failure = claim given
//     back), except that it reads the local time from `now` (default
//     package:clock's clock.now()) EVERY time it runs, encodes it in
//     GestureSettings.timeBuzzMode, and hands the tap and the elements to
//     onTellTime, which plays them as a gesture (GestureController). No handler
//     is a failed action, like any in-app action.
//   The haptic budget rule is the existing hapticsAvailable gate: no room for a
//     gesture's start means no action, no claim, no handler call.
//   shouldAckTap: a tap whose only action to run was tellTime is not
//     acknowledged (the time buzz IS the answer; the confirm cue after a 20 s
//     time would be a stray buzz).
//
// Notation: S short, L long, C click, g gap, P pause.

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';
import 'package:openstrap_edge/gestures/time_buzz.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/double_tap_repeat_rig.dart' show repTap;

const _sh = TimeBuzzElement.short;
const _lg = TimeBuzzElement.long;
const _ck = TimeBuzzElement.click;
const _g = TimeBuzzElement.gap;
const _ps = TimeBuzzElement.pause;

const _channel = MethodChannel('openstrap/device_actions');

List<TimeBuzzElement> _e(String s) => [
      for (final t in s.trim().split(RegExp(r'\s+')))
        switch (t) {
          'S' => _sh,
          'L' => _lg,
          'C' => _ck,
          'g' => _g,
          'P' => _ps,
          _ => throw ArgumentError('bad token $t'),
        },
    ];

Future<GestureSettings> _boot(
    {Set<DeviceAction> actions = const {DeviceAction.tellTime}}) async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  await s.setDoubleTapActions(actions);
  return s;
}

class _Rig {
  _Rig(
    this.settings, {
    this.open = true,
    this.failTime = false,
    this.withHandler = true,
    DateTime? at,
    bool withNow = true,
  }) : clockNow = at ?? DateTime(2026, 10, 7, 15, 8) {
    dispatcher = GestureDispatcher(
      settings: settings,
      performNative: (_) async => true,
      claim: (k) async => claims.add(k),
      release: (k) async => claims.remove(k),
      onWorkoutToggle: (e) async => ran.add('workout'),
      onTellTime: withHandler
          ? (e, elements) async {
              played.add((e, elements));
              if (failTime) throw StateError('band said no');
            }
          : null,
      now: withNow ? () => clockNow : null,
      onFailed: (e, kind, reason) => failed.add(reason),
      hapticsAvailable: () => open,
    );
  }

  final GestureSettings settings;
  bool open;
  final bool failTime;
  final bool withHandler;

  /// What the injected clock answers; change it between taps.
  DateTime clockNow;
  late final GestureDispatcher dispatcher;
  final claims = <String>{};
  final ran = <String>[];
  final failed = <String>[];
  final played = <(StrapEvent, List<TimeBuzzElement>)>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('DeviceAction.tellTime', () {
    test('its wire id is tell_time, and it round-trips', () {
      expect(DeviceAction.tellTime.id, 'tell_time');
      expect(DeviceActionX.fromId('tell_time'), DeviceAction.tellTime);
    });

    test('its label is "Tell the time"', () {
      expect(DeviceAction.tellTime.label, 'Tell the time');
      expect(DeviceAction.tellTime.blurb, isNotEmpty);
    });

    test('every wire id is still unique and the old ones did not move', () {
      final ids = DeviceAction.values.map((a) => a.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(DeviceAction.mediaPlayPause.id, 'media_play_pause');
      expect(DeviceAction.broadcastToTasker.id, 'broadcast_to_tasker');
      expect(DeviceAction.logWater.id, 'log_water');
    });

    test('it is appended: the enum order is the persisted bitmask, so no old '
        'action changes its bit', () {
      expect(DeviceAction.values.indexOf(DeviceAction.breathe),
          DeviceAction.values.indexOf(DeviceAction.tellTime) + 1,
          reason: 'only Breathing exercise was appended after it');
      expect(DeviceAction.values.indexOf(DeviceAction.broadcastToTasker), 11);
      expect(DeviceAction.values.indexOf(DeviceAction.tellTime), 12);
      expect(GestureSettings.maskOf({DeviceAction.tellTime}), 1 << 12);
      expect(GestureSettings.actionsOfMask(1 << 12), {DeviceAction.tellTime});
    });

    test('it is an in-app action: handled in Dart, never sent to the native '
        'channel, offered on every platform', () {
      expect(DeviceAction.tellTime.isInApp, isTrue);
      expect(DeviceAction.tellTime.isNative, isFalse);
    });

    test('it is never replayed from history: a time buzzed hours late is '
        'wrong', () {
      expect(DeviceAction.tellTime.supportsHistoricalReplay, isFalse);
    });
  });

  group('a live double tap with Tell the time mapped', () {
    test('plays the time once: the tap and the encoded elements of the '
        'injected clock (15:08, count) reach the handler', () async {
      final r = _Rig(await _boot());
      final tap = repTap();
      final out = await r.dispatcher.handle(tap);
      expect(out.map((o) => o.action), [DeviceAction.tellTime]);
      expect(out.single.status, GestureStatus.ran);
      expect(r.played, hasLength(1));
      expect(identical(r.played.single.$1, tap), isTrue);
      expect(r.played.single.$2, _e('L g L g L P C'));
      expect(r.claims.single, contains('tell_time'));
      expect(r.failed, isEmpty);
    });

    test('it never goes to the native channel', () async {
      final s = await _boot();
      final native = <String>[];
      final d = GestureDispatcher(
        settings: s,
        performNative: (id) async {
          native.add(id);
          return true;
        },
        claim: (_) async => true,
        release: (_) async {},
        onTellTime: (e, el) async {},
        now: () => DateTime(2026, 10, 7, 15, 8),
      );
      await d.handle(repTap());
      expect(native, isEmpty);
    });

    test('the injected clock is read when the action runs, every time, not '
        'when the dispatcher is built', () async {
      final r = _Rig(await _boot(), at: DateTime(2026, 10, 7, 3, 0));
      await r.dispatcher.handle(repTap());
      r.clockNow = DateTime(2026, 10, 7, 15, 7);
      await r.dispatcher.handle(repTap(sec: 5));
      r.clockNow = DateTime(2026, 10, 7, 0, 53);
      await r.dispatcher.handle(repTap(sec: 10));
      expect(r.played.map((p) => p.$2), [
        _e('S g S g S'),
        _e('L g L g L'),
        _e('${List.filled(12, 'S').join(' g ')} P C g C g C g C'),
      ]);
    });

    test('with no clock injected it reads package:clock\'s clock.now() (the '
        'wall clock fields are what is encoded)', () async {
      final r = _Rig(await _boot(), withNow: false);
      await withClock(Clock.fixed(DateTime(2026, 10, 7, 9, 0)),
          () => r.dispatcher.handle(repTap()));
      expect(r.played.single.$2, _e(List.filled(9, 'S').join(' g ')));
    });

    test('the encoding follows GestureSettings.timeBuzzMode, read on every '
        'run', () async {
      final s = await _boot();
      final r = _Rig(s);
      await s.setTimeBuzzMode(TimeBuzzMode.binary);
      await r.dispatcher.handle(repTap());
      await s.setTimeBuzzMode(TimeBuzzMode.morse);
      await r.dispatcher.handle(repTap(sec: 5));
      await s.setTimeBuzzMode(TimeBuzzMode.count);
      await r.dispatcher.handle(repTap(sec: 10));
      expect(r.played.map((p) => p.$2), [
        _e('S g S g L g L P L P C'), // binary 3:08 PM
        _e('S g S g S g L g L P S g L g L g S P C'), // morse 3:08 PM
        _e('L g L g L P C'), // count
      ]);
    });

    test('a handler that throws is a failed outcome, the claim goes back and '
        'the failure is reported with the action named', () async {
      final r = _Rig(await _boot(), failTime: true);
      final out = await r.dispatcher.handle(repTap());
      expect(out.single.status, GestureStatus.failed);
      expect(out.single.error, isA<StateError>());
      expect(r.claims, isEmpty, reason: 'given back so a re-send can retry');
      expect(r.failed.single, startsWith('tell_time'));
    });

    test('no handler wired is a failed action, like any in-app action (an '
        'offered action that does nothing is the failure the picker exists to '
        'end)', () async {
      final r = _Rig(await _boot(), withHandler: false);
      final out = await r.dispatcher.handle(repTap());
      expect(out.single.status, GestureStatus.failed);
      expect(r.played, isEmpty);
    });

    test('a re-sent tap (same identity) tells the time once', () async {
      final r = _Rig(await _boot());
      final tap = repTap();
      await r.dispatcher.handle(tap);
      final again = await r.dispatcher.handle(tap);
      expect(again.single.status, GestureStatus.skippedDuplicate);
      expect(r.played, hasLength(1));
    });

    test('a late tap (replayed from the band\'s flash) tells nothing and '
        'takes no claim', () async {
      final r = _Rig(await _boot());
      final out =
          await r.dispatcher.handle(repTap(late: const Duration(seconds: 30)));
      expect(out.single.status, GestureStatus.skippedStale);
      expect(r.played, isEmpty);
      expect(r.claims, isEmpty);
    });

    test('with other actions mapped each runs; a failing time does not stop '
        'the workout', () async {
      final r = _Rig(
          await _boot(
              actions: {DeviceAction.workoutToggle, DeviceAction.tellTime}),
          failTime: true);
      final out = await r.dispatcher.handle(repTap());
      expect(out.map((o) => (o.action, o.status)), [
        (DeviceAction.workoutToggle, GestureStatus.ran),
        (DeviceAction.tellTime, GestureStatus.failed),
      ]);
      expect(r.ran, ['workout']);
    });
  });

  group('the haptic budget (a gesture with no room for its start is not '
      'acted on)', () {
    test('no budget: no time, no claim, no handler call, no failure',
        () async {
      final r = _Rig(await _boot(), open: false);
      final out = await r.dispatcher.handle(repTap());
      expect(out, isEmpty);
      expect(r.played, isEmpty);
      expect(r.claims, isEmpty);
      expect(r.failed, isEmpty);
    });

    test('the same tap tells the time once there is room', () async {
      final r = _Rig(await _boot(), open: false);
      expect(await r.dispatcher.handle(repTap()), isEmpty);
      r.open = true;
      final out = await r.dispatcher.handle(repTap());
      expect(out.single.status, GestureStatus.ran);
      expect(r.played, hasLength(1));
    });
  });

  group('the tap ack', () {
    GestureOutcome ran(DeviceAction a) => GestureOutcome(
        action: a, status: GestureStatus.ran, timeSource: EventTimeSource.strap);

    test('a tap whose only action was Tell the time is not acknowledged: the '
        'time buzz is the answer', () {
      expect(shouldAckTap(repTap(), [ran(DeviceAction.tellTime)]), isFalse);
    });

    test('with another action that ran as well, the tap is acknowledged '
        '(unchanged)', () {
      expect(
          shouldAckTap(repTap(),
              [ran(DeviceAction.workoutToggle), ran(DeviceAction.tellTime)]),
          isTrue);
    });

    test('a tap whose other action ran is acknowledged as before (control)',
        () {
      expect(shouldAckTap(repTap(), [ran(DeviceAction.workoutToggle)]), isTrue);
    });
  });
}
