// Phase 7 failure injection — gesture sessions and the gesture dispatcher.
// BLE disconnect mid-gesture, write timeouts, duplicate taps, a skewed strap
// clock, corrupt frames, a failing database and a process restart. Each ends
// with the latch cleared (the next double tap works), no stream left running,
// and never two actions or two buzzes for one tap.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
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

LabradorR17 _packet(int sec, {int n = 100, int contactFrom = 1000}) => LabradorR17(
      packetType: 43,
      headerSecondary: 0,
      sequence: sec,
      strapSeconds: sec,
      subseconds: 0,
      quality: 0,
      flags: const LabradorFlags(0x0a),
      result: 0,
      s2State: 0,
      progress: 0,
      unreadable: const LabradorUnreadableMask(0),
      averageHr: 0,
      liveHr: 0,
      variabilityRaw: null,
      reserved: 0,
      sampleCount: n,
      samples: Int16List.fromList([
        for (var i = 0; i < n; i++) i >= contactFrom ? 120 : 0,
      ]),
      tail: Uint8List(0),
      inner: Uint8List(0),
    );

class _Rig {
  _Rig({
    this.beginHangs = false,
    this.endHangs = false,
    this.recordHangs = false,
    this.recordThrows = false,
    this.buzzHangsOnCall,
    Duration t = const Duration(milliseconds: 40),
  }) {
    session = EcgTapSession(
      beginStream: () {
        began++;
        return beginHangs ? Completer<bool>().future : Future.value(true);
      },
      endStream: () {
        ended++;
        return endHangs ? Completer<void>().future : Future.value();
      },
      isStreamAlive: () => alive,
      buzz: (pulses, id) {
        buzzes.add((pulses, id));
        return buzzHangsOnCall == buzzes.length
            ? Completer<bool>().future
            : Future.value(true);
      },
      maxTaps: () => 3,
      thresholds: EcgTapThresholds.new,
      onFinished: (c, r) => results.add((c, r)),
      recordSession: (r) {
        records.add(r);
        if (recordThrows) throw StateError('database is locked');
        return recordHangs ? Completer<void>().future : Future.value();
      },
      now: () => now,
      wait: (_) async {}, // the band's quiet gap is not what these test
      pollEvery: const Duration(hours: 1),
      beginTimeout: t,
      endTimeout: t,
      recordTimeout: t,
      buzzTimeout: t,
    );
  }

  final bool beginHangs, endHangs, recordHangs, recordThrows;
  final int? buzzHangsOnCall;
  late final EcgTapSession session;
  bool alive = true;
  DateTime now = _t0;
  int began = 0, ended = 0;
  final buzzes = <(int, String)>[];
  final results = <(int?, String?)>[];
  final records = <EcgGestureRecord>[];

