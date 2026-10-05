// 8W: a custom haptic pattern for the Device lab's pattern probe.
// AlarmPayloads.gen5MaverickPattern builds the RUN_HAPTIC_PATTERN_MAVERICK
// (0x13) body: [0x01, 8 waveform-effect slots (0 = idle), u16 per-effect loop
// control, u8 overall loop]. BleEngine.buzzMaverickPattern writes it like
// buzzBand does (same reply logging and onReply), on a gen5 link only. Every
// band buzz still goes through AlertDispatcher (test/phase7/
// audit_guards_test.dart, test/device_lab_probe_wiring_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart'
    show AlarmPayloads, CommandAwaiter;
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// A link that records every command written (opcode and body) and answers
/// with [status], or says nothing when [status] is null.
class _Band {
  _Band(
    this.status, {
    BandProfile band = BandProfile.gen5,
    bool writeOk = true,
    bool connect = true,
  }) {
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    if (!connect) return;
    engine.debugInstallFakeLink(
      band: band,
      listening: true,
      onWrite: (frame) async {
        final inner = parseFrame(frame, profile: band)!.inner;
        written.add((opcode: inner[2], body: inner.sublist(3).toList()));
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
  final written = <({int opcode, List<int> body})>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('AlarmPayloads.gen5MaverickPattern', () {
    test('revision 1, the effects padded to 8 slots, two zero loop-control '
        'bytes, the overall loop', () {
      expect(AlarmPayloads.gen5MaverickPattern([14, 152, 14]), [
        0x01,
        14,
        152,
        14,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
      ]);
      expect(AlarmPayloads.gen5MaverickPattern([47, 152], loop: 3), [
        0x01,
        47,
        152,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        3,
      ]);
      expect(AlarmPayloads.gen5MaverickPattern([1]).length, 12);
    });

    test('eight effects fill every slot; 255 is a valid effect', () {
      expect(AlarmPayloads.gen5MaverickPattern([1, 2, 3, 4, 5, 6, 7, 255]), [
        0x01,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        255,
        0,
        0,
        1,
      ]);
    });

    test('the loop is 1..3 (the probe\'s safety cap)', () {
      for (final loop in [1, 2, 3]) {
        expect(AlarmPayloads.gen5MaverickPattern([47], loop: loop).last, loop);
      }
    });

    test('anything outside 1 ≤ effects ≤ 8, effect 1..255, loop 1..3 is an '
        'ArgumentError', () {
      for (final bad in <List<int>>[
        [],
        [1, 2, 3, 4, 5, 6, 7, 8, 9],
        [0],
        [47, 0],
        [256],
        [-1],
      ]) {
        expect(
          () => AlarmPayloads.gen5MaverickPattern(bad),
          throwsArgumentError,
          reason: '$bad',
        );
      }
      for (final loop in [0, 4, 255, -1]) {
        expect(
          () => AlarmPayloads.gen5MaverickPattern([47], loop: loop),
          throwsArgumentError,
          reason: 'loop $loop',
        );
      }
    });

    test('the ordinary test buzz is the pair [47, 152], loop 1', () {
      expect(
        AlarmPayloads.gen5MaverickBuzz(),
        AlarmPayloads.gen5MaverickPattern([47, 152]),
      );
    });
  });

  group('BleEngine.buzzMaverickPattern', () {
    test(
      'writes RUN_HAPTIC_PATTERN_MAVERICK with that body on a gen5 band',
      () async {
        final b = _Band(CommandAwaiter.statusSuccess);
        final ok = await b.engine.buzzMaverickPattern(effects: [14, 152, 14]);
        expect(ok, isTrue);
        expect(b.written, hasLength(1));
        expect(b.written.single.opcode, Cmd.runHapticPatternMaverick);
        expect(
          b.written.single.body.take(12),
          AlarmPayloads.gen5MaverickPattern([14, 152, 14]),
        );
      },
    );

    test('the loop goes into the last byte', () async {
      final b = _Band(CommandAwaiter.statusSuccess);
      expect(
        await b.engine.buzzMaverickPattern(effects: [47], loop: 3),
        isTrue,
      );
      expect(
        b.written.single.body.take(12),
        AlarmPayloads.gen5MaverickPattern([47], loop: 3),
      );
      expect(b.written.single.body[11], 3);
    });

    for (final (status, name) in [
      (CommandAwaiter.statusSuccess, 'success'),
      (CommandAwaiter.statusPending, 'pending'),
      (CommandAwaiter.statusFailure, 'failure'),
    ]) {
      test('a $name reply is reported to onReply by name', () async {
        final b = _Band(status);
        final heard = <(String?, int)>[];
        expect(
          await b.engine.buzzMaverickPattern(
            effects: [47, 152],
            onReply: (s, ms) => heard.add((s, ms)),
          ),
          isTrue,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(heard, hasLength(1));
        expect(heard.single.$1, name);
        expect(heard.single.$2, greaterThanOrEqualTo(0));
      });
    }

    test('no reply inside the log window reports null; the write was still '
        'delivery', () async {
      final b = _Band(null);
      final heard = <(String?, int)>[];
      final ok = await b.engine.buzzMaverickPattern(
        effects: [47],
        onReply: (s, ms) => heard.add((s, ms)),
      );
      expect(ok, isTrue, reason: 'delivery never waits on a reply');
      expect(heard, isEmpty);
      await Future<void>.delayed(
        BleEngine.buzzReplyLogWindow + const Duration(milliseconds: 500),
      );
      expect(heard, hasLength(1));
      expect(heard.single.$1, isNull);
    });

    test('a failed write returns false and never calls onReply', () async {
      final b = _Band(CommandAwaiter.statusSuccess, writeOk: false);
      var calls = 0;
      expect(
        await b.engine.buzzMaverickPattern(
          effects: [47],
          onReply: (_, _) => calls++,
        ),
        isFalse,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 0);
    });

    test('a throwing onReply does not break the engine', () async {
      final b = _Band(CommandAwaiter.statusSuccess);
      expect(
        await b.engine.buzzMaverickPattern(
          effects: [47],
          onReply: (_, _) => throw StateError('x'),
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await b.engine.buzzMaverickPattern(effects: [47]), isTrue);
    });

    test('on a gen4 band it returns false and writes nothing', () async {
      final b = _Band(CommandAwaiter.statusSuccess, band: BandProfile.gen4);
      var calls = 0;
      expect(
        await b.engine.buzzMaverickPattern(
          effects: [47, 152],
          onReply: (_, _) => calls++,
        ),
        isFalse,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(b.written, isEmpty);
      expect(calls, 0);
    });

    test('with no link it returns false', () async {
      final b = _Band(null, connect: false);
      expect(await b.engine.buzzMaverickPattern(effects: [47]), isFalse);
    });

    test('an invalid payload returns false and writes nothing (it does not '
        'throw)', () async {
      final b = _Band(CommandAwaiter.statusSuccess);
      expect(await b.engine.buzzMaverickPattern(effects: []), isFalse);
      expect(await b.engine.buzzMaverickPattern(effects: [0]), isFalse);
      expect(await b.engine.buzzMaverickPattern(effects: [256]), isFalse);
      expect(
        await b.engine.buzzMaverickPattern(
          effects: [1, 2, 3, 4, 5, 6, 7, 8, 9],
        ),
        isFalse,
      );
      expect(
        await b.engine.buzzMaverickPattern(effects: [47], loop: 0),
        isFalse,
      );
      expect(
        await b.engine.buzzMaverickPattern(effects: [47], loop: 4),
        isFalse,
      );
      expect(b.written, isEmpty);
    });

    test('maxQueueWait is accepted like buzzBand\'s', () async {
      final b = _Band(CommandAwaiter.statusSuccess);
      expect(
        await b.engine.buzzMaverickPattern(
          effects: [47],
          maxQueueWait: const Duration(seconds: 1),
        ),
        isTrue,
      );
    });
  });
}
