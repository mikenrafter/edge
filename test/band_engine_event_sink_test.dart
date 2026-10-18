// The engine hands the app a StrapEvent, not three positional values
// (an event value object with eventId, tsEpoch, tsSubsec, receive time, and
// raw diagnostics replaces the positional EventSink callback).
//
// BleEngine CAN be driven headlessly: `debugInstallFakeLink` +
// `debugProcessImmediateFrame` push a real EVENT frame through the real
// `_processImmediateFrame` path (the same code the notify callback reaches), so
// the first group uses the engine itself. The second group is a source guard on
// the wiring that no headless test can reach (AppState's two engine closures, the
// headless drain, `_markMomentFromGesture`) — the same style as
// test/reset_quiesces_ingest_test.dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

final DateTime _t0 = DateTime.utc(2026, 3, 14, 12, 0, 0);
final int _t0Sec = _t0.millisecondsSinceEpoch ~/ 1000;

Uint8List _eventInner(int id, int ts, int subsec) {
  final inner = Uint8List(12);
  final v = ByteData.sublistView(inner);
  inner[0] = PacketType.event;
  inner[1] = 0x07;
  v.setUint16(2, id, Endian.little);
  v.setUint32(4, ts, Endian.little);
  v.setUint16(8, subsec, Endian.little);
  v.setUint16(10, 0, Endian.little);
  return inner;
}

String _hex(Uint8List b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

({BleEngine engine, List<StrapEvent> got}) _rig({
  DateTime Function()? clock,
  BandProfile band = BandProfile.gen4,
}) {
  final got = <StrapEvent>[];
  final engine = BleEngine(
    onRecord: (_, _) async {},
    onState: (_) {},
    onEvent: got.add,
    clock: clock,
  );
  engine.debugInstallFakeLink(onWrite: (_) async => true, band: band);
  return (engine: engine, got: got);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BleEngine.onEvent receives a StrapEvent', () {
    test('with the frame\'s id, whole seconds, SUBSEC and verbatim hex', () {
      final r = _rig(clock: () => _t0.add(const Duration(seconds: 1)));
      final inner = _eventInner(14, _t0Sec, 29491);
      r.engine.debugProcessImmediateFrame(Frame(inner, true, true));

      final e = r.got.single;
      expect(e.eventId, 14);
      expect(e.tsEpoch, _t0Sec);
      expect(e.tsSubsec, 29491, reason: 'the subsec must not be dropped here');
      expect(e.hex, _hex(inner));
      expect(e.name, 'DOUBLE_TAP');
      expect(e.strapTime.microsecondsSinceEpoch,
          _t0Sec * 1000000 + (29491 * 1000000) ~/ 32768);
    });

    test('stamped with the receive time from the engine clock, per frame', () {
      var now = _t0.add(const Duration(seconds: 1));
      final r = _rig(clock: () => now);
      r.engine.debugProcessImmediateFrame(
          Frame(_eventInner(14, _t0Sec, 10), true, true));
      now = _t0.add(const Duration(hours: 2)); // the next one arrives late
      r.engine.debugProcessImmediateFrame(
          Frame(_eventInner(14, _t0Sec + 1, 20), true, true));

      expect(r.got, hasLength(2));
      expect(r.got[0].receivedAt, _t0.add(const Duration(seconds: 1)));
      expect(r.got[1].receivedAt, _t0.add(const Duration(hours: 2)));
      // Receipt time never leaks into the strap's own time.
      expect(r.got[1].tsEpoch, _t0Sec + 1);
      expect(r.got[1].tsSubsec, 20);
      expect(r.got[1].isLive, isFalse);
    });

    test('without an injected clock the receive time is the real now, bracketed',
        () {
      final r = _rig();
      final before = DateTime.now();
      r.engine.debugProcessImmediateFrame(
          Frame(_eventInner(14, _t0Sec, 0), true, true));
      final after = DateTime.now();
      final got = r.got.single.receivedAt;
      expect(got.isBefore(before), isFalse);
      expect(got.isAfter(after), isFalse);
    });

    test('names the device the engine knows about: the primary', () {
      final r = _rig(clock: () => _t0);
      r.engine.debugProcessImmediateFrame(
          Frame(_eventInner(14, _t0Sec, 0), true, true));
      expect(r.got.single.deviceId, LocalDb.kPrimaryDeviceId);
    });

    test('the same on a gen5 link', () {
      final r = _rig(clock: () => _t0, band: BandProfile.gen5);
      r.engine.debugProcessImmediateFrame(
          Frame(_eventInner(14, _t0Sec, 777), true, true));
      expect(r.got.single.tsSubsec, 777);
      expect(r.got.single.eventId, 14);
    });

    test('every event reaches the sink; the dispatcher, not the engine, '
        'decides which are gestures', () {
      final r = _rig(clock: () => _t0);
      for (final id in const [14, 14, 100]) {
        r.engine.debugProcessImmediateFrame(
            Frame(_eventInner(id, _t0Sec, id), true, true));
      }
      expect(r.got.map((e) => e.eventId), [14, 14, 100]);
    });
  });

  group('wiring (source guards for paths no headless test can reach)', () {
    String read(String path) => File(path).readAsStringSync();

    test('AppState: both engine closures take the event, and dispatch via '
        '`handle`', () {
      final src = read('lib/state/app_state.dart');
      expect(src.contains('onEvent: (id, ts, hex)'), isFalse,
          reason: 'the positional closures must be gone');
      expect(src.contains('_gestureDispatcher.onEvent('), isFalse);
      expect(src.contains('_gestures.onEvent('), isFalse);
      // The dispatcher is owned by the gesture controller.
      expect(src, contains('_gestures.handle('));
    });

    test('the headless drain persists the full event, not (id, ts, hex)', () {
      final src = read('lib/sync/background_sync.dart');
      expect(src.contains('onEvent: (id, ts, hex)'), isFalse);
      expect(src, contains('insertStrapEvent('));
    });

    test('the live path persists the full event too', () {
      expect(read('lib/state/app_state.dart'), contains('insertStrapEvent('));
    });

    test('Mark moment never asks the clock what time it is', () {
      final src = read('lib/state/app_state.dart');
      final start = src.indexOf('Future<void> _markMomentFromGesture(');
      expect(start, greaterThanOrEqualTo(0));
      final end = src.indexOf('\n  }\n', start);
      final body = src.substring(start, end);
      expect(body.contains('DateTime.now()'), isFalse,
          reason: 'event time comes from momentStampFor(event)');
      expect(body, contains('momentStampFor('));
      expect(body, contains('withMomentTag('));
    });
  });
}
