// What AppState does so a sweep has a real motion source: it holds the IMU
// live owner next to HR for as long as the sweep runs, gives the accelerometer
// samples of the live IMU frames to the sweep's StillnessMeter on the sweep's
// session clock, and lets go of both on every way out. RAM only (AGENTS.md
// 3.14): nothing is written anywhere.
//
// Accel arrives only in the IMU frames: gen5 0x2B rec 21 (100 Hz buffer), gen4
// 0x2B rec 10 (R10) and gen4 0x33 (10 samples a frame). All decode in g
// (1/4096 g per LSB); the sweep reuses the same decode as the pedometer and
// the Device lab recorder (ImuPacketAdapter / protocol frameAccel).
//
// ASSUMED NEW API (reached through a dynamic shim so one missing symbol fails
// one test, as support/live_stream_band_rig.dart does):
//   LiveStreamOwners.sweepMotion   the sweep's IMU owner (a NEW owner field;
//                                  not imuLab, which is the Device lab's, and
//                                  not movementSampling, which is the reminder)
//   ResonanceSweepController.sessionTime
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/explore/resonance/resonance_analyzer.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_controller.dart';
import 'package:openstrap_edge/state/imu_packet.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto
    show frameAccel;
import 'package:openstrap_protocol/openstrap_protocol.dart'
    show BandProfile, Cmd;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/app_state_live_harness.dart';
import 'support/sweep_fixtures.dart';

const _dbName = 'resonance_stillness_ram_only.db';
const _hr = Cmd.toggleRealtimeHr;
const _imu = Cmd.toggleImuMode;
const _ts0 = 1790000000;

bool sweepMotionOwner(G6Rig rig) =>
    ((rig.app.debugLiveOwners as dynamic).sweepMotion) as bool;

// ── frames ─────────────────────────────────────────────────────────────────

/// 0x28 compact HR with one beat, like the other sweep wiring tests.
void hrFrame(G6Rig rig, int i) => rig.app.debugOnLiveFrame(
    0x28,
    hexOf(hr28Inner(rr: [1000 + (i % 4) * 10], ts: _ts0 + i)),
    _ts0 + i);

/// Raw int16 for [g] on the x axis (1/4096 g per LSB).
int _lsb(double g) => (g * 4096).round();

/// 1 g on x, constant: the band at rest.
double still(int k) => 1.0;

/// 1.5 g / 0.5 g alternating: SD of the magnitude 0.5 g, far over any gate.
double shaken(int k) => k.isEven ? 1.5 : 0.5;

/// A gen5 live IMU frame (0x2B rec 21) whose 100 accel samples are
/// [mag] (g) on x and nothing on y and z.
void gen5Imu(G6Rig rig, int i, double Function(int k) mag) {
  final inner = r21LiveInner(ax: 0, ay: 0, az: 0, recordIndex: i + 1);
  final v = ByteData.sublistView(inner);
  for (var k = 0; k < 100; k++) {
    v.setInt16(20 + 2 * k, _lsb(mag(k)), Endian.little);
  }
  rig.app.debugOnLiveFrame(0x2B, hexOf(inner), null);
}

/// A gen4 R10 frame (0x2B rec 10). [ts] 0 is a band whose clock was never set.
void gen4R10(G6Rig rig, int i, double Function(int k) mag,
    {int? ts, bool beat = true}) {
  final inner = r10LiveInner(
      rr: beat ? [1000 + (i % 4) * 10] : const [], ax: 0, ts: ts ?? _ts0 + i);
  final v = ByteData.sublistView(inner);
  for (var k = 0; k < 100; k++) {
    v.setInt16(85 + 2 * k, _lsb(mag(k)), Endian.little);
  }
  rig.app.debugOnLiveFrame(0x2B, hexOf(inner), ts ?? _ts0 + i);
}

/// An accel-only gen4 R10 (0x2B rec 10): the first [length] bytes of a full
/// R10, cut after the accelerometer block. 685 bytes is the shortest protocol's
/// accel decode takes (X@85, Y@285, Z@485, 100 int16 each); the six-axis
/// decoder needs the gyro block (to byte 1288) and rejects it, so the sweep's
/// only way to see this frame's motion is the accel fallback. Beats are not
/// carried (they come from the 0x28 frames).
Uint8List accelOnlyR10Inner(int i, double Function(int k) mag,
    {int length = 700, int? ts}) {
  final full = r10LiveInner(rr: const [], ax: 0, ts: ts ?? _ts0 + i);
  final v = ByteData.sublistView(full);
  for (var k = 0; k < 100; k++) {
    v.setInt16(85 + 2 * k, _lsb(mag(k)), Endian.little);
  }
  return Uint8List.sublistView(full, 0, length);
}

