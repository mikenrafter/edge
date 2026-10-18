// A dispatcher handed Log water anyway (RED).
//
// The standalone action is retired, but an old action value can still reach
// the dispatcher (a setter, a not-yet-migrated store). It must not silently do
// nothing, and must not write water: the rule is the simplest consistent one,
// it IS Mark a moment (the follow-up then asks, and its Water answer adds the
// glass). Mapped before the claim, so a tap with both selected marks ONCE.
//
// No `onLogWater` handler is wired anywhere in this file on purpose.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/dart_source_lexical.dart';

final DateTime _t0 = DateTime.utc(2026, 3, 14, 12, 0, 0);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap() => StrapEvent(
      eventId: 14,
      tsEpoch: _t0Sec,
      tsSubsec: 0,
      receivedAt: _t0.add(const Duration(seconds: 1)),
      hex: '',
      deviceId: 'dev-a',
    );

Future<GestureSettings> _settings(Set<DeviceAction> actions) async {
  SharedPreferences.setMockInitialValues({});
  final s = GestureSettings();
  await s.setDoubleTapActions(actions);
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Log water alone runs Mark a moment, once, and it succeeds', () async {
    final s = await _settings({DeviceAction.logWater});
    final marks = <StrapEvent>[];
    final claims = <String>{};
    final d = GestureDispatcher(
      settings: s,
      onMarkMoment: (e) async => marks.add(e),
      claim: (k) async => claims.add(k),
      release: (k) async => claims.remove(k),
    );
    final out = await d.handle(_tap());
    expect(marks, hasLength(1), reason: 'not silently dropped');
    expect(out, isNotEmpty);
    expect(out.map((o) => o.status), everyElement(GestureStatus.ran));
    expect(claims.where((k) => k.endsWith(':mark_moment')), hasLength(1));
    expect(claims.where((k) => k.contains('log_water')), isEmpty,
        reason: 'the occurrence is claimed as the action that ran');
  });

  test('Log water AND Mark a moment together mark once, not twice', () async {
    final s = await _settings({DeviceAction.logWater, DeviceAction.markMoment});
    final marks = <StrapEvent>[];
    final d = GestureDispatcher(
      settings: s,
      onMarkMoment: (e) async => marks.add(e),
      claim: (k) async => true,
    );
    final out = await d.handle(_tap());
    expect(marks, hasLength(1));
    expect(out.map((o) => o.status), everyElement(GestureStatus.ran));
  });

  test('through the slot handler it arrives as Mark a moment on its slot',
      () async {
    final s = await _settings({DeviceAction.logWater});
    final calls = <(String, DeviceAction)>[];
    final d = GestureDispatcher(
      settings: s,
      onSlotAction: (slot, a, e) async => calls.add((slot, a)),
      claim: (k) async => true,
    );
    await d.handle(_tap());
    expect(calls, [('double', DeviceAction.markMoment)]);
  });

  test('with no mark-moment handler it FAILS loudly, never a silent no-op',
      () async {
    final s = await _settings({DeviceAction.logWater});
    final d = GestureDispatcher(settings: s, claim: (k) async => true);
    final out = await d.handle(_tap());
    expect(out, isNotEmpty);
    expect(out.map((o) => o.status), everyElement(GestureStatus.failed));
  });

  test('a tap replayed from history is judged by Mark a moment\'s replay '
      'setting (Log water never replayed; Mark a moment does)', () async {
    // Mark a moment is the one action safe to replay (it stamps the tap's own
    // time). Handed logWater, the dispatcher treats it as exactly that action.
    final s = await _settings({DeviceAction.logWater});
    await s.setReplayHistorical(DeviceAction.markMoment, true);
    final marks = <StrapEvent>[];
    final d = GestureDispatcher(
      settings: s,
      onMarkMoment: (e) async => marks.add(e),
      claim: (k) async => true,
    );
    final stale = StrapEvent(
      eventId: 14,
      tsEpoch: _t0Sec,
      tsSubsec: 0,
      receivedAt: _t0.add(const Duration(hours: 2)),
      hex: '',
      deviceId: 'dev-a',
    );
    final out = await d.handle(stale);
    expect(marks, hasLength(1), reason: 'replay is on for Mark a moment');
    expect(out.map((o) => o.status), everyElement(GestureStatus.ran));
  });

  test('the old gesture water write path is gone from AppState', () {
    final code = codeOnly(File('lib/state/app_state.dart').readAsStringSync());
    expect(code.contains('_logWaterFromGesture'), isFalse);
    expect(code.contains('_writingWaterFromGesture'), isFalse);
  });
}
