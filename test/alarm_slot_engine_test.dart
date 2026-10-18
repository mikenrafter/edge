// The engine's three alarm-slot calls for the Device lab probe, over the fake
// link seam (no radio): what goes on the wire for each band family and slot,
// and how the band's replies are read.
//
//   setAlarmSlot   SET_ALARM_TIME for probe alarm A (slot 0) or B (slot 1)
//   readAlarmSlot  GET_ALARM_TIME for that slot (gen5 by id; gen4 has no index)
//   clearAlarmSlot DISABLE_ALARM for that slot (gen5 by id, never 0xFF)

import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

final DateTime _when = DateTime.fromMillisecondsSinceEpoch(1790000120 * 1000);

class _Link {
  _Link({
    this.band = proto.BandProfile.gen5,
    this.replyTo,
    this.writeOk = true,
  }) {
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {}, log: logs.add);
    engine.debugInstallFakeLink(
      band: band,
      onWrite: (frame) async {
        final inner = proto.parseFrame(frame, profile: band)!.inner;
        writes.add((opcode: inner[2], inner: inner));
        final reply = replyTo?.call(inner[1], inner[2]);
        if (reply != null) engine.debugAbsorbDecoded(reply);
        return writeOk;
      },
    );
  }

  final proto.BandProfile band;
  final proto.Decoded? Function(int seq, int opcode)? replyTo;
  final bool writeOk;
  final logs = <String>[];
  final writes = <({int opcode, Uint8List inner})>[];
  late final BleEngine engine;

  /// The written frames for [opcode].
  List<Uint8List> of(int opcode) =>
      [for (final w in writes) if (w.opcode == opcode) w.inner];
}