void accelOnlyR10(G6Rig rig, int i, double Function(int k) mag,
    {int length = 700, int? ts}) {
  rig.app.debugOnLiveFrame(
      0x2B, hexOf(accelOnlyR10Inner(i, mag, length: length, ts: ts)),
      ts ?? _ts0 + i);
}

/// A gen4 0x33 IMU frame: 10 accel samples, [mag] (g) by sample index.
void gen4Imu33(G6Rig rig, int frame, double Function(int k) mag) {
  final inner = imu33Inner(ax: 0, ts: _ts0 + frame ~/ 10);
  final v = ByteData.sublistView(inner);
  for (var k = 0; k < 10; k++) {
    v.setInt16(24 + 2 * k, _lsb(mag(frame * 10 + k)), Endian.little);
  }
  rig.app.debugOnLiveFrame(0x33, hexOf(inner), _ts0 + frame ~/ 10);
}

// ── driving one 60 s block on a stepped clock ──────────────────────────────

typedef FeedSecond = void Function(int second, void Function(int ms) at);

class Run {
  Run(this.rig);
  final G6Rig rig;
  DateTime clock = DateTime.utc(2026, 10, 7, 12);
  late final DateTime start = clock;
  late final ResonanceSweepController c;

  void at(int ms) => clock = start.add(Duration(milliseconds: ms));
}

/// One 60 s block (no settle stretch, so every frame is in the measure
/// window). Second [i] of frames arrives at 500 + i * 1000 ms unless [feed]
/// moves the clock itself.
Future<Run> sweepOneBlock(
  G6Rig rig,
  FeedSecond feed, {
  bool stop = true,
  int seconds = 60,
  Future<void> Function()? afterStart,
}) async {
  rig.app.repo = LocalRepositoryImpl(getProfileMap: () => const {});
  final run = Run(rig);
  run.c = rig.app.buildResonanceSweep(
    plan: planFor([6.0],
        settle: Duration.zero, measure: const Duration(seconds: 60)),
    now: () => run.clock,
  );
  addTearDown(run.c.dispose);
  await run.c.start();
  await afterStart?.call();
  for (var i = 0; i < seconds; i++) {
    run.at(500 + i * 1000);
    feed(i, run.at);
  }
  run.at(61 * 1000);
  if (stop) await run.c.stop();
  return run;
}

BlockResult only(Run r) => r.c.result!.blocks.single;

/// The last HR / IMU write is not an ON: nothing is left running.
void expectNetOff(G6Rig rig) {
  for (final op in [_hr, _imu]) {
    final last = rig.ops.lastWhere((o) => o.$1 == op, orElse: () => (op, 0));
    expect(last.$2, 0, reason: 'opcode $op was left on: ${rig.ops}');
  }
}