  Future<void> settle([int ms = 120]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// Two packets one second apart: the stream is steady and the first window
  /// opens (nothing buzzes yet).
  Future<void> steady({int sec = 1000}) async {
    now = _t0.add(const Duration(milliseconds: 500));
    session.onFrame(_packet(sec));
    now = _t0.add(const Duration(milliseconds: 1500));
    session.onFrame(_packet(sec + 1));
    await Future<void>.delayed(Duration.zero);
  }

  /// A no-contact second after [steady]: the first window runs out, so the
  /// gesture ends at 2 with the two-command buzz.
  Future<void> noTouch({int sec = 1000}) async {
    now = _t0.add(const Duration(seconds: 2));
    session.onFrame(_packet(sec + 2));
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('EcgTapSession', () {
    test('a stream-start write that never answers fails the start, clears the '
        'latch, stops a late stream, and the next tap works', () async {
      final r = _Rig(beginHangs: true);
      // 8X: the fallback is on by default, so a failed start does not throw: it
      // ends the gesture with count 2 (the double-tap action).
      await r.session.start(_tap());
      expect(r.session.active, isFalse);
      expect(r.results, [(2, 'fallback: start_failed')]);
      expect(r.ended, 1, reason: 'a start that answers late must not stream on');
      expect(r.records.single.reason, contains('start_failed'));
      // The latch is clear: another tap begins a new gesture.
      final again = _Rig();
      await again.session.start(_tap());
      expect(again.session.active, isTrue);
    });

    test('a database that never answers does not keep the stream running',
        () async {
      final r = _Rig(recordHangs: true);
      await r.session.start(_tap());
      await r.steady();
      r.alive = false;
      r.session.poll(); // link lost
      await r.settle(300);
      expect(r.session.active, isFalse);
      expect(r.results.single, (2, 'fallback: link_lost'));
      expect(r.ended, 1);
    });

    test('a database that throws still ends the gesture and stops the stream',
        () async {
      final r = _Rig(recordThrows: true);
      await r.session.start(_tap());
      await r.steady();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect((r.session.active, r.ended, r.records.length), (false, 1, 1));
    });

    test('a stop command that never answers cannot wedge the next gesture',
        () async {
      final r = _Rig(endHangs: true);
      await r.session.start(_tap());
      await r.steady();
      r.alive = false;
      r.session.poll();
      await r.settle();
      expect(r.session.active, isFalse);
      r.alive = true;
      await r.session.start(_tap(sec: 30));
      expect(r.session.active, isTrue);
    });

    test('a count buzz that never answers cannot hold the gesture: the count '
        'stands and the latch is free', () async {
      final r = _Rig(buzzHangsOnCall: 1);
      await r.session.start(_tap());
      await r.steady();
      await r.noTouch();
      expect(r.buzzes.single.$1, 1,
          reason: 'the first command of the two-command count buzz; it timed '
              'out, so the second is not sent');
      await r.settle(200);
      expect(r.session.active, isFalse);
      expect(r.results.single, (2, null));
    });

    test('a stuck buzz of one gesture does not queue the next gesture\'s '
        'buzz behind it', () async {
      final r = _Rig(buzzHangsOnCall: 1);
      await r.session.start(_tap());
      await r.steady();
      await r.noTouch(); // ends at 2; its buzz is stuck
      await r.settle(10);
      await r.session.start(_tap(sec: 40));
      await r.steady(sec: 2000);
      await r.noTouch(sec: 2000);
      await r.settle(200);
      expect(r.buzzes.length, 3,
          reason: 'the first gesture sent one command and timed out; the '
              'second gesture sent both of its commands');
    });

    test('BLE disconnect mid-gesture: ended once (count 2 by the default '
        'fallback), recorded once, stream stopped', () async {
      final r = _Rig();
      await r.session.start(_tap());
      await r.steady();
      r.alive = false;
      r.session.poll();
      r.session.poll(); // a second poll must not double-finish
      await r.settle();
      expect(r.results, [(2, 'fallback: link_lost')]);
      expect((r.records.length, r.ended), (1, 1));
    });

    test('the same tap delivered twice starts one gesture', () async {
      final r = _Rig();
      final tap = _tap();
      await Future.wait([r.session.start(tap), r.session.start(tap)]);
      expect(r.began, 1);
    });

    test('corrupt frames (no samples, an absurd strap clock) never throw and '
        'do not end the gesture', () async {
      final r = _Rig();
      await r.session.start(_tap());
      r.session.onFrame(_packet(1000, n: 0));
      r.session.onFrame(_packet(0x7fffffff));
      r.session.onFrame(_packet(-5));
      expect(r.session.active, isTrue);
    });

    test('process restart: a brand new session after an abandoned one counts '
        'from scratch', () async {
      final a = _Rig();
      await a.session.start(_tap());
      await a.steady();
      a.alive = false;
      a.session.poll();
      await a.settle();
      final b = _Rig(); // new process, new object
      await b.session.start(_tap(sec: 100));
      await b.steady(sec: 5000);
      expect(b.buzzes, isEmpty);
      expect(b.session.active, isTrue);
      await b.noTouch(sec: 5000);
      expect(b.buzzes.map((x) => x.$1), [1, 1]);
      expect(b.results, [(2, null)]);
    });
  });

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
      await s.setDoubleTapActions({DeviceAction.logWater, DeviceAction.markMoment});
      return s;
    }

    test('an action that never answers is a failed outcome, the next action '
        'still runs, and its claim is kept (no second run on a re-send)',
        () async {
      final s = await settings();
      final claims = <String>{};
      var water = 0, moment = 0;
      final d = GestureDispatcher(
        settings: s,
        actionTimeout: const Duration(milliseconds: 40),
        claim: (k) async => claims.add(k),
        release: (k) async => claims.remove(k),
        onMarkMoment: (_) => Completer<void>().future, // first in enum order; hangs
        onLogWater: (_) async => water++,
      );
      final out = await d.handle(_tap());
      expect(out.map((o) => o.status), [GestureStatus.failed, GestureStatus.ran]);
      expect(out.first.error, isA<TimeoutException>());
      expect(water, 1);
      // The same tap again: nothing runs twice.
      final again = await GestureDispatcher(
        settings: s,
        actionTimeout: const Duration(milliseconds: 40),
        claim: (k) async => claims.add(k),
        release: (k) async => claims.remove(k),
        onMarkMoment: (_) async => moment++,
        onLogWater: (_) async => water++,
      ).handle(_tap());
      expect(again.map((o) => o.status),
          [GestureStatus.skippedDuplicate, GestureStatus.skippedDuplicate]);
      expect((water, moment), (1, 0));
    });

    test('a database that throws on the claim fails closed for every action',
        () async {
      final s = await settings();
      var ran = 0;
      final out = await GestureDispatcher(
        settings: s,
        claim: (_) async => throw StateError('database is locked'),
        onLogWater: (_) async => ran++,
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
        onLogWater: (_) async => throw StateError('write failed'),
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
        onLogWater: (_) async => ran++,
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
        onLogWater: (_) async => throw StateError('denied'),
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
        onLogWater: (_) async {},
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
