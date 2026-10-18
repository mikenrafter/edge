// "Toggle ECG recording on double tap": the persisted switch, and the
// dispatcher starting exactly one capture for a live tap on a WHOOP MG.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('openstrap/device_actions');
const _key = 'gesture_ecg_on_double_tap';

final DateTime _t0 = DateTime.utc(2026, 10, 2, 8);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _tap({Duration late = const Duration(seconds: 1), int id = 14}) =>
    StrapEvent(
      eventId: id,
      tsEpoch: _t0Sec,
      receivedAt: _t0.add(late),
      hex: '',
      deviceId: 'band',
    );

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

class _Rig {
  _Rig(this.settings, {this.mg = true});
  final GestureSettings settings;
  bool mg;
  final Set<String> claims = {};
  final List<StrapEvent> started = [];

  GestureDispatcher build() => GestureDispatcher(
        settings: settings,
        performNative: (_) async => true,
        claim: (k) async => claims.add(k),
        release: (k) async => claims.remove(k),
        ecgSupported: () => mg,
        onEcgTap: (e) async => started.add(e),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('GestureSettings.ecgOnDoubleTap', () {
    test('off by default', () async {
      final s = await _boot({});
      expect(s.ecgOnDoubleTap, isFalse);
    });

    test('stored with the gesture settings and survives a restart', () async {
      final s = await _boot({});
      var notified = 0;
      s.addListener(() => notified++);
      await s.setEcgOnDoubleTap(true);
      expect(s.ecgOnDoubleTap, isTrue);
      expect(notified, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_key), isTrue);
      final again = GestureSettings();
      await again.bootstrap();
      expect(again.ecgOnDoubleTap, isTrue);
    });
  });

  group('dispatcher: ECG on double tap', () {
    test('live tap, switch on, WHOOP MG -> exactly one capture', () async {
      final rig = _Rig(await _boot({_key: true}));
      final d = rig.build();
      await d.handle(_tap());
      expect(rig.started, hasLength(1));
    });

    test('the same tap delivered again starts nothing more', () async {
      final rig = _Rig(await _boot({_key: true}));
      final d = rig.build();
      await d.handle(_tap());
      await d.handle(_tap());
      await rig.build().handle(_tap()); // after a "restart"
      expect(rig.started, hasLength(1));
    });

    test('works with no double-tap action mapped', () async {
      final s = await _boot({_key: true});
      expect(s.doubleTapActions, isEmpty);
      final rig = _Rig(s);
      await rig.build().handle(_tap());
      expect(rig.started, hasLength(1));
    });

    test('late tap -> none', () async {
      final rig = _Rig(await _boot({_key: true}));
      await rig.build().handle(_tap(late: const Duration(hours: 2)));
      expect(rig.started, isEmpty);
    });

    test('switch off -> none', () async {
      final rig = _Rig(await _boot({}));
      await rig.build().handle(_tap());
      expect(rig.started, isEmpty);
    });

    test('not a WHOOP MG -> none, even with the switch on', () async {
      final rig = _Rig(await _boot({_key: true}), mg: false);
      await rig.build().handle(_tap());
      expect(rig.started, isEmpty);
    });

    test('other event ids -> none', () async {
      final rig = _Rig(await _boot({_key: true}));
      await rig.build().handle(_tap(id: 7));
      expect(rig.started, isEmpty);
    });

    test('switch on suspends every normal double-tap action', () async {
      final s = await _boot({
        _key: true,
        // Mark moment mapped (bit 8).
        'gesture_double_tap_actions': 1 << 8,
      });
      expect(s.doubleTapActions, isNotEmpty);
      final marked = <StrapEvent>[];
      final started = <StrapEvent>[];
      final d = GestureDispatcher(
        settings: s,
        performNative: (_) async => true,
        claim: (k) async => true,
        release: (k) async {},
        onMarkMoment: (e) async => marked.add(e),
        ecgSupported: () => true,
        onEcgTap: (e) async => started.add(e),
      );
      final out = await d.handle(_tap());
      expect(marked, isEmpty);
      expect(out.where((o) => o.status == GestureStatus.ran), isEmpty);
      expect(started, hasLength(1));
    });

    test('switch off: normal actions run as before', () async {
      final s = await _boot({'gesture_double_tap_actions': 1 << 8});
      final marked = <StrapEvent>[];
      final d = GestureDispatcher(
        settings: s,
        performNative: (_) async => true,
        claim: (k) async => true,
        release: (k) async {},
        onMarkMoment: (e) async => marked.add(e),
        ecgSupported: () => true,
        onEcgTap: (e) async {},
      );
      await d.handle(_tap());
      expect(marked, hasLength(1));
    });

    test('a failed start gives the claim back so a retry can run', () async {
      final s = await _boot({_key: true});
      final claims = <String>{};
      var calls = 0;
      GestureDispatcher d() => GestureDispatcher(
            settings: s,
            performNative: (_) async => true,
            claim: (k) async => claims.add(k),
            release: (k) async => claims.remove(k),
            ecgSupported: () => true,
            onEcgTap: (e) async {
              calls++;
              if (calls == 1) throw StateError('transport busy');
            },
          );
      await d().handle(_tap());
      await d().handle(_tap());
      expect(calls, 2);
    });
  });
}
