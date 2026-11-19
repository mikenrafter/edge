// Failure injection — gesture sessions and the gesture dispatcher.
// BLE disconnect mid-gesture, write timeouts, duplicate taps, a skewed strap
// clock, corrupt frames, a failing database and a process restart. Each ends
// with the latch cleared (the next double tap works), no stream left running,
// and never two actions or two buzzes for one tap.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:shared_preferences/shared_preferences.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);

StrapEvent _tap({int sec = 0, int? ts, Duration late = const Duration(milliseconds: 300)}) {
  final epoch = ts ?? _t0.millisecondsSinceEpoch ~/ 1000 + sec;
  return StrapEvent(
    eventId: 14,
    tsEpoch: epoch,
    receivedAt: _t0.add(Duration(seconds: sec)).add(late),
    hex: '',
    deviceId: 'band',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DoubleTapRepeatSession', () {
    test('a buzz that never answers cannot hold the window open', () {
      fakeAsync((async) {
        final session = DoubleTapRepeatSession(
          maxTaps: () => 5,
          window: () => const Duration(seconds: 2),
          buzz: (_) => Completer<bool>().future,
        );
        int? count;
        session.begin(_tap()).then((c) => count = c);
        session.add(_tap(sec: 1));
        async.elapse(const Duration(seconds: 3));
        expect(count, 3);
        expect(session.open, isFalse);
      });
    });

    test('a skewed strap clock cannot count one physical tap twice', () {
      fakeAsync((async) {
        final session = DoubleTapRepeatSession(
          maxTaps: () => 5,
          window: () => const Duration(seconds: 2),
        );
        int? count;
        // An unset RTC (epoch 0) gives every tap the same identity.
        session.begin(_tap(ts: 0)).then((c) => count = c);
        expect(session.add(_tap(ts: 0)), isFalse,
            reason: 'same receipt instant = the same tap seen twice');
        async.elapse(const Duration(seconds: 3));
        expect(count, 2);
      });
    });
  });

  group('GestureDispatcher', () {
    const channel = MethodChannel('openstrap/device_actions');
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) async {
        return c.method == 'capabilities' ? <String>[] : false;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    Future<GestureSettings> settings() async {
      final s = GestureSettings();
      await s.bootstrap();
      await s.setDoubleTapActions({DeviceAction.workoutToggle, DeviceAction.markMoment});
      return s;
    }

    test('an action that never answers is a failed outcome, the next action '
        'still runs, and its claim is kept (no second run on a re-send)',
        () async {
      final s = await settings();
      final claims = <String>{};
      var workout = 0, moment = 0;
      final d = GestureDispatcher(
        settings: s,
        actionTimeout: const Duration(milliseconds: 40),
        claim: (k) async => claims.add(k),
        release: (k) async => claims.remove(k),
        onMarkMoment: (_) => Completer<void>().future, // first in enum order; hangs
        onWorkoutToggle: (_) async => workout++,
      );
      final out = await d.handle(_tap());
      expect(out.map((o) => o.status), [GestureStatus.failed, GestureStatus.ran]);
      expect(out.first.error, isA<TimeoutException>());
      expect(workout, 1);
      // The same tap again: nothing runs twice.
      final again = await GestureDispatcher(
        settings: s,
        actionTimeout: const Duration(milliseconds: 40),
        claim: (k) async => claims.add(k),
        release: (k) async => claims.remove(k),
        onMarkMoment: (_) async => moment++,
        onWorkoutToggle: (_) async => workout++,
      ).handle(_tap());
      expect(again.map((o) => o.status),
          [GestureStatus.skippedDuplicate, GestureStatus.skippedDuplicate]);
      expect((workout, moment), (1, 0));
    });

    test('a database that throws on the claim fails closed for every action',
        () async {
      final s = await settings();
      var ran = 0;
      final out = await GestureDispatcher(
        settings: s,
        claim: (_) async => throw StateError('database is locked'),
        onWorkoutToggle: (_) async => ran++,
        onMarkMoment: (_) async => ran++,
      ).handle(_tap());
      expect(out.map((o) => o.status), [GestureStatus.failed, GestureStatus.failed]);
      expect(ran, 0);
    });

    test('a database that throws on release does not escape handle', () async {
      final s = await settings();
      final out = await GestureDispatcher(
        settings: s,
        claim: (_) async => true,
        release: (_) async => throw StateError('database is locked'),
        onWorkoutToggle: (_) async => throw StateError('write failed'),
        onMarkMoment: (_) async {},
      ).handle(_tap());
      expect(out.map((o) => o.status), [GestureStatus.ran, GestureStatus.failed]);
    });

    test('a strap clock hours in the future runs the action once, then '
        'debounces on receipt time', () async {
      final s = await settings();
      var ran = 0;
      final d = GestureDispatcher(
        settings: s,
        claim: (_) async => fail('an implausible clock must not claim'),
        onWorkoutToggle: (_) async => ran++,
        onMarkMoment: (_) async {},
      );
      final future = _t0.millisecondsSinceEpoch ~/ 1000 + 6 * 3600;
      await d.handle(_tap(ts: future));
      final dup = await d.handle(_tap(ts: future));
      expect(ran, 1);
      expect(dup.every((o) => o.status == GestureStatus.skippedDuplicate), isTrue);
    });

    test('every action failing (permission lost) sends no acknowledgement buzz',
        () async {
      final s = await settings();
      final out = await GestureDispatcher(
        settings: s,
        claim: (_) async => true,
        release: (_) async {},
        performNative: (_) async => false,
        onWorkoutToggle: (_) async => throw StateError('denied'),
        onMarkMoment: (_) async => throw StateError('denied'),
      ).handle(_tap());
      var buzzes = 0;
      final d = AlertDispatcher(
        phone: () async => false,
        band: () async => ++buzzes > 0,
        isConnected: () => true,
        supportedBandModes: const {AlertExecutionMode.phoneLive},
        ledger: MemoryAlertDeliveryLedger(),
      );
      final live = _tap(late: const Duration(milliseconds: 100));
      expect(await ackTap(d, live, out), isFalse);
      expect(buzzes, 0);
    });

    test('the acknowledgement survives a throwing ledger as a quiet no', () async {
      final s = await settings();
      final outcomes = await GestureDispatcher(
        settings: s,
        claim: (_) async => true,
        release: (_) async {},
        onWorkoutToggle: (_) async {},
        onMarkMoment: (_) async {},
      ).handle(_tap());
      final d = AlertDispatcher(
        phone: () async => false,
        band: () async => true,
        isConnected: () => true,
        supportedBandModes: const {AlertExecutionMode.phoneLive},
        ledger: _ThrowingLedger(),
      );
      expect(await ackTap(d, _tap(), outcomes), isFalse);
    });
  });
}

class _ThrowingLedger implements AlertDeliveryLedger {
  @override
  Future<bool> claim(String key) async => throw StateError('database is locked');
  @override
  Future<void> release(String key) async => throw StateError('database is locked');
}
