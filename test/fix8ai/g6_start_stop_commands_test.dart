// 8AI G6: "Start live feed" / "Stop" for the connected band — what goes on the
// wire, per family, and that nothing is left running.
//
// WHY THIS IS NEEDED. On gen5 an ordinary foreground connection owns no live
// stream (#287: `desiredLiveStreams` is HR only for a mounted live-HR view /
// workout / breathing, IMU only for a gait workout), and gen5 realtime frames
// only flow once opcode 3 (HR) and 0x6A (IMU) are written. The Live devices
// screen is none of those owners, so on a connected MG it shows nothing. (gen4
// in the foreground already owns HR + the R10/R11 + IMU + optical bundle via
// `LiveStreamOwners.foreground`.)
//
// ASSUMED API (see support/g6_support.dart for the shims):
//   Future<void> AppState.startLiveFeed(String deviceId)
//   Future<void> AppState.stopLiveFeed(String deviceId)
//   bool         AppState.isLiveFeedOn(String deviceId)
//   LiveStreamOwners.developerLiveFeed
//     a NEW owner of BOTH streams on both families; AppState sets it in
//     startLiveFeed and clears it in stopLiveFeed (in a `finally`, §4.3), then
//     nudges the engine. The EXISTING serialized reconciler (`_reconcileLive`)
//     stays the only writer, so no new opcode and no second write path (§3.8).
//     Starting also clears the sticky radio fallback, exactly like
//     `clearRadioFallbackAndReconcile` does for a workout, or a latched
//     fallback would give a gen4 user HR only.
//   deviceId '' is the band. Start is idempotent; Stop without Start writes
//   nothing.
//
// WIRE (existing commands only):
//   gen5 ON   03(1), 6A(rev1, 1)                OFF  6A(rev1, 0), 03(0)
//   gen4 ON   03(1), 3F(1), 6A(1), 6B(rev1, 1)
//   gen4 OFF  not pinned here: in the foreground gen4's own `foreground` owner
//             keeps HR + bundle on after the developer owner lets go (open
//             question in the report).
// No opcode in `dangerousCmds` (or OpcodeSafety.isDestructive) is ever sent.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/g6_support.dart';

const _hr = Cmd.toggleRealtimeHr;
const _imu = Cmd.toggleImuMode;
const _r10 = Cmd.sendR10R11Realtime;
const _opt = Cmd.enableOpticalData;

void _noDangerous(G6Rig rig) {
  for (final op in rig.opcodes) {
    expect(dangerousCmds, isNot(contains(op)), reason: 'opcode $op');
    expect(OpcodeSafety.isDestructive(op), isFalse, reason: 'opcode $op');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  group('gen5 / MG', () {
    test('a connected MG writes nothing until the feed is started', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await rig.engine.reconcileLiveStreams();
      expect(rig.writes, isEmpty);
      expect(rig.engine.liveEnabled, isFalse);
    });

    test('Start arms realtime HR then the IMU stream, nothing else', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await startFeed(rig.app);
      await rig.settle();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
      expect(feedOn(rig.app), isTrue);
      expect(developerOwnerSet(rig.app), isTrue);
      expect(rig.engine.liveEnabled, isTrue);
      _noDangerous(rig);
    });

    test('Stop turns both streams off and clears the flag', () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await startFeed(rig.app);
      await rig.settle();
      rig.writes.clear();
      await stopFeed(rig.app);
      await rig.settle();
      expect(rig.ops, [(_imu, 0), (_hr, 0)]);
      expect(feedOn(rig.app), isFalse);
      expect(developerOwnerSet(rig.app), isFalse);
      expect(rig.engine.liveEnabled, isFalse);
      _noDangerous(rig);
    });

    test('Start twice is one arming; Stop without Start writes nothing',
        () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await stopFeed(rig.app);
      await rig.settle();
      expect(rig.writes, isEmpty);
      await startFeed(rig.app);
      await startFeed(rig.app);
      await rig.settle();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
    });

    test('a write that returns false cannot leave the flag set after Stop',
        () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await startFeed(rig.app);
      await rig.settle();
      rig.failing.addAll([_imu, _hr]);
      await stopFeed(rig.app);
      await rig.settle();
      expect(feedOn(rig.app), isFalse);
      expect(developerOwnerSet(rig.app), isFalse,
          reason: 'the owner is cleared whether or not the band acked');
    });

    test('a write that THROWS cannot leave the flag set, and Stop completes',
        () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await startFeed(rig.app);
      await rig.settle();
      rig.throwing.addAll([_imu, _hr]);
      await stopFeed(rig.app); // must not throw
      await rig.settle();
      expect(feedOn(rig.app), isFalse);
      expect(developerOwnerSet(rig.app), isFalse);
    });

    test('a Start whose write throws still leaves Stop able to clear the flag',
        () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.throwing.add(_imu);
      await startFeed(rig.app); // must not throw
      await rig.settle();
      await stopFeed(rig.app);
      await rig.settle();
      expect(feedOn(rig.app), isFalse);
      expect(developerOwnerSet(rig.app), isFalse);
    });

    test('Start clears the sticky radio fallback so IMU is not silently dropped',
        () async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      rig.engine.state.standardHrFallback = true;
      await startFeed(rig.app);
      await rig.settle();
      expect(rig.engine.state.standardHrFallback, isFalse);
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
    });
  });

  group('gen4', () {
    test('a connected 4.0 writes nothing until the feed is started', () async {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      expect(rig.writes, isEmpty);
    });

    test('Start sends the gen4 bundle in the established order', () async {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      await startFeed(rig.app);
      await rig.settle();
      expect(rig.ops, [(_hr, 1), (_r10, 1), (_imu, 1), (_opt, 1)]);
      expect(feedOn(rig.app), isTrue);
      _noDangerous(rig);
    });

    test('Stop clears the flag even when the band refuses the writes',
        () async {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      await startFeed(rig.app);
      await rig.settle();
      rig.failing.addAll([_hr, _r10, _imu, _opt, Cmd.toggleOpticalMode]);
      await stopFeed(rig.app);
      await rig.settle();
      expect(feedOn(rig.app), isFalse);
      expect(developerOwnerSet(rig.app), isFalse);
      _noDangerous(rig);
    });

    test('Start clears the sticky radio fallback', () async {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      rig.engine.state.standardHrFallback = true;
      await startFeed(rig.app);
      await rig.settle();
      expect(rig.engine.state.standardHrFallback, isFalse);
      expect(rig.ops, [(_hr, 1), (_r10, 1), (_imu, 1), (_opt, 1)]);
    });
  });
}
