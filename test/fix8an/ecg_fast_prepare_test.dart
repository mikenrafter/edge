// The fast start's band commands (8AN C): PREPARE sends 123 wrist and 139
// filtered ON only, no 125 raw-save ON; CLEANUP is unchanged (124 stop, 139
// OFF, 125 OFF: turning raw-save off when it was never on is harmless); the
// ECG screen's reading path is unchanged and still sends all three; the durable
// guard order stays (guard set and acknowledged BEFORE any write); no
// dangerous opcode is ever written.
//
// ASSUMED API (new, one optional named switch threaded through the stack,
// default true so every existing caller is unchanged):
//   EcgController.begin(wrist, {persist, trace, bool rawSave = true})
//   EcgTransport.prepare(lease, wrist, {bool rawSave = true})   (+ the
//       BleEngineEcgTransport adapter)
//   BleEngine.ecgPrepare(lease, wrist, {bool rawSave = true})
//       -> members selectWrist, filteredOn [, rawSaveOn]
// The fake transport below therefore implements the NEW prepare signature.
// The app's gesture wiring (lib/state/app_state.dart) passes
// `rawSave: false` for fast mode; that wiring is not unit-tested here.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/ecg/ble_ecg_transport.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_guard_store.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_transport.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

// ---- controller over a fake transport ---------------------------------------

EcgCommandListResult _ok(List<String> labels) => EcgCommandListResult([
      for (final l in labels) EcgMemberOutcome(l, written: true, succeeded: true),
    ]);

class _Transport implements EcgTransport {
  _Transport(this.guard);
  final MemoryEcgGuardStore guard;
  final calls = <String>[];
  final prepares = <bool>[]; // the rawSave switch of each prepare
  bool guardSetAtPrepare = false;
  final _events = StreamController<EcgTransportEvent>.broadcast();
  EcgLeaseHandle? current;

  @override
  bool get isReady => true;
  @override
  bool get isMaverick => true;
  @override
  int get linkGeneration => 7;
  @override
  String? get serial => 'MG-SERIAL';
  @override
  Stream<EcgTransportEvent> get events => _events.stream;

  @override
  EcgLeaseHandle? acquire() =>
      current == null ? current = EcgLeaseHandle(Object(), 7) : null;
  @override
  bool leaseValid(EcgLeaseHandle lease) => identical(current, lease);
  @override
  void release(EcgLeaseHandle lease) {
    if (identical(current, lease)) current = null;
  }

  @override
  Future<void> cancelHistory(EcgLeaseHandle lease) async =>
      calls.add('cancelHistory');

  @override
  Future<EcgCommandListResult> prepare(
    EcgLeaseHandle lease,
    EcgWrist wrist, {
    bool rawSave = true,
  }) async {
    calls.add('prepare');
    prepares.add(rawSave);
    guardSetAtPrepare = guard.active.contains('MG-SERIAL');
    return _ok([
      'selectWrist',
      'filteredOn',
      if (rawSave) 'rawSaveOn',
    ]);
  }

  @override
  Future<EcgCommandListResult> start(EcgLeaseHandle lease) async {
    calls.add('start');
    return _ok(['abortHistorical', 'generationStart']);
  }

  @override
  Future<EcgCommandListResult> restart(EcgLeaseHandle lease) async =>
      _ok(['abortHistorical', 'generationRestart']);

  @override
  Future<EcgCommandListResult> cleanup(EcgLeaseHandle lease) async {
    calls.add('cleanup');
    return _ok(['generationStop', 'filteredOff', 'rawSaveOff']);
  }

  @override
  Future<void> requestSync() async => calls.add('sync');
}

class _Rig {
  _Rig() {
    t = _Transport(guard);
    c = EcgController(
      transport: t,
      guard: guard,
      save: (r, p) async {},
      busyReason: () => null,
      holdScreen: (o) async {},
      releaseScreen: (o) async {},
      captureTimeout: const Duration(seconds: 120),
      nowMs: () => 1787823754000,
    );
  }
  final guard = MemoryEcgGuardStore();
  late final _Transport t;
  late final EcgController c;
}

// ---- engine over a fake link ------------------------------------------------

Decoded _ack(int seq, int opcode) => Decoded('cmd_response', {
      'opcode': opcode,
      'req_seq': seq,
      'cmd_status': CommandAwaiter.statusSuccess,
    });

class _Link {
  final commands = <({int seq, int opcode, List<int> body})>[];
  late final BleEngine engine;

