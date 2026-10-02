// 8L runtime — what a counted tap DOES once the counter has a result.
//
// Lab switch OFF, WHOOP MG, at least one 3-5 tap mapping: a LIVE double tap
// starts the counter session and, when it finishes, the final count's actions
// run through the ordinary GestureDispatcher path (same once-ever claim,
// isolation and stale rules, keyed per tap identity AND count). No 3-5 mapping,
// a non-MG band, or a late tap behaves exactly as before. An abandoned session
// runs nothing. The counter's own buzzes are the acknowledgement, so the 8H
// tap-ack stays silent for a counted tap. See test/phase8/CONTRACTS.md §8L.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dart_source.dart';

const _channel = MethodChannel('openstrap/device_actions');

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap({Duration late = const Duration(seconds: 1), int sec = 0}) {
  final ts = _t0Sec + sec;
  return StrapEvent(
    eventId: 14,
    tsEpoch: ts,
    receivedAt:
        DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true).add(late),
    hex: '',
    deviceId: 'band',
  );
}

Future<GestureSettings> _boot(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return <String>[];
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

/// 2 taps -> log water, 3 taps -> mark moment, 4 taps -> workout toggle.
Future<GestureSettings> _mapped({bool three = true, bool four = true}) async {
  final s = await _boot({});
  await s.setDoubleTapActions({DeviceAction.logWater});
  if (three) await s.setActionsForTaps(3, {DeviceAction.markMoment});
  if (four) await s.setActionsForTaps(4, {DeviceAction.workoutToggle});
  return s;
}

class _Rig {
  _Rig(this.settings, {this.mg = true});
  final GestureSettings settings;
  bool mg;

  /// What the session reports; null = abandoned.
  Future<int?> Function(StrapEvent e) counter = (_) async => 2;

  /// The session could not start (the contract: onCountTaps throws).
  bool startFails = false;
  bool failMoment = false;

  final Set<String> claims = {};
  final List<String> ran = [];
  final List<StrapEvent> counted = [];
  final List<StrapEvent> labStarts = [];

  late final GestureDispatcher dispatcher = GestureDispatcher(
    settings: settings,
    performNative: (_) async => true,
    claim: (k) async => claims.add(k),
    release: (k) async => claims.remove(k),
    ecgSupported: () => mg,
    onEcgTap: (e) async => labStarts.add(e),
    onCountTaps: (e) async {
      counted.add(e);
      if (startFails) throw StateError('ECG stream did not start');
      return counter(e);
    },
    onLogWater: (e) async => ran.add('water'),
    onMarkMoment: (e) async {
      if (failMoment) throw StateError('moment');
      ran.add('moment');
    },
    onWorkoutToggle: (e) async => ran.add('workout'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('lab off + MG + a 3-5 mapping: a live double tap is counted', () {
    test('a final count of 4 runs the 4-tap actions once, and only those',
        () async {
      final r = _Rig(await _mapped())..counter = (_) async => 4;
      final out = await r.dispatcher.handle(_tap());
      expect(r.counted, hasLength(1));
      expect(r.ran, ['workout']);
      expect(out.map((o) => (o.action, o.status, o.taps)), [
        (DeviceAction.workoutToggle, GestureStatus.ran, 4),
      ]);
      expect(r.labStarts, isEmpty, reason: 'the lab path is not used');
    });

    test('nothing runs until the session reports', () async {
      final r = _Rig(await _mapped());
      final done = Completer<int?>();
      r.counter = (_) => done.future;
      final pending = r.dispatcher.handle(_tap());
      await Future<void>.delayed(Duration.zero);
      expect(r.ran, isEmpty, reason: 'the actions wait for the final count');
      done.complete(3);
      await pending;
      expect(r.ran, ['moment']);
    });

    test('a final count of 2 runs the 2-tap actions', () async {
      final r = _Rig(await _mapped())..counter = (_) async => 2;
      final out = await r.dispatcher.handle(_tap());
      expect(r.ran, ['water']);
      expect(out.single.taps, 2);
    });

    test('a count nothing is mapped to runs nothing', () async {
      final r = _Rig(await _mapped(three: false))..counter = (_) async => 3;
      final out = await r.dispatcher.handle(_tap());
      expect(r.ran, isEmpty);
      expect(out, isEmpty);
    });

    test('claims are keyed per tap identity and count; a re-send runs nothing',
        () async {
      final r = _Rig(await _mapped())..counter = (_) async => 4;
      final e = _tap();
      await r.dispatcher.handle(e);
      expect(r.claims,
          contains('gesture:${e.identity}:t4:${DeviceAction.workoutToggle.id}'));
      await r.dispatcher.handle(e);
      expect(r.counted, hasLength(1), reason: 'a duplicate starts no session');
      expect(r.ran, ['workout']);
    });

    test('a count of 2 keeps the plain double-tap claim key', () async {
      final r = _Rig(await _mapped())..counter = (_) async => 2;
      final e = _tap();
      await r.dispatcher.handle(e);
      expect(r.claims,
          contains('gesture:${e.identity}:${DeviceAction.logWater.id}'));
    });

    test('an action that fails gives its claim back; the next still runs',
        () async {
      final s = await _mapped();
      await s.setDoubleTapActions(
          {DeviceAction.logWater, DeviceAction.markMoment});
      final r = _Rig(s)
        ..failMoment = true
        ..counter = (_) async => 2;
      final out = await r.dispatcher.handle(_tap());
      // Enum order: the failing mark moment goes first, water still runs.
      expect(out.map((o) => o.status),
          [GestureStatus.failed, GestureStatus.ran]);
      expect(r.ran, ['water']);
      expect(r.claims.where((k) => k.endsWith(DeviceAction.markMoment.id)),
          isEmpty);
    });

    test('an abandoned session (link drop or stall) runs nothing', () async {
      final r = _Rig(await _mapped())..counter = (_) async => null;
      final out = await r.dispatcher.handle(_tap());
      expect(out, isEmpty);
      expect(r.ran, isEmpty);
    });

    test('a session that could not start gives the claim back and the '
        'double-tap actions run at once', () async {
      final r = _Rig(await _mapped())..startFails = true;
      final e = _tap();
      final out = await r.dispatcher.handle(e);
      expect(r.ran, ['water']);
      expect(out.single.status, GestureStatus.ran);
      expect(out.single.taps, isNull, reason: 'not counted, so it may be acked');
      expect(r.claims.any((k) => k.endsWith(':ecg')), isFalse);
    });

    test('a duplicate tap identity starts no second session', () async {
      final r = _Rig(await _mapped())..counter = (_) async => 4;
      await Future.wait([
        r.dispatcher.handle(_tap()),
        r.dispatcher.handle(_tap()),
      ]);
      expect(r.counted, hasLength(1));
      expect(r.ran, ['workout']);
    });

    test('an unset strap clock: a second tap inside 2 s is a duplicate, a '
        'later one is a new tap', () async {
      final r = _Rig(await _mapped())..counter = (_) async => 4;
      StrapEvent unset(int ms) => StrapEvent(
            eventId: 14,
            tsEpoch: 0,
            receivedAt: _t0.add(Duration(milliseconds: ms)),
            hex: '',
            deviceId: 'band',
          );
      await r.dispatcher.handle(unset(0));
      await r.dispatcher.handle(unset(500));
      expect(r.counted, hasLength(1));
      await r.dispatcher.handle(unset(5000));
      expect(r.counted, hasLength(2));
    });

    test('a late (non-live) tap never starts a session; stale rules apply',
        () async {
      final r = _Rig(await _mapped())..counter = (_) async => 4;
      final out =
          await r.dispatcher.handle(_tap(late: const Duration(minutes: 5)));
      expect(r.counted, isEmpty);
      expect(r.ran, isEmpty);
      expect(out.map((o) => o.status), [GestureStatus.skippedStale]);
    });
  });

  group('everything else behaves exactly as before', () {
    test('no 3-5 mapping: the double-tap actions run at once, no session',
        () async {
      final r = _Rig(await _mapped(three: false, four: false));
      final e = _tap();
      final out = await r.dispatcher.handle(e);
      expect(r.counted, isEmpty);
      expect(r.ran, ['water']);
      expect(out.single.taps, isNull);
      expect(r.claims.single, 'gesture:${e.identity}:${DeviceAction.logWater.id}');
    });

    test('a non-MG band: immediate, no session, even with a 4-tap mapping',
        () async {
      final r = _Rig(await _mapped(), mg: false);
      await r.dispatcher.handle(_tap());
      expect(r.counted, isEmpty);
      expect(r.ran, ['water']);
    });

    test('only 4 taps mapped and no 2-tap action: still counted', () async {
      final s = await _boot({});
      await s.setActionsForTaps(4, {DeviceAction.workoutToggle});
      final r = _Rig(s)..counter = (_) async => 4;
      await r.dispatcher.handle(_tap());
      expect(r.counted, hasLength(1));
      expect(r.ran, ['workout']);
    });
  });

  group('the Device lab keeps ownership while its switch is on', () {
    test('lab on: the lab capture starts, no counted session, no actions',
        () async {
      final s = await _mapped();
      await s.setEcgOnDoubleTap(true);
      final r = _Rig(s);
      final out = await r.dispatcher.handle(_tap());
      expect(r.labStarts, hasLength(1));
      expect(r.counted, isEmpty);
      expect(r.ran, isEmpty);
      expect(out, isEmpty);
    });

    test('ecgTapMax is 5 in the lab regardless of mappings', () async {
      final s = await _boot({});
      expect(s.maxMappedTaps, 2);
      expect(s.ecgTapMax, 2, reason: 'outside the lab: the highest mapped');
      await s.setEcgOnDoubleTap(true);
      expect(s.ecgTapMax, 5);
      await s.setActionsForTaps(3, {DeviceAction.markMoment});
      expect(s.ecgTapMax, 5);
      await s.setEcgOnDoubleTap(false);
      expect(s.ecgTapMax, 3);
      await s.setActionsForTaps(4, {DeviceAction.logWater});
      expect(s.ecgTapMax, 4);
    });
  });

  group("acknowledgement: the counter's buzzes replace the 8H tap ack", () {
    AlertDispatcher alerts(void Function() onBuzz) => AlertDispatcher(
          phone: () async => false,
          band: () async {
            onBuzz();
            return true;
          },
          isConnected: () => true,
          ledger: MemoryAlertDeliveryLedger(),
          now: () => _t0.add(const Duration(seconds: 1)),
        );

    test('a counted tap whose actions ran is NOT acked', () async {
      final r = _Rig(await _mapped())..counter = (_) async => 4;
      final e = _tap();
      final out = await r.dispatcher.handle(e);
      expect(out.any((o) => o.status == GestureStatus.ran), isTrue);
      expect(shouldAckTap(e, out), isFalse);
      var buzzes = 0;
      expect(await ackTap(alerts(() => buzzes++), e, out), isFalse);
      expect(buzzes, 0);
    });

    test('a count of 2 is not acked either: the confirm buzz was the ack',
        () async {
      final r = _Rig(await _mapped())..counter = (_) async => 2;
      final e = _tap();
      final out = await r.dispatcher.handle(e);
      expect(shouldAckTap(e, out), isFalse);
    });

    test('an immediate tap (no mapping, or the session failed to start) is '
        'still acked once', () async {
      for (final r in [
        _Rig(await _mapped(three: false, four: false)),
        _Rig(await _mapped())..startFails = true,
      ]) {
        final e = _tap();
        final out = await r.dispatcher.handle(e);
        var buzzes = 0;
        expect(await ackTap(alerts(() => buzzes++), e, out), isTrue);
        expect(buzzes, 1);
      }
    });
  });

  group('AppState wiring (source guard)', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();

    test('the dispatcher is handed the counter; the session reads ecgTapMax',
        () {
      final code = codeOnly(src);
      expect(code, contains('onCountTaps: _countTaps'));
      expect(code, contains('maxTaps: () => gestureSettings.ecgTapMax'));
    });

    test('the gesture session starts the ECG controller without persisting',
        () {
      final begin = bodyOf(src, 'Future<bool> _beginEcgForTap(');
      expect(begin, isNotEmpty);
      expect(codeOnly(begin), contains('persist: false'));
    });

    test('the live event path still acks only through ackTap', () {
      expect(bodyOf(src, 'void _onLiveEvent('), contains('ackTap('));
    });
  });
}