/// True when [body] appears in [frame] as a contiguous run.
bool _has(Uint8List frame, List<int> body) {
  for (var i = 0; i + body.length <= frame.length; i++) {
    var ok = true;
    for (var j = 0; j < body.length; j++) {
      if (frame[i + j] != body[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

proto.Decoded _statusReply(int opcode, int seq, int alarmStatus,
    {int outer = 1}) {
  final inner =
      Uint8List.fromList([0x24, 0x55, opcode, seq, outer, 3, alarmStatus]);
  final r = proto.parseCommandResponse(inner, profile: proto.BandProfile.gen5)!;
  return proto.Decoded('cmd_response', {'opcode': r.opcode, ...r.decoded});
}

proto.Decoded _outerReply(int opcode, int seq, int status) =>
    proto.Decoded('cmd_response',
        {'opcode': opcode, 'req_seq': seq, 'cmd_status': status});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('setAlarmSlot', () {
    test('gen5 slot B writes the id-2 rich body, and reports an accept',
        () async {
      final link = _Link(
        replyTo: (seq, op) => op == proto.Cmd.setAlarmTime
            ? _statusReply(op, seq, proto.AlarmStatus.validInputPattern)
            : null,
      );
      final w = await link.engine.setAlarmSlot(_when, slot: 1);
      final frames = link.of(proto.Cmd.setAlarmTime);
      expect(frames, hasLength(1));
      expect(
        _has(frames.single,
            AlarmPayloads.probeBody(_when, isGen5: true, slot: 1)),
        isTrue,
      );
      expect(w.written, isTrue);
      expect(w.answered, isTrue);
      expect(w.rejected, isFalse);
      expect(w.alarmStatus, proto.AlarmStatus.validInputPattern);
      expect(w.alarmStatusName, 'valid_input_pattern');
      expect(w.wallSec, 1790000120);
      expect(w.strapSec, 1790000120, reason: 'no clock correlation: no shift');
      expect(link.logs.any((l) => l.contains('[alarm]')), isTrue,
          reason: 'always-on dev log line');
    });

    test('gen5 slot A is id 1', () {
      fakeAsync((async) {
        final link = _Link(); // nothing answers: only the frame matters here
        link.engine.setAlarmSlot(_when, slot: 0);
        async.elapse(const Duration(seconds: 6));
        final frames = link.of(proto.Cmd.setAlarmTime);
        expect(
          _has(frames.single,
              AlarmPayloads.probeBody(_when, isGen5: true, slot: 0)),
          isTrue,
        );
      });
    });

    test('gen4 slot B is the rich form at index 1 (the rev-1 form has no index)',
        () {
      fakeAsync((async) {
        final link = _Link(band: proto.BandProfile.gen4);
        link.engine.setAlarmSlot(_when, slot: 1);
        async.elapse(const Duration(seconds: 6));
        final frames = link.of(proto.Cmd.setAlarmTime);
        expect(
          _has(frames.single,
              AlarmPayloads.probeBody(_when, isGen5: false, slot: 1)),
          isTrue,
        );
      });
    });

    test('an input rejection is reported as rejected, with its name',
        () async {
      final link = _Link(
        replyTo: (seq, op) => op == proto.Cmd.setAlarmTime
            ? _statusReply(op, seq, proto.AlarmStatus.invalidAlarmId)
            : null,
      );
      final w = await link.engine.setAlarmSlot(_when, slot: 1);
      expect(w.rejected, isTrue);
      expect(w.alarmStatusName, 'invalid_alarm_id');
    });

    test('a FAILURE outer result is a refusal even with no status byte',
        () async {
      final link = _Link(
        replyTo: (seq, op) => op == proto.Cmd.setAlarmTime
            ? _outerReply(op, seq, CommandAwaiter.statusFailure)
            : null,
      );
      final w = await link.engine.setAlarmSlot(_when, slot: 1);
      expect(w.rejected, isTrue);
      expect(w.resultStatus, CommandAwaiter.statusFailure);
    });

    test('an unanswered write is "sent, no reply", not a refusal', () {
      fakeAsync((async) {
        final link = _Link();
        AlarmSlotWrite? w;
        link.engine.setAlarmSlot(_when, slot: 1).then((v) => w = v);
        async.elapse(const Duration(seconds: 6));
        expect(w, isNotNull);
        expect(w!.written, isTrue);
        expect(w!.answered, isFalse);
        expect(w!.rejected, isFalse);
      });
    });

    test('a write that never left the phone says so', () async {
      final link = _Link(writeOk: false);
      final w = await link.engine.setAlarmSlot(_when, slot: 1);
      expect(w.written, isFalse);
      expect(link.engine.pendingCommandCount, 0);
    });

    test('only slots 0 and 1 exist', () async {
      final link = _Link();
      await expectLater(
          link.engine.setAlarmSlot(_when, slot: 2), throwsArgumentError);
      expect(link.of(proto.Cmd.setAlarmTime), isEmpty);
    });
  });

  group('readAlarmSlot', () {
    // GET_ALARM_TIME rev-4 reply: body [04][active][epoch u32][subsec u16].
    proto.Decoded getReply(int seq, int epoch, {int active = 1}) {
      final inner = Uint8List.fromList([
        0x24, 0x55, proto.Cmd.getAlarmTime, seq, 1, //
        0x04, active,
        epoch & 0xff, (epoch >> 8) & 0xff, (epoch >> 16) & 0xff,
        (epoch >> 24) & 0xff,
        0, 0,
      ]);
      final r =
          proto.parseCommandResponse(inner, profile: proto.BandProfile.gen5)!;
      return proto.Decoded('cmd_response', {'opcode': r.opcode, ...r.decoded});
    }

    test('gen5 asks for the slot by id and reads epoch and active', () async {
      final link = _Link(
        replyTo: (seq, op) =>
            op == proto.Cmd.getAlarmTime ? getReply(seq, 1790000180) : null,
      );
      final r = await link.engine.readAlarmSlot(slot: 1);
      expect(
        _has(link.of(proto.Cmd.getAlarmTime).single,
            AlarmPayloads.probeReadBody(isGen5: true, slot: 1)),
        isTrue,
      );
      expect(r.answered, isTrue);
      expect(r.epoch, 1790000180);
      expect(r.active, isTrue);
    });

    test('an inactive slot reads active false', () async {
      final link = _Link(
        replyTo: (seq, op) => op == proto.Cmd.getAlarmTime
            ? getReply(seq, 1790000180, active: 0)
            : null,
      );
      final r = await link.engine.readAlarmSlot(slot: 0);
      expect(r.answered, isTrue);
      expect(r.active, isFalse);
    });

    test('no reply is silent, never a guessed epoch', () {
      fakeAsync((async) {
        final link = _Link();
        AlarmSlotRead? r;
        link.engine.readAlarmSlot(slot: 1).then((v) => r = v);
        async.elapse(const Duration(seconds: 6));
        expect(r, isNotNull);
        expect(r!.answered, isFalse);
        expect(r!.epoch, isNull);
      });
    });
  });

  group('clearAlarmSlot', () {
    test('gen5 clears exactly one id, never the all-slots 0xFF', () async {
      final link = _Link(
        replyTo: (seq, op) => op == proto.Cmd.disableAlarm
            ? _outerReply(op, seq, CommandAwaiter.statusSuccess)
            : null,
      );
      expect(await link.engine.clearAlarmSlot(slot: 1), isTrue);
      final frame = link.of(proto.Cmd.disableAlarm).single;
      expect(_has(frame, AlarmPayloads.probeClearBody(isGen5: true, slot: 1)),
          isTrue);
      expect(_has(frame, const [0x02, 0xFF]), isFalse);
    });

    test('a refused clear is false, so the probe says so', () async {
      final link = _Link(
        replyTo: (seq, op) => op == proto.Cmd.disableAlarm
            ? _outerReply(op, seq, CommandAwaiter.statusFailure)
            : null,
      );
      expect(await link.engine.clearAlarmSlot(slot: 1), isFalse);
    });

    test('a clear that never left the phone is false', () async {
      final link = _Link(writeOk: false);
      expect(await link.engine.clearAlarmSlot(slot: 1), isFalse);
    });
  });
}
