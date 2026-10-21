// The phone transport and Stop (Sol round 3): a Stop during the capability
// query starts no vibration; a Stop during a hold cancels it, once, and only
// when this example started it. Time is fake.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/example_playback.dart';
import 'package:openstrap_edge/haptics/phone_vibration.dart';

class _Fake implements PhoneVibrator {
  Completer<bool>? supportGate;
  bool supports = true;
  final vibrated = <int>[];
  int cancels = 0, buzzes = 0;
  Completer<void>? cancelGate;
  @override
  Future<bool> supportsDuration() =>
      supportGate?.future ?? Future<bool>.value(supports);
  @override
  Future<void> vibrate(int ms) async => vibrated.add(ms);
  @override
  Future<void> cancel() async {
    cancels++;
    await cancelGate?.future;
  }
  @override
  Future<void> fixedBuzz() async => buzzes++;
}

void main() {
  late _Fake f;
  final saved = phoneVibrator;
  setUp(() {
    f = _Fake();
    phoneVibrator = f;
    resetPhoneVibrationForTest();
  });
  tearDown(() => phoneVibrator = saved);

  test('Stop during the capability query: nothing vibrates', () {
    fakeAsync((async) {
      f.supportGate = Completer<bool>();
      final c = HapticCancel();
      vibratePhoneFor(const Duration(seconds: 2), cancel: c);
      async.flushMicrotasks();
      c.cancel();
      f.supportGate!.complete(true);
      async.flushMicrotasks();
      expect(f.vibrated, isEmpty);
      expect(f.buzzes, 0, reason: 'not even the fallback buzz');
    });
  });

  test('Stop during a hold cancels the vibration, once', () {
    fakeAsync((async) {
      final c = HapticCancel();
      vibratePhoneFor(const Duration(seconds: 5), cancel: c);
      async.elapse(const Duration(milliseconds: 100));
      expect(f.vibrated, [5000]);
      c.cancel();
      c.cancel();
      async.flushMicrotasks();
      expect(f.cancels, 1);
    });
  });

  test('a hold that already ended is not cancelled (it may be another\'s '
      'vibration by now)', () {
    fakeAsync((async) {
      final c = HapticCancel();
      vibratePhoneFor(const Duration(milliseconds: 300), cancel: c);
      async.elapse(const Duration(seconds: 1));
      c.cancel();
      async.flushMicrotasks();
      expect(f.cancels, 0);
    });
  });

  test('the latest vibration wins: owned then owned stops the first at '
      'takeover, and Stop afterwards cancels only the active one', () {
    fakeAsync((async) {
      final a = HapticCancel(), b = HapticCancel();
      vibratePhoneFor(const Duration(seconds: 5), cancel: a);
      async.elapse(const Duration(milliseconds: 100));
      vibratePhoneFor(const Duration(seconds: 5), cancel: b);
      async.elapse(const Duration(milliseconds: 100));
      expect(f.cancels, 1, reason: 'the first hold ran on under the second');
      a.cancel();
      async.flushMicrotasks();
      expect(f.cancels, 1, reason: 'A cut off B\'s vibration');
      b.cancel();
      async.flushMicrotasks();
      expect(f.cancels, 2);
    });
  });

  test('owned then unowned (a short preview): the hold is stopped at '
      'takeover and a later Stop has nothing of the example\'s to cancel', () {
    fakeAsync((async) {
      final a = HapticCancel();
      vibratePhoneFor(const Duration(seconds: 5), cancel: a);
      async.elapse(const Duration(milliseconds: 100));
      vibratePhoneFor(const Duration(milliseconds: 200));
      async.elapse(const Duration(milliseconds: 50));
      expect(f.cancels, 1);
      a.cancel();
      async.flushMicrotasks();
      expect(f.cancels, 1, reason: 'Stop cancelled the preview');
    });
  });

  test('unowned then owned: the running unowned vibration is stopped at '
      'takeover', () {
    fakeAsync((async) {
      vibratePhoneFor(const Duration(seconds: 5));
      async.elapse(const Duration(milliseconds: 100));
      vibratePhoneFor(const Duration(seconds: 1), cancel: HapticCancel());
      async.flushMicrotasks();
      expect(f.cancels, 1);
    });
  });

  test('a request that arrives while a takeover is cancelling the old hold '
      'supersedes the one in between: only the newest plays', () {
    fakeAsync((async) {
      final a = HapticCancel(), b = HapticCancel(), c = HapticCancel();
      vibratePhoneFor(const Duration(seconds: 5), cancel: a);
      async.elapse(const Duration(milliseconds: 100));
      expect(f.vibrated, [5000]);
      f.cancelGate = Completer<void>(); // cancelling A hangs
      vibratePhoneFor(const Duration(seconds: 4), cancel: b);
      async.elapse(const Duration(milliseconds: 100));
      expect(f.cancels, 1, reason: 'B stops A');
      vibratePhoneFor(const Duration(seconds: 3), cancel: c);
      async.elapse(const Duration(milliseconds: 100));
      f.cancelGate!.complete();
      f.cancelGate = null;
      async.elapse(const Duration(milliseconds: 100));
      expect(f.vibrated, [5000, 3000], reason: 'B was overtaken, it never plays');
      expect(f.cancels, 1, reason: 'A was cancelled once, nothing else ran');
      a.cancel();
      b.cancel();
      async.flushMicrotasks();
      expect(f.cancels, 1);
      c.cancel();
      async.flushMicrotasks();
      expect(f.cancels, 2, reason: 'Stop cancels the active one');
    });
  });

  test('a hold that already ran out is never cancelled at takeover', () {
    fakeAsync((async) {
      final a = HapticCancel();
      vibratePhoneFor(const Duration(milliseconds: 300), cancel: a);
      async.elapse(const Duration(seconds: 1));
      vibratePhoneFor(const Duration(seconds: 1), cancel: HapticCancel());
      async.flushMicrotasks();
      expect(f.cancels, 0);
    });
  });

  test('a vibration with no owner is never cancelled by an example', () {
    fakeAsync((async) {
      final c = HapticCancel();
      vibratePhoneFor(const Duration(seconds: 5));
      async.elapse(const Duration(milliseconds: 100));
      c.cancel();
      async.flushMicrotasks();
      expect(f.cancels, 0);
    });
  });

  test('the capability is asked once per process', () {
    fakeAsync((async) {
      var asked = 0;
      phoneVibrator = _Counting(f, () => asked++);
      vibratePhoneFor(const Duration(milliseconds: 10));
      vibratePhoneFor(const Duration(milliseconds: 10));
      async.flushMicrotasks();
      expect(asked, lessThanOrEqualTo(1));
    });
  });
}

class _Counting implements PhoneVibrator {
  _Counting(this.inner, this.onAsk);
  final _Fake inner;
  final void Function() onAsk;
  @override
  Future<bool> supportsDuration() {
    onAsk();
    return inner.supportsDuration();
  }

  @override
  Future<void> vibrate(int ms) => inner.vibrate(ms);
  @override
  Future<void> cancel() => inner.cancel();
  @override
  Future<void> fixedBuzz() => inner.fixedBuzz();
}
