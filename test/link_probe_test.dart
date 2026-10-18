// BleEngine.probeLink(): a real question to the band, answered by a real
// reply. Used by resume paths that find a quiet link after the process was
// suspended (resumeLinkAction.probe). Never "assumes alive".

import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

class _Link {
  final logs = <String>[];
  final written = <({int seq, int opcode})>[];
  late final BleEngine engine;
  bool answerBattery;
  bool writesSucceed;

  _Link({this.answerBattery = false, this.writesSucceed = true}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
    );
    engine.debugInstallFakeLink(
      band: BandProfile.gen4,
      listening: true,
      onWrite: (Uint8List frame) async {
        final p = parseFrame(frame, profile: BandProfile.gen4)!;
        final seq = p.inner[1];
        final opcode = p.inner[2];
        written.add((seq: seq, opcode: opcode));
        if (!writesSucceed) return false;
        if (opcode == Cmd.getBatteryLevel && answerBattery) {
          Future<void>.microtask(() => engine.debugAbsorbDecoded(
                Decoded('cmd_response', {
                  'opcode': Cmd.getBatteryLevel,
                  'req_seq': seq,
                  'cmd_status': CommandAwaiter.statusSuccess,
                  'battery_pct': 61.0,
                }),
              ));
        }
        return true;
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  const fast = Duration(milliseconds: 40);

  test('answered → true, and the reply still lands in state', () async {
    final link = _Link(answerBattery: true);
    expect(await link.engine.probeLink(timeout: fast), isTrue);
    expect(link.written.map((w) => w.opcode), contains(Cmd.getBatteryLevel));
    expect(link.engine.state.batteryPct, 61.0);
  });

  test('unanswered → false after the timeout', () {
    fakeAsync((async) {
      final link = _Link(answerBattery: false);
      bool? result;
      link.engine.probeLink(timeout: fast).then((v) => result = v);

      async.elapse(fast - const Duration(milliseconds: 1));
      expect(result, isNull, reason: 'still waiting for the reply');
      expect(link.engine.pendingCommandCount, 1);

      async.elapse(const Duration(milliseconds: 1));
      expect(result, isFalse);
      expect(link.engine.pendingCommandCount, 0,
          reason: 'the awaiter must not leak a pending entry');
    });
  });

  test('write failed → false immediately', () async {
    final link = _Link(writesSucceed: false);
    expect(await link.engine.probeLink(timeout: fast), isFalse);
  });

  test('no session → false without writing', () async {
    final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    expect(await engine.probeLink(timeout: fast), isFalse);
  });
}
