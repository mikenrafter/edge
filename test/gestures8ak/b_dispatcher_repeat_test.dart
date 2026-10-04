// 8AK B (red): the dispatcher's repeated-double-tap route and the tap
// acknowledgement.
//
// With the session itself playing the confirm cue at the end of a counted
// gesture (b_double_tap_cues_test.dart), the 8H tap acknowledgement
// (`ackTap`, a confirm cue after an action ran) must stay out of that route,
// or the wearer would feel the confirm twice. The ECG route already does
// this: its outcomes carry `taps` (even for a count of 2), which makes
// `shouldAckTap` false.
//
// ASSUMED BEHAVIOUR (lib/gestures/gesture_dispatcher.dart, `_repeatTap`):
//   * every action that runs for a counted repeated-double-tap gesture
//     carries `taps: count`, a count of 2 included (today only 3 and up), so
//     `shouldAckTap` is false for the whole route and the session's confirm
//     is the one acknowledgement.
//   * the claim keys stay as they are (a count of 2 keeps the plain
//     `gesture:<identity>:<action>` key, 3-5 their `t<count>` scope).
//   * a single double tap with NO 3-5 slot mapped is not a gesture at all (no
//     window, runs at once): it keeps `taps: null` and the 8H ack (regression
//     guard).
//
// Failure mode today: the count of 2 outcome has `taps == null`, so the ack
// and the session's confirm would both play.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ak_repeat_rig.dart';

const _channel = MethodChannel('openstrap/device_actions');

Future<GestureSettings> _boot({bool three = true}) async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  await s.setDoubleTapActions({DeviceAction.logWater});
  if (three) await s.setActionsForTaps(3, {DeviceAction.markMoment});
  return s;
}

class _Rig {
  _Rig(GestureSettings settings) {
    repeat = DoubleTapRepeatSession(
      maxTaps: () => settings.repeatTapMax,
      window: () => settings.repeatTapWindow,
      buzz: (id) async => true,
    );
    dispatcher = GestureDispatcher(
      settings: settings,
      performNative: (_) async => true,
      claim: (k) async => claims.add(k),
      release: (k) async => claims.remove(k),
      ecgSupported: () => false,
      repeatSession: repeat,
      onLogWater: (e) async => ran.add('water'),
      onMarkMoment: (e) async => ran.add('moment'),
    );
  }

  late final DoubleTapRepeatSession repeat;
  late final GestureDispatcher dispatcher;
  final claims = <String>{};
  final ran = <String>[];
  List<GestureOutcome>? first;

  void tap(StrapEvent e) => dispatcher.handle(e).then((o) => first = o);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  test('a count of 2 through the window carries taps: 2, so the 8H ack stays '
      'quiet and the session\'s confirm is the only one', () async {
    final s = await _boot();
    fakeAsync((async) {
      final r = _Rig(s)..tap(repTap());
      async.elapse(const Duration(milliseconds: 2500));
      async.flushMicrotasks();
      expect(r.ran, ['water']);
      expect(r.first!.single.taps, 2);
      expect(shouldAckTap(repTap(), r.first!), isFalse);
      expect(r.claims, contains('gesture:${repTap().identity}:${DeviceAction.logWater.id}'),
          reason: 'a count of 2 keeps the plain claim key');
    });
  });

  test('regression guard (passes today): a count of 3 through the window: taps '
      '3, no ack', () async {
    final s = await _boot();
    fakeAsync((async) {
      final r = _Rig(s)..tap(repTap());
      async.elapse(const Duration(milliseconds: 800));
      r.dispatcher.handle(repTap(sec: 1));
      async.elapse(const Duration(milliseconds: 2500));
      async.flushMicrotasks();
      expect(r.first!.single.taps, 3);
      expect(shouldAckTap(repTap(), r.first!), isFalse);
    });
  });

  test('regression guard (passes today): with NO 3-5 slot mapped a double '
      'tap runs at once, taps null, and the 8H ack applies', () async {
    final s = await _boot(three: false);
    fakeAsync((async) {
      final r = _Rig(s)..tap(repTap());
      async.flushMicrotasks();
      expect(r.ran, ['water']);
      expect(r.first!.single.taps, isNull);
      expect(shouldAckTap(repTap(), r.first!), isTrue);
      expect(r.repeat.open, isFalse);
    });
  });
}
