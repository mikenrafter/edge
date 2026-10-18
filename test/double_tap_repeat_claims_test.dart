// Every double tap that joins a repeated-double-tap group is claimed durably
// (review finding J).
//
// Before: only the tap that OPENED a window took the once-ever claim; later taps
// went straight into the session (`session.add`), whose dedupe is per session.
// A member re-delivered after its group finished (history replay, reconnect)
// was therefore unclaimed and opened a NEW window or ran an action a second
// time. Now each member takes `gesture:<identity>:rep` before it is offered to
// the session; an implausible strap clock (no stable identity) keeps the
// session's receipt debounce instead.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap(int sec, {int lateMs = 1000}) {
  final ts = _t0Sec + sec;
  return StrapEvent(
    eventId: 14,
    tsEpoch: ts,
    receivedAt:
        DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)
            .add(Duration(milliseconds: lateMs)),
    hex: '',
    deviceId: 'band',
  );
}

StrapEvent _unset(int receivedMs) => StrapEvent(
      eventId: 14,
      tsEpoch: 0,
      receivedAt: _t0.add(Duration(milliseconds: receivedMs)),
      hex: '',
      deviceId: 'band',
    );

Future<GestureSettings> _mapped() async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  await s.setDoubleTapActions({DeviceAction.tellTime});
  await s.setActionsForTaps(3, {DeviceAction.markMoment});
  await s.setActionsForTaps(4, {DeviceAction.workoutToggle});
  return s;
}

class _Rig {
  _Rig(this.settings) {
    repeat = DoubleTapRepeatSession(
      maxTaps: () => settings.repeatTapMax,
      window: () => settings.repeatTapWindow,
      step: steps.add,
      onFinished: finished.add,
    );
    dispatcher = GestureDispatcher(
      settings: settings,
      performNative: (_) async => true,
      claim: (k) async {
        claimCalls.add(k);
        if (claimThrows) throw StateError('db locked');
        return claims.add(k);
      },
      release: (k) async => claims.remove(k),
      repeatSession: repeat,
      onTellTime: (e, _) async => ran.add('tell'),
      onMarkMoment: (e) async => ran.add('moment'),
      onWorkoutToggle: (e) async => ran.add('workout'),
    );
  }

  final GestureSettings settings;
  late final DoubleTapRepeatSession repeat;
  late final GestureDispatcher dispatcher;
  bool claimThrows = false;
  final Set<String> claims = {};
  final claimCalls = <String>[];
  final ran = <String>[];
  final steps = <String>[];
  final finished = <int>[];

  void tap(StrapEvent e) => dispatcher.handle(e);

  String repKey(StrapEvent e) => 'gesture:${e.identity}:rep';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  test('a member takes its own durable claim', () async {
    final s = await _mapped();
    fakeAsync((async) {
      final r = _Rig(s);
      final a = _tap(0), b = _tap(1);
      r.tap(a);
      async.flushMicrotasks();
      r.tap(b);
      async.flushMicrotasks();
      expect(r.claims, containsAll([r.repKey(a), r.repKey(b)]));
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(r.ran, ['moment']);
    });
  });

  test('a member re-delivered after its group finished is not a new gesture',
      () async {
    final s = await _mapped();
    fakeAsync((async) {
      final r = _Rig(s);
      final a = _tap(0), b = _tap(1);
      r.tap(a);
      async.flushMicrotasks();
      r.tap(b);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(r.ran, ['moment']);
      expect(r.repeat.open, isFalse);
      // History replay / reconnect hands B over again.
      r.tap(b);
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(r.repeat.open, isFalse, reason: 'B must not open a window');
      expect(r.ran, ['moment'], reason: 'and must not run an action');
      expect(r.finished, [3]);
    });
  });

  test('the opener re-delivered after its group finished is still skipped',
      () async {
    final s = await _mapped();
    fakeAsync((async) {
      final r = _Rig(s);
      final a = _tap(0);
      r.tap(a);
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(r.ran, ['tell']);
      r.tap(a);
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(r.ran, ['tell']);
    });
  });

  test('the same member delivered twice at once is counted once', () async {
    final s = await _mapped();
    fakeAsync((async) {
      final r = _Rig(s);
      r.tap(_tap(0));
      async.flushMicrotasks();
      final b = _tap(1);
      r.tap(b);
      r.tap(b);
      async.flushMicrotasks();
      expect(r.repeat.count, 3, reason: 'one B, not two');
    });
  });

  test('a claim store that fails skips the member (fail closed) and the group '
      'carries on', () async {
    final s = await _mapped();
    fakeAsync((async) {
      final r = _Rig(s);
      r.tap(_tap(0));
      async.flushMicrotasks();
      r.claimThrows = true;
      r.tap(_tap(1));
      async.flushMicrotasks();
      expect(r.repeat.count, 2, reason: 'not counted without a claim');
      expect(r.repeat.open, isTrue);
    });
  });

  test('a member that starts the NEXT group keeps the claim it took (taken '
      'once) and runs its own gesture', () async {
    final s = await _mapped();
    fakeAsync((async) {
      final r = _Rig(s);
      final a = _tap(0, lateMs: 4000), b = _tap(3, lateMs: 1010);
      r.tap(a);
      async.flushMicrotasks();
      r.tap(b);
      async.flushMicrotasks();
      expect(r.repeat.open, isTrue, reason: 'B opened the next window');
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(r.ran, ['tell', 'tell'],
          reason: 'two separate double taps, not a triple');
      expect(r.claimCalls.where((k) => k == r.repKey(b)), hasLength(1),
          reason: 'B claimed once, not again when it opened the group');
    });
  });

  test('an unrelated older tap is ignored but stays claimed', () async {
    final s = await _mapped();
    fakeAsync((async) {
      final r = _Rig(s);
      final a = _tap(10);
      r.tap(a);
      async.flushMicrotasks();
      final stray = _tap(2, lateMs: 5000);
      r.tap(stray);
      async.flushMicrotasks();
      expect(r.repeat.count, 2);
      expect(r.claims, contains(r.repKey(stray)));
    });
  });

  test('an implausible strap clock keeps the receipt debounce: members are '
      'not blocked by the dispatcher\'s 2 s window', () async {
    final s = await _mapped();
    fakeAsync((async) {
      final r = _Rig(s);
      r.tap(_unset(0));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 600));
      r.tap(_unset(600));
      async.flushMicrotasks();
      expect(r.repeat.count, 3);
      expect(r.claims, isEmpty,
          reason: 'no persistent claim without a believable strap clock');
    });
  });
}
