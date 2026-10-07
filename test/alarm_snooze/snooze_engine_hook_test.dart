// BleEngine.onHapticsTerminated: HAPTICS_TERMINATED(100) reaches AppState with
// its cause. RED: the hook is declared but the engine never calls it.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List _eventInner(int id, List<int> body, {int ts = 1786000000}) {
  final inner = Uint8List(12 + body.length);
  inner[0] = PacketType.event;
  inner[1] = 0x07;
  final view = ByteData.sublistView(inner);
  view.setUint16(2, id, Endian.little);
  view.setUint32(4, ts, Endian.little);
  view.setUint16(8, 0, Endian.little);
  view.setUint16(10, body.length, Endian.little);
  inner.setRange(12, inner.length, body);
  return inner;
}

({BleEngine engine, List<String> logs}) _rig() {
  final logs = <String>[];
  final engine = BleEngine(
    onRecord: (_, _) async {},
    onState: (_) {},
    log: logs.add,
  );
  engine.debugInstallFakeLink(
    onWrite: (_) async => true,
    band: BandProfile.gen5,
  );
  return (engine: engine, logs: logs);
}

void _terminate(BleEngine e, int code) => e.debugProcessImmediateFrame(Frame(
      _eventInner(EventId.hapticsTerminated, <int>[1, code]),
      true,
      true,
    ));

void main() {
  test('each termination reaches the hook with its cause and a receipt time',
      () {
    final r = _rig();
    final seen = <(String, DateTime)>[];
    r.engine.onHapticsTerminated = (cause, at) => seen.add((cause, at));
    final before = DateTime.now();
    _terminate(r.engine, HapticsTermination.userDoubleTap);
    _terminate(r.engine, HapticsTermination.expired);
    _terminate(r.engine, HapticsTermination.error);
    expect([for (final s in seen) s.$1], ['user_double_tap', 'expired', 'error']);
    for (final s in seen) {
      expect(s.$2.isBefore(before), isFalse, reason: 'the phone clock, now');
    }
  });

  test('an unknown code reaches the hook as its code_N name', () {
    final r = _rig();
    final seen = <String>[];
    r.engine.onHapticsTerminated = (cause, at) => seen.add(cause);
    _terminate(r.engine, 9);
    expect(seen, ['code_9']);
  });

  test('a hook that throws cannot break the engine\'s own bookkeeping', () {
    final r = _rig();
    var calls = 0;
    r.engine.onHapticsTerminated = (cause, at) {
      calls++;
      throw StateError('boom');
    };
    _terminate(r.engine, HapticsTermination.userDoubleTap);
    expect(calls, 1, reason: 'the hook ran');
    expect(r.engine.lastHapticsDoubleTapAt, isNotNull);
    expect(r.engine.offloadSnapshot['last_haptics_termination'],
        'user_double_tap');
  });
}
