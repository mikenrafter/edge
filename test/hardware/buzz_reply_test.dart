// 8V: BleEngine.buzzBand(onReply:) tells the Device lab's buzz probe what the
// band said. onReply gets the reply's status name when the band answers and
// null when nothing came inside buzzReplyLogWindow; it never gates delivery (the
// buzz is delivered when the write lands either way).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart' show CommandAwaiter;
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// A gen5 link whose band answers a haptic command with [status], or says
/// nothing when [status] is null.
class _Band {
  _Band(this.status, {bool writeOk = true}) {
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      listening: true,
      onWrite: (frame) async {
        final inner = parseFrame(frame, profile: BandProfile.gen5)!.inner;
        written.add(inner[2]);
        if (!writeOk) return false;
        final s = status;
        if (s != null) {
          engine.debugAbsorbDecoded(
            Decoded('cmd_response', {
              'opcode': inner[2],
              'req_seq': inner[1],
              'cmd_status': s,
            }),
          );
        }
        return true;
      },
    );
  }

  late final BleEngine engine;
  final int? status;
  final written = <int>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('buzzBand onReply', () {
    for (final (status, name) in [
      (CommandAwaiter.statusSuccess, 'success'),
      (CommandAwaiter.statusFailure, 'failure'),
      (CommandAwaiter.statusUnsupported, 'unsupported'),
    ]) {
      test('a $name reply is reported by name, with the ms it took', () async {
        final b = _Band(status);
        final heard = <(String?, int)>[];
        final ok = await b.engine.buzzBand(
          onReply: (s, ms) => heard.add((s, ms)),
        );
        expect(ok, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(heard, hasLength(1));
        expect(heard.single.$1, name);
        expect(heard.single.$2, greaterThanOrEqualTo(0));
        expect(b.written, hasLength(1));
      });
    }

    test('no reply inside the log window reports null, and the buzz was still '
        'delivered', () async {
      final b = _Band(null);
      final heard = <(String?, int)>[];
      final ok = await b.engine.buzzBand(
        onReply: (s, ms) => heard.add((s, ms)),
      );
      expect(ok, isTrue, reason: 'delivery never waits on a reply');
      expect(heard, isEmpty, reason: 'nothing yet');
      await Future<void>.delayed(
        BleEngine.buzzReplyLogWindow + const Duration(milliseconds: 500),
      );
      expect(heard, hasLength(1));
      expect(heard.single.$1, isNull);
      expect(
        heard.single.$2,
        greaterThanOrEqualTo(BleEngine.buzzReplyLogWindow.inMilliseconds - 50),
      );
    });

    test('a failed write never calls onReply and is not delivered', () async {
      final b = _Band(CommandAwaiter.statusSuccess, writeOk: false);
      var calls = 0;
      expect(await b.engine.buzzBand(onReply: (_, _) => calls++), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 0);
    });

    test('a throwing onReply does not break the engine', () async {
      final b = _Band(CommandAwaiter.statusSuccess);
      expect(
        await b.engine.buzzBand(onReply: (_, _) => throw StateError('x')),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await b.engine.buzzBand(), isTrue);
    });
  });
}