  _Link() {
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      onWrite: (frame) async {
        final inner = parseFrame(frame, profile: BandProfile.gen5)!.inner;
        commands.add((seq: inner[1], opcode: inner[2], body: inner.sublist(3)));
        engine.debugAbsorbDecoded(_ack(inner[1], inner[2]));
        return true;
      },
      onCommit: (raws, samples, token,
          {archives, ecgRawPackets, deviceFamily}) async {},
    );
  }

  List<int> get opcodes => commands.map((c) => c.opcode).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('controller', () {
    test('rawSave: false reaches PREPARE; the guard is set first and the '
        'order is unchanged', () async {
      final r = _Rig();
      await r.c.begin(EcgWrist.right, persist: false, rawSave: false);
      expect(r.t.prepares, [false]);
      expect(r.t.guardSetAtPrepare, isTrue,
          reason: 'guard set + acknowledged before any write');
      expect(r.t.calls, ['cancelHistory', 'prepare', 'start']);
      expect(r.guard.log, ['set:MG-SERIAL']);
    });

    test('the default begin (the ECG screen) still asks for raw-save',
        () async {
      final r = _Rig();
      await r.c.begin(EcgWrist.right);
      expect(r.t.prepares, [true]);
    });

    test('a persist: false gesture that wants raw-save keeps it (the two '
        'switches are independent)', () async {
      final r = _Rig();
      await r.c.begin(EcgWrist.right, persist: false);
      expect(r.t.prepares, [true]);
    });

    test('cleanup after a fast start is the ordinary cleanup, once, and '
        'clears the guard', () async {
      final r = _Rig();
      await r.c.begin(EcgWrist.right, persist: false, rawSave: false);
      await r.c.cancel();
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      expect(r.guard.active, isEmpty);
      expect(r.c.isCapturing, isFalse);
    });

    test('the switch is per begin: the next ordinary begin asks for raw-save '
        'again (no sticky flag)', () async {
      final r = _Rig();
      await r.c.begin(EcgWrist.right, persist: false, rawSave: false);
      await r.c.cancel();
      await r.c.begin(EcgWrist.right);
      expect(r.t.prepares, [false, true]);
    });
  });

  group('engine commands', () {
    test('PREPARE with rawSave: false: 123 wrist and 139 ON only', () async {
      final l = _Link();
      final out = await l.engine.ecgPrepare(
        l.engine.ecgAcquire()!,
        WristSelection.right,
        rawSave: false,
      );
      expect(l.opcodes, [123, 139]);
      expect(l.commands[0].body.sublist(0, 5), [1, 1, 0, 0, 0]);
      expect(l.commands[1].body.sublist(0, 2), [1, 1]);
      expect(out.map((o) => o.label), ['selectWrist', 'filteredOn']);
      expect(out.every((o) => o.written && o.succeeded), isTrue);
    });

    test('PREPARE by default is still 123, 139, 125 ON', () async {
      final l = _Link();
      final out = await l.engine
          .ecgPrepare(l.engine.ecgAcquire()!, WristSelection.right);
      expect(l.opcodes, [123, 139, 125]);
      expect(l.commands[2].body.sublist(0, 2), [1, 1]);
      expect(out.map((o) => o.label), ['selectWrist', 'filteredOn', 'rawSaveOn']);
    });

    test('CLEANUP after a fast PREPARE is still all three OFF', () async {
      final l = _Link();
      final lease = l.engine.ecgAcquire()!;
      await l.engine.ecgPrepare(lease, WristSelection.left, rawSave: false);
      l.commands.clear();
      final out = await l.engine.ecgCleanup(lease);
      expect(l.opcodes, [124, 139, 125]);
      expect(l.commands[0].body.sublist(0, 2), [1, 1]);
      expect(l.commands[1].body.sublist(0, 2), [1, 0]);
      expect(l.commands[2].body.sublist(0, 2), [1, 0]);
      expect(out.map((o) => o.label),
          ['generationStop', 'filteredOff', 'rawSaveOff']);
    });

    test('a whole fast session writes no dangerous opcode', () async {
      final l = _Link();
      final lease = l.engine.ecgAcquire()!;
      await l.engine.ecgPrepare(lease, WristSelection.right, rawSave: false);
      await l.engine.ecgStart(lease);
      await l.engine.ecgCleanup(lease);
      expect(l.opcodes, [123, 139, 20, 124, 124, 139, 125]);
      for (final op in l.opcodes) {
        expect(dangerousCmds, isNot(contains(op)), reason: 'opcode $op');
        expect(OpcodeSafety.isDestructive(op), isFalse, reason: 'opcode $op');
      }
    });

    test('a lease that is no longer valid writes nothing, and the list is '
        'still complete', () async {
      final l = _Link();
      final lease = l.engine.ecgAcquire()!;
      l.engine.ecgRelease(lease);
      final out = await l.engine
          .ecgPrepare(lease, WristSelection.right, rawSave: false);
      expect(l.commands, isEmpty);
      expect(out, hasLength(2));
      expect(out.every((o) => !o.written), isTrue);
    });

    test('the transport adapter forwards the switch', () async {
      final l = _Link();
      final transport = BleEngineEcgTransport(
        engine: l.engine,
        serialOf: () => 'MG-SERIAL',
        onRequestSync: () async {},
      );
      final lease = transport.acquire()!;
      final fast = await transport.prepare(lease, EcgWrist.right, rawSave: false);
      expect(l.opcodes, [123, 139]);
      expect(fast.allSucceeded, isTrue);
      expect(fast.outcomes.map((o) => o.label), ['selectWrist', 'filteredOn']);
      l.commands.clear();
      await transport.prepare(lease, EcgWrist.right);
      expect(l.opcodes, [123, 139, 125]);
      transport.dispose();
    });
  });
}