Future<int> _totalChanges() async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery('SELECT total_changes() AS n');
  return (r.single['n'] as num).toInt();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = _dbName;
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), _dbName));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), _dbName));
  });

  Future<G6Rig> newRig({BandProfile band = BandProfile.gen5}) async {
    final rig = G6Rig(band: band);
    addTearDown(rig.dispose);
    return rig;
  }

  group('the IMU owner', () {
    test('gen5: a running sweep holds IMU next to HR, and Stop gives both '
        'back; the Device lab owner is never used', () async {
      final rig = await newRig();
      final c = rig.app.buildResonanceSweep(plan: planFor([6.0]));
      addTearDown(c.dispose);
      expect(rig.ops, isEmpty);

      await c.start();
      await rig.settle();
      expect(c.state, SweepState.running);
      expect(sweepMotionOwner(rig), isTrue);
      expect(rig.app.debugLiveOwners.breathing, isTrue);
      expect(rig.app.debugLiveOwners.imuLab, isFalse);
      expect(rig.app.debugLiveOwners.movementSampling, isFalse);
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);

      await c.stop();
      await rig.settle();
      expect(sweepMotionOwner(rig), isFalse);
      expect(rig.app.debugLiveOwners.breathing, isFalse);
      expect(rig.ops, [(_hr, 1), (_imu, 1), (_imu, 0), (_hr, 0)]);
    });

    test('gen4: the owner is held while running and released after',
        () async {
      final rig = await newRig(band: BandProfile.gen4);
      final c = rig.app.buildResonanceSweep(plan: planFor([6.0]));
      addTearDown(c.dispose);
      expect(sweepMotionOwner(rig), isFalse);
      await c.start();
      expect(sweepMotionOwner(rig), isTrue);
      await c.stop();
      expect(sweepMotionOwner(rig), isFalse);
    });

    test('without a band the sweep fails and never takes the owner',
        () async {
      final rig = await newRig();
      rig.engine.state.connection = 'disconnected';
      final c = rig.app.buildResonanceSweep(plan: planFor([6.0]));
      addTearDown(c.dispose);
      await c.start();
      await rig.settle();
      expect(c.state, SweepState.failed);
      expect(sweepMotionOwner(rig), isFalse);
      expect(rig.ops, isEmpty);
    });

    // Every way out hands both streams back (4.3: no latch left set).
    group('is released on every exit path', () {
      void check(
        String name,
        Future<void> Function(G6Rig rig) body, {
        bool imuWasOn = true,
      }) {
        test(name, () async {
          final rig = await newRig();
          await body(rig);
          await rig.settle();
          if (imuWasOn) {
            expect(rig.ops.contains((_imu, 1)), isTrue,
                reason: 'the sweep took IMU: ${rig.ops}');
          }
          expect(sweepMotionOwner(rig), isFalse);
          expect(rig.app.debugLiveOwners.breathing, isFalse);
          expectNetOff(rig);
        });
      }

      check('Stop mid-run', (rig) async {
        final c = rig.app.buildResonanceSweep(plan: planFor([6.0]));
        addTearDown(c.dispose);
        await c.start();
        await rig.settle();
        await c.stop();
      });

      check('the screen leaves mid-run (dispose)', (rig) async {
        final c = rig.app.buildResonanceSweep(plan: planFor([6.0]));
        await c.start();
        await rig.settle();
        c.dispose();
      });

      check('the screen leaves while the sweep is still starting', (rig) async {
        final c = rig.app.buildResonanceSweep(plan: planFor([6.0]));
        final starting = c.start();
        expect(sweepMotionOwner(rig), isTrue,
            reason: 'claimed as the acquisition begins');
        c.dispose();
        await starting;
      }, imuWasOn: false);

      check('the sweep runs to its end', (rig) async {
        rig.app.repo = LocalRepositoryImpl(getProfileMap: () => const {});
        var clock = DateTime.utc(2026, 10, 7, 12);
        final start = clock;
        final c = rig.app.buildResonanceSweep(
          plan: planFor([6.0]),
          now: () => clock,
        );
        addTearDown(c.dispose);
        await c.start();
        clock = start.add(const Duration(seconds: 151));
        c.tick();
        await pumpEventQueue();
        expect(c.state, SweepState.finished);
      });

      check('scoring fails at the end (the data store is not ready)',
          (rig) async {
        rig.app.repo = null;
        var clock = DateTime.utc(2026, 10, 7, 12);
        final start = clock;
        final c = rig.app.buildResonanceSweep(
          plan: planFor([6.0]),
          now: () => clock,
        );
        addTearDown(c.dispose);
        await c.start();
        clock = start.add(const Duration(seconds: 151));
        c.tick();
        await pumpEventQueue();
        expect(c.state, SweepState.failed);
      });

      check('the band refuses the IMU write, then Stop', (rig) async {
        rig.failing.add(_imu);
        final c = rig.app.buildResonanceSweep(plan: planFor([6.0]));
        addTearDown(c.dispose);
        await c.start();
        await rig.settle();
        expect(c.state, SweepState.running,
            reason: 'a refused IMU write does not fail the sweep');
        rig.failing.clear();
        await c.stop();
      });
    });
  });

  group('accel reaches the sweep and decides the blocks (gen5, 0x2B rec 21)',
      () {
    void second(G6Rig rig, int i, double Function(int k) mag) {
      hrFrame(rig, i);
      gen5Imu(rig, i, mag);
    }

    test('a still wrist: the block is scored, not abstained', () async {
      final rig = await newRig();
      final run = await sweepOneBlock(rig, (i, at) => second(rig, i, still));
      expect(only(run).rejection, isNull);
      expect(only(run).admitted, isTrue);
    });

    test('a shaken wrist: the block is rejected for movement', () async {
      final rig = await newRig();
      final run = await sweepOneBlock(rig, (i, at) => second(rig, i, shaken));
      expect(only(run).rejection, BlockRejection.movement);
      expect(run.c.result!.rateBpm, isNull);
    });

    test('a wrist that moved for a third of the window is movement, not still',
        () async {
      final rig = await newRig();
      final run = await sweepOneBlock(
          rig, (i, at) => second(rig, i, i % 3 == 0 ? shaken : still));
      expect(only(run).rejection, BlockRejection.movement);
    });

    test('no IMU frames at all: movementUnknown, never still', () async {
      final rig = await newRig();
      final run = await sweepOneBlock(rig, (i, at) => hrFrame(rig, i));
      expect(only(run).rejection, BlockRejection.movementUnknown);
    });

    test('IMU frames for only half the window: movementUnknown', () async {
      final rig = await newRig();
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        if (i < 30) gen5Imu(rig, i, still);
      });
      expect(only(run).rejection, BlockRejection.movementUnknown);
    });

    test('a short IMU frame (a partial buffer) does not stand in for a full '
        'second', () async {
      final rig = await newRig();
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        final inner = r21LiveInner(
            ax: 4096, ay: 0, az: 0, recordIndex: i + 1, accelCount: 20);
        rig.app.debugOnLiveFrame(0x2B, hexOf(inner), null);
      });
      expect(only(run).rejection, BlockRejection.movementUnknown,
          reason: '20 samples a second is under the minimum');
    });

    test('IMU frames that arrive while the sweep is not running are ignored',
        () async {
      final rig = await newRig();
      rig.app.repo = LocalRepositoryImpl(getProfileMap: () => const {});
      var clock = DateTime.utc(2026, 10, 7, 12);
      final start = clock;
      final c = rig.app.buildResonanceSweep(
        plan: planFor([6.0],
            settle: Duration.zero, measure: const Duration(seconds: 60)),
        now: () => clock,
      );
      addTearDown(c.dispose);
      // Shaken frames before the sweep starts: no session time yet.
      for (var i = 0; i < 60; i++) {
        gen5Imu(rig, i, shaken);
      }
      await c.start();
      for (var i = 0; i < 60; i++) {
        clock = start.add(Duration(milliseconds: 500 + i * 1000));
        hrFrame(rig, i);
        gen5Imu(rig, i, still);
      }
      clock = start.add(const Duration(seconds: 61));
      await c.stop();
      expect(c.result!.blocks.single.rejection, isNull,
          reason: 'the earlier shaking was never recorded');
    });

    test('a newer sweep takes the samples; an old one gets none', () async {
      final rig = await newRig();
      rig.app.repo = LocalRepositoryImpl(getProfileMap: () => const {});
      final old = rig.app.buildResonanceSweep(plan: planFor([6.0]));
      addTearDown(old.dispose);
      final run = await sweepOneBlock(rig, (i, at) => second(rig, i, still));
      expect(only(run).rejection, isNull);
      expect(old.state, SweepState.idle);
    });
  });

  group('gen4', () {
    test('0x33 IMU stream, 10 samples a frame: still is scored', () async {
      final rig = await newRig(band: BandProfile.gen4);
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        for (var f = 0; f < 10; f++) {
          at(i * 1000 + f * 100 + 50);
          gen4Imu33(rig, i * 10 + f, still);
        }
      });
      expect(only(run).rejection, isNull);
    });

    test('0x33 IMU stream: shaken is movement (raw LSBs read in g)',
        () async {
      final rig = await newRig(band: BandProfile.gen4);
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        for (var f = 0; f < 10; f++) {
          at(i * 1000 + f * 100 + 50);
          gen4Imu33(rig, i * 10 + f, shaken);
        }
      });
      expect(only(run).rejection, BlockRejection.movement);
    });

    test('R10 (0x2B rec 10) carries beats and accel in one frame', () async {
      final rig = await newRig(band: BandProfile.gen4);
      final still4 = await sweepOneBlock(
          rig, (i, at) => gen4R10(rig, i, still));
      expect(only(still4).rejection, isNull);

      final rig2 = await newRig(band: BandProfile.gen4);
      final shaken4 = await sweepOneBlock(
          rig2, (i, at) => gen4R10(rig2, i, shaken));
      expect(only(shaken4).rejection, BlockRejection.movement);
    });

    test('an R10 from a band whose clock was never set still counts: the '
        'samples are valid, the sweep stamps them on its own clock', () async {
      final rig = await newRig(band: BandProfile.gen4);
      // The beats come from 0x28 frames; the R10 frames carry accel only.
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        gen4R10(rig, i, still, ts: 0, beat: false);
      });
      expect(only(run).rejection, isNull);
    });
  });

  // The gen4 R10 fallback: a valid R10 shorter than the gyro block (685 to
  // 1287 bytes) carries 100 accel samples but no gyro, so the six-axis decoder
  // rejects it and `_safeFrameAccel` is the only reader. That path already
  // feeds the pedometer and the live graphs; the sweep's meter must take the
  // same frame, scaled to g the same way and stamped on the sweep's own clock.
  group('accel-only R10 (the fallback the six-axis decoder rejects)', () {
    test('fixture: protocol reads it, the six-axis adapter does not', () {
      for (final len in [685, 700, 1000, 1287]) {
        final inner = accelOnlyR10Inner(0, still, length: len);
        expect(proto.frameAccel(hexOf(inner)), isNotNull, reason: '$len B');
        expect(
            ImuPacketAdapter().decode(
                packetType: 0x2B,
                hex: hexOf(inner),
                deviceId: 'band',
                connectionGeneration: 1),
            isNull,
            reason: '$len B has no gyro block');
      }
    });

    test('a still sweep: the block is admitted, not movementUnknown',
        () async {
      final rig = await newRig(band: BandProfile.gen4);
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        accelOnlyR10(rig, i, still);
      });
      expect(only(run).rejection, isNull);
      expect(only(run).admitted, isTrue);
    });

    test('the shortest and the longest valid R10 both count', () async {
      for (final len in [685, 1287]) {
        final rig = await newRig(band: BandProfile.gen4);
        final run = await sweepOneBlock(rig, (i, at) {
          hrFrame(rig, i);
          accelOnlyR10(rig, i, still, length: len);
        });
        expect(only(run).rejection, isNull, reason: '$len B');
      }
    });

    test('a shaken wrist: the block is rejected for movement', () async {
      final rig = await newRig(band: BandProfile.gen4);
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        accelOnlyR10(rig, i, shaken);
      });
      expect(only(run).rejection, BlockRejection.movement);
      expect(run.c.result!.rateBpm, isNull);
    });

    test('a wrist that moved for a third of the window is movement, not still',
        () async {
      final rig = await newRig(band: BandProfile.gen4);
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        accelOnlyR10(rig, i, i % 3 == 0 ? shaken : still);
      });
      expect(only(run).rejection, BlockRejection.movement);
    });

    test('frames for only half the window: movementUnknown, never still',
        () async {
      final rig = await newRig(band: BandProfile.gen4);
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        if (i < 30) accelOnlyR10(rig, i, still);
      });
      expect(only(run).rejection, BlockRejection.movementUnknown);
    });

    test('frames that arrive while the sweep is not running are ignored',
        () async {
      final rig = await newRig(band: BandProfile.gen4);
      rig.app.repo = LocalRepositoryImpl(getProfileMap: () => const {});
      var clock = DateTime.utc(2026, 10, 7, 12);
      final start = clock;
      final c = rig.app.buildResonanceSweep(
        plan: planFor([6.0],
            settle: Duration.zero, measure: const Duration(seconds: 60)),
        now: () => clock,
      );
      addTearDown(c.dispose);
      for (var i = 0; i < 60; i++) {
        accelOnlyR10(rig, i, shaken);
      }
      await c.start();
      for (var i = 0; i < 60; i++) {
        clock = start.add(Duration(milliseconds: 500 + i * 1000));
        hrFrame(rig, i);
        accelOnlyR10(rig, i, still);
      }
      clock = start.add(const Duration(seconds: 61));
      await c.stop();
      expect(c.result!.blocks.single.rejection, isNull,
          reason: 'the earlier shaking was never recorded');
    });

    // The pedometer's once-only rule: with 0x33 flowing, 0x2B is not read
    // again, so the same motion is not counted from two stream formats.
    test('with the 0x33 stream flowing, the R10 is not read again: a still '
        '0x33 stands against a shaken R10', () async {
      final rig = await newRig(band: BandProfile.gen4);
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        for (var f = 0; f < 10; f++) {
          at(i * 1000 + f * 100 + 50);
          gen4Imu33(rig, i * 10 + f, still);
        }
        at(i * 1000 + 950);
        accelOnlyR10(rig, i, shaken);
      });
      expect(only(run).rejection, isNull,
          reason: 'a shaken R10 after 0x33 began must not reach the meter');
    });

    test('with the 0x33 stream flowing, a still R10 does not dilute a shaken '
        '0x33', () async {
      final rig = await newRig(band: BandProfile.gen4);
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        for (var f = 0; f < 10; f++) {
          at(i * 1000 + f * 100 + 50);
          gen4Imu33(rig, i * 10 + f, shaken);
        }
        at(i * 1000 + 950);
        accelOnlyR10(rig, i, still);
      });
      expect(only(run).rejection, BlockRejection.movement);
    });

    test('a sweep with an accel-only R10 flood writes no row (RAM only)',
        () async {
      final rig = await newRig(band: BandProfile.gen4);
      await LocalDb.instance;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = await _totalChanges();
      final run = await sweepOneBlock(rig, (i, at) {
        hrFrame(rig, i);
        accelOnlyR10(rig, i, still);
      });
      await rig.settle();
      expect(only(run).rejection, isNull,
          reason: 'the frames were read (else this proves nothing)');
      expect(await _totalChanges(), before,
          reason: 'no raw_records, decoded_*, raw_archive or settings row');
    });
  });

  // A family whose IMU stream cannot be enabled keeps abstaining: the sweep
  // neither fails, nor forces the radio, nor reads motion from anywhere else.
  group('a band whose IMU stream cannot be enabled stays movementUnknown', () {
    for (final gen5 in [true, false]) {
      final family = gen5 ? 'gen5' : 'gen4';
      final band = gen5 ? BandProfile.gen5 : BandProfile.gen4;

      test('$family: the marginal-radio fallback holds HR only; the sweep '
          'does not clear the fallback to get motion', () async {
        final rig = await newRig(band: band);
        rig.engine.state.standardHrFallback = true;
        final run = await sweepOneBlock(rig, (i, at) => hrFrame(rig, i),
            afterStart: () async {
          await rig.settle();
          expect(sweepMotionOwner(rig), isTrue,
              reason: 'the sweep asks for IMU; the radio fallback refuses it');
        });
        await rig.settle();
        expect(rig.ops.where((o) => o.$1 == _imu && o.$2 == 1), isEmpty,
            reason: 'no IMU ON while the radio is in fallback');
        expect(rig.engine.state.standardHrFallback, isTrue,
            reason: 'a sweep is not the user action that clears it');
        expect(run.c.state, SweepState.stopped);
        expect(only(run).rejection, BlockRejection.movementUnknown);
        expect(run.c.result!.rateBpm, isNull);
        expect(sweepMotionOwner(rig), isFalse);
      });

      test('$family: the band refuses the IMU write; the sweep still runs '
          'and abstains', () async {
        final rig = await newRig(band: band);
        rig.failing.add(_imu);
        final run = await sweepOneBlock(rig, (i, at) => hrFrame(rig, i),
            afterStart: () async {
          await rig.settle();
          expect(sweepMotionOwner(rig), isTrue);
          expect(rig.ops.contains((_imu, 1)), isTrue,
              reason: 'the IMU ON was attempted and the band refused it');
        });
        expect(run.c.state, SweepState.stopped);
        expect(only(run).rejection, BlockRejection.movementUnknown);
        expect(run.c.result!.rateBpm, isNull);
        expect(sweepMotionOwner(rig), isFalse);
      });

      test('$family: HR-only 0x28 frames carry no motion and are never '
          'read as still', () async {
        final rig = await newRig(band: band);
        final run = await sweepOneBlock(rig, (i, at) => hrFrame(rig, i));
        expect(only(run).rejection, BlockRejection.movementUnknown);
      });
    }
  });

  group('RAM only (AGENTS.md 3.14)', () {
    for (final gen5 in [true, false]) {
      test('a sweep with its IMU flood writes no row (${gen5 ? 'gen5' : 'gen4'})',
          () async {
        final rig = await newRig(
            band: gen5 ? BandProfile.gen5 : BandProfile.gen4);
        await LocalDb.instance;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final before = await _totalChanges();
        final run = await sweepOneBlock(rig, (i, at) {
          hrFrame(rig, i);
          if (gen5) {
            gen5Imu(rig, i, still);
          } else {
            gen4R10(rig, i, still);
          }
        });
        await rig.settle();
        expect(only(run).rejection, isNull);
        expect(await _totalChanges(), before,
            reason: 'no raw_records, decoded_*, raw_archive or settings row');
      });
    }
  });
}
