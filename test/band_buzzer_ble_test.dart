import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/band_buzzer.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/default_band_buzzer.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

import 'support/band_buzzer_fakes.dart';

base class _NoRadio extends FlutterBluePlusPlatform {
  final connections = StreamController<BmConnectionStateResponse>.broadcast();
  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged => connections.stream;
  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    connections.add(BmConnectionStateResponse(remoteId: request.remoteId,
        connectionState: BmConnectionStateEnum.disconnected,
        disconnectReasonCode: null, disconnectReasonString: null));
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  for (final band in [proto.BandProfile.gen4, proto.BandProfile.gen5]) {
    final generation = band.isGen5 ? 'gen5' : 'gen4';
    test('$generation checked writes preserve the existing alarm and pulse bytes', () async {
      final written = <List<int>>[];
      final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      engine.debugInstallFakeLink(band: band, onWrite: (frame) async {
        written.add(proto.parseFrame(frame, profile: band)!.inner.sublist(2));
        return true;
      });
      expect(await engine.runAlarmChecked(), isTrue);
      expect(await engine.buzzChecked(), isTrue);
      // Gen4 RUN_ALARM=0x44 rev1; gen5 uses the existing Maverick pulse.
      // Gen5's 12-byte body is followed by one frame-alignment byte.
      if (band == proto.BandProfile.gen4) {
        expect(written, [
          [0x44, 1],
          [0x4f, 2, 0, 0, 0, 0],
        ]);
      } else {
        expect(written, [
          [0x13, 1, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0],
          [0x13, 1, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0],
        ]);
      }
    });

    test('$generation checked write exposes false after reaching transport', () async {
      var calls = 0;
      var accepted = true;
      final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      engine.debugInstallFakeLink(band: band, onWrite: (_) async {
        calls++;
        return accepted;
      });
      expect(await engine.buzzChecked(), isTrue);
      accepted = false;
      expect(await engine.buzzChecked(), isFalse);
      expect(await engine.runAlarmChecked(), isFalse);
      expect(calls, 3);
    });
  }

  test('checked methods refuse a missing link before the transport seam', () async {
    FlutterBluePlusPlatform? original;
    try { original = FlutterBluePlusPlatform.instance; } on UnsupportedError {
      // Unit-test runners may have no registered Bluetooth plugin.
    }
    final platform = _NoRadio();
    FlutterBluePlusPlatform.instance = platform;
    addTearDown(() async {
      if (original != null) FlutterBluePlusPlatform.instance = original;
      await platform.connections.close();
    });
    var calls = 0;
    final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugInstallFakeLink(onWrite: (_) async { calls++; return true; });
    expect(await engine.buzzChecked(), isTrue);
    await engine.disconnect();
    expect(await engine.buzzChecked(), isFalse);
    expect(await engine.runAlarmChecked(), isFalse);
    expect(calls, 1);
  });

  test('stop during real guarded write leaves native SET_ALARM untouched', () async {
    final clock = WakeClock(DateTime.utc(2026, 10, 25, 6));
    final gate = Completer<bool>();
    final opcodes = <int>[];
    final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugInstallFakeLink(onWrite: (frame) async {
      opcodes.add(proto.parseFrame(frame)!.inner[2]);
      return opcodes.length == 1 ? gate.future : true;
    });
    addTearDown(() { if (!gate.isCompleted) gate.complete(true); });
    final buzzer = DefaultBandBuzzer(
        transport: engine, now: clock.now, delay: clock.delay);
    final play = buzzer.play(BandBuzzRequest(id: 'a:0', scope: 'a',
        expiresAt: clock.at.add(const Duration(minutes: 1)),
        kind: BandBuzzKind.rampStep, stepIndex: 0, stepCount: 4, pulses: 4));
    await wakeMicrotasks();
    expect(opcodes, [proto.Cmd.runHapticsPattern]);
    buzzer.stop('a');
    gate.complete(true);
    expect(await play, BandBuzzResult.partial);
    expect(opcodes, [proto.Cmd.runHapticsPattern],
        reason: 'cancellation sends neither SET_ALARM nor DISABLE_ALARM');
  });

  test('AppState default composition plays through its own checked engine', () {
    fakeAsync((time) {
      final app = AppState(initialize: false);
      addTearDown(app.dispose);
      final written = <int>[];
      app.engine.debugInstallFakeLink(onWrite: (frame) async {
        written.add(proto.parseFrame(frame)!.inner[2]);
        return true;
      });
      final now = DateTime.utc(2026, 10, 25, 6);
      withClock(Clock.fixed(now), () {
        BandBuzzResult? result;
        app.bandBuzzer.play(BandBuzzRequest(id: 'default:0', scope: 'default',
            expiresAt: now.add(const Duration(minutes: 1)),
            kind: BandBuzzKind.rampStep, stepIndex: 0, stepCount: 3, pulses: 2))
            .then((value) => result = value);
        time.elapse(const Duration(seconds: 2));
        expect(result, BandBuzzResult.complete);
        expect(written, [0x4f, 0x4f]);
      });
    });
  });

  test('existing guarded write blocks destructive commands with positive control', () async {
    final written = <int>[];
    final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
    engine.debugInstallFakeLink(onWrite: (frame) async {
      written.add(proto.parseFrame(frame)!.inner[2]);
      return true;
    });
    await engine.buzz();
    expect(written, [proto.Cmd.runHapticsPattern]);
    // Explicit opcodes, independent of the set under test.
    for (final opcode in [proto.Cmd.forceTrim, proto.Cmd.rebootStrap, proto.Cmd.powerCycleStrap]) {
      expect(await engine.debugWriteRaw(proto.buildCommand(
          1, opcode, const [], proto.BandProfile.gen4)), isFalse);
    }
    expect(written, [proto.Cmd.runHapticsPattern]);
  });
}
