// The Device lab's IMU recorder: armed by the wearer, started by the next live
// double tap, bounded in time and packets, and always letting go of the IMU
// stream (the `imuLab` owner) however it ends. It keeps its capture in RAM; it
// has no file to write.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_recorder.dart';
import 'package:openstrap_edge/gestures/imu_recording.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

import 'support/imu_recording_fixtures.dart';

const _tapSec = 1790000000;

StrapEvent _tap({
  int eventId = 14,
  int? ageMs = 90,
  bool stale = false,
  int sub = 0,
}) {
  final received = DateTime.fromMillisecondsSinceEpoch(
      _tapSec * 1000 + (stale ? 20000 : (ageMs ?? 0)),
      isUtc: true);
  return StrapEvent(
    eventId: eventId,
    tsEpoch: ageMs == null ? 0 : _tapSec,
    tsSubsec: sub,
    receivedAt: received,
    hex: '',
    deviceId: 'band-a',
  );
}

class _Rig {
  _Rig({
    this.connected = true,
    int maxPackets = 600,
    Duration startTimeout = const Duration(seconds: 10),
    this.onOwner,
  }) {
    recorder = ImuLabRecorder(
      packets: packets.stream,
      setStreamOwner: (held) {
        owner.add(held);
        onOwner?.call(held);
      },
      monotonicNow: () => mono,
      isConnected: () => connected,
      context: () => const ImuLabContext(
        bandModel: 'WHOOP MG',
        bandFirmware: '50.41.1.0',
        deviceId: 'band-a',
        appVersion: '0.10.0+67',
        protocolVersion: 'bc7d8d0',
      ),
      lab: lab,
      newId: () => 'imu-test-1',
      maxPackets: maxPackets,
      startTimeout: startTimeout,
    );
  }

  final packets = StreamController<ImuPacket>.broadcast(sync: true);
  final lab = DeviceLabLog();
  final owner = <bool>[];
  final void Function(bool held)? onOwner;
  bool connected;
  Duration mono = Duration.zero;
  late final ImuLabRecorder recorder;

  bool get held => owner.isNotEmpty && owner.last;

  void arm({
    ImuRecordingKind kind = ImuRecordingKind.action,
    Duration? duration,
  }) =>
      recorder.arm(ImuLabSetup(
        kind: kind,
        label: 'rotate out',
        wrist: ImuWrist.left,
        mounting: 'logo to elbow',
        posture: 'sitting',
        environment: 'car',
        duration: duration ?? const Duration(seconds: 5),
      ));

  void packet(int ms, {int gen = 1, String device = 'band-a'}) {
    mono = Duration(milliseconds: ms);
    packets.add(labPacket(ms, generation: gen, deviceId: device));
  }
}

void main() {
  test('default durations: 5 s for an action, 30 s for an ambient baseline', () {
    expect(ImuLabSetup.defaultDuration(ImuRecordingKind.action),
        const Duration(seconds: 5));
    expect(ImuLabSetup.defaultDuration(ImuRecordingKind.ambient),
        const Duration(seconds: 30));
    expect(ImuLabSetup.defaultDuration(ImuRecordingKind.unintendedTap),
        const Duration(seconds: 5));
  });

  group('arming', () {
    test('needs a connected band', () {
      final r = _Rig(connected: false)..arm();
      expect(r.recorder.phase, ImuLabPhase.idle);
      expect(r.recorder.note, contains('Connect the band'));
      expect(r.recorder.holdsActions, isFalse);
      expect(r.owner, isEmpty);
    });

    test('arming waits for a tap: no stream is requested, actions are held', () {
      final r = _Rig()..arm();
      expect(r.recorder.phase, ImuLabPhase.armed);
      expect(r.recorder.holdsActions, isTrue,
          reason: 'normal tap actions are suspended while a lab recording is armed');
      expect(r.owner, isEmpty, reason: 'the owner is not touched until the tap');
      r.packet(100);
      expect(r.recorder.phase, ImuLabPhase.armed,
          reason: 'packets another owner caused do not start a recording');
      expect(r.recorder.recording, isNull);
    });

    test('a duration beyond the limit is clamped; a non-positive one refused',
        () {
      final r = _Rig();
      r.arm(duration: const Duration(minutes: 30));
      expect(r.recorder.setup!.duration, ImuLabRecorder.maxDuration);
      r.recorder.cancel();
      r.arm(duration: Duration.zero);
      expect(r.recorder.phase, ImuLabPhase.idle);
      expect(r.recorder.note, isNotNull);
    });

    test('cannot arm over a recording in progress', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.arm(kind: ImuRecordingKind.ambient);
        expect(r.recorder.setup!.kind, ImuRecordingKind.action);
        expect(r.recorder.phase, ImuLabPhase.starting);
      });
    });

    test('arming over a review replaces it', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(500);
        r.recorder.stop();
        expect(r.recorder.phase, ImuLabPhase.review);
        r.arm();
        expect(r.recorder.phase, ImuLabPhase.armed);
        expect(r.recorder.recording, isNull);
      });
    });
  });

  group('starting', () {
    test('only a live double tap begins it', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap(eventId: 7));
        expect(r.recorder.phase, ImuLabPhase.armed, reason: 'not a double tap');
        r.recorder.onBandEvent(_tap(stale: true));
        expect(r.recorder.phase, ImuLabPhase.armed,
            reason: 'a late tap, drained from the band, is not the cue');
        expect(r.owner, isEmpty);
        r.recorder.onBandEvent(_tap());
        expect(r.recorder.phase, ImuLabPhase.starting);
        expect(r.owner, [true]);
      });
    });

    test('a tap with no armed recorder does nothing', () {
      final r = _Rig();
      r.recorder.onBandEvent(_tap());
      expect(r.recorder.phase, ImuLabPhase.idle);
      expect(r.owner, isEmpty);
    });

    test('subscribes before it asks for the stream, so the first packet is kept',
        () {
      fakeAsync((_) {
        late final _Rig r;
        r = _Rig(onOwner: (held) {
          if (held) r.packet(40); // arrives at once, inside the request
        });
        r.arm();
        r.mono = const Duration(milliseconds: 5);
        r.recorder.onBandEvent(_tap());
        expect(r.recorder.phase, ImuLabPhase.recording);
        expect(r.recorder.packetCount, 1);
      });
    });

    test('markers: tap received (with the band event age), stream requested',
        () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.mono = const Duration(milliseconds: 250);
        r.recorder.onBandEvent(_tap(ageMs: 90));
        r.packet(900);
        r.recorder.stop();
        final m = r.recorder.recording!.markers;
        expect(m.map((e) => e.kind), [
          ImuMarkerKind.tapReceived,
          ImuMarkerKind.streamRequested,
          ImuMarkerKind.firstPacket,
        ]);
        expect(m[0].mono, const Duration(milliseconds: 250));
        expect(m[0].bandEventAge, const Duration(milliseconds: 90));
        expect(m[0].at.isUtc, isTrue);
        expect(m[2].mono, const Duration(milliseconds: 900));
      });
    });

    test('a tap whose band clock cannot be believed carries no event age', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap(ageMs: null));
        r.recorder.stop();
        expect(r.recorder.recording!.markers.first.bandEventAge, isNull);
      });
    });

    test('startup timing goes to the lab log; an unknown event age is not 0',
        () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.mono = const Duration(milliseconds: 100);
        r.recorder.onBandEvent(_tap(ageMs: 90));
        r.packet(400);
        for (var i = 1; i < 120; i++) {
          r.packet(400 + i * 10);
        }
        final text = r.lab.toPlainText();
        expect(text, contains('IMU timing: tap event age 90 ms'));
        expect(text, contains('IMU timing: first packet to usable samples'));

        final r2 = _Rig()..arm();
        r2.recorder.onBandEvent(_tap(ageMs: null));
        expect(r2.lab.toPlainText(), isNot(contains('tap event age')));
      });
    });

    test('opens a lab session that ends with the recording', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        expect(r.lab.isSessionActive, isTrue);
        r.packet(100);
        r.recorder.stop();
        expect(r.lab.isSessionActive, isFalse);
        expect(r.lab.sessionSummaries.first, contains('IMU recording'));
        expect(r.lab.sessionSummaries.first, contains('1 packet'));
      });
    });
  });

  group('recording', () {
    test('first packet moves to recording; ends after the duration from it', () {
      fakeAsync((fa) {
        final r = _Rig()..arm(duration: const Duration(seconds: 5));
        r.recorder.onBandEvent(_tap());
        expect(r.recorder.phase, ImuLabPhase.starting);
        fa.elapse(const Duration(seconds: 3)); // startup is not the recording
        r.packet(3000);
        expect(r.recorder.phase, ImuLabPhase.recording);
        fa.elapse(const Duration(milliseconds: 4900));
        expect(r.recorder.phase, ImuLabPhase.recording);
        fa.elapse(const Duration(milliseconds: 200));
        expect(r.recorder.phase, ImuLabPhase.review);
        expect(r.recorder.recording!.status, ImuRecordingStatus.completed);
        expect(r.held, isFalse);
        expect(r.owner, [true, false]);
      });
    });

    test('keeps packets as received, with the metadata the wearer gave', () {
      fakeAsync((fa) {
        final r = _Rig()..arm(duration: const Duration(seconds: 1));
        r.recorder.onBandEvent(_tap());
        r.packet(200);
        r.packet(1200);
        fa.elapse(const Duration(seconds: 2));
        final rec = r.recorder.recording!;
        expect(rec.packetCount, 2);
        expectSamePacket(labPacket(200), rec.packets[0]);
        final m = rec.meta;
        expect(m.id, 'imu-test-1');
        expect(m.kind, ImuRecordingKind.action);
        expect(m.label, 'rotate out');
        expect(m.wrist, ImuWrist.left);
        expect(m.mounting, 'logo to elbow');
        expect(m.posture, 'sitting');
        expect(m.environment, 'car');
        expect(m.bandModel, 'WHOOP MG');
        expect(m.bandFirmware, '50.41.1.0');
        expect(m.deviceId, 'band-a');
        expect(m.appVersion, '0.10.0+67');
        expect(m.protocolVersion, 'bc7d8d0');
        expect(m.createdAt.isUtc, isTrue);
        expect(m.requestedDuration, const Duration(seconds: 1));
      });
    });

    test('unequal gen5 counts are kept, not aligned', () {
      fakeAsync((fa) {
        final r = _Rig()..arm(duration: const Duration(seconds: 1));
        r.recorder.onBandEvent(_tap());
        r.packets.add(labPacket(100, accel: 3, gyro: 2));
        fa.elapse(const Duration(seconds: 2));
        final p = r.recorder.recording!.packets.single;
        expect([p.accelSampleCount, p.gyroSampleCount], [3, 2]);
        expect([p.accelSamples.length, p.gyroSamples.length], [3, 2]);
      });
    });

    test('bounded by packets: stops at the limit and says so', () {
      fakeAsync((_) {
        final r = _Rig(maxPackets: 3)..arm(duration: const Duration(seconds: 30));
        r.recorder.onBandEvent(_tap());
        for (var i = 1; i <= 5; i++) {
          r.packet(i * 100);
        }
        expect(r.recorder.phase, ImuLabPhase.review);
        final rec = r.recorder.recording!;
        expect(rec.packetCount, 3);
        expect(rec.status, ImuRecordingStatus.packetLimit);
        expect(r.held, isFalse);
      });
    });

    test('stream never starts: times out with the tap marker and no packets', () {
      fakeAsync((fa) {
        final r = _Rig(startTimeout: const Duration(seconds: 4))..arm();
        r.recorder.onBandEvent(_tap());
        fa.elapse(const Duration(seconds: 3));
        expect(r.recorder.phase, ImuLabPhase.starting);
        fa.elapse(const Duration(seconds: 2));
        expect(r.recorder.phase, ImuLabPhase.review);
        final rec = r.recorder.recording!;
        expect(rec.status, ImuRecordingStatus.streamTimeout);
        expect(rec.packetCount, 0);
        expect(rec.markers.map((m) => m.kind),
            [ImuMarkerKind.tapReceived, ImuMarkerKind.streamRequested]);
        expect(r.held, isFalse);
        expect(r.recorder.holdsActions, isFalse);
      });
    });

    test('Stop ends it early as a partial recording', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        r.recorder.stop();
        expect(r.recorder.phase, ImuLabPhase.review);
        expect(r.recorder.recording!.status, ImuRecordingStatus.stopped);
        expect(r.recorder.recording!.isComplete, isFalse);
        expect(r.owner, [true, false]);
      });
    });

    test('packets after it ended, and other bands\' packets, are not added', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        r.packet(150, device: 'band-b');
        expect(r.recorder.packetCount, 1);
        r.recorder.stop();
        r.packet(200);
        expect(r.recorder.recording!.packetCount, 1);
      });
    });

    test('later taps during the recording are markers; they do not restart it',
        () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        r.mono = const Duration(milliseconds: 700);
        r.recorder.onBandEvent(_tap(sub: 200));
        r.recorder.stop();
        final taps = r.recorder.recording!.markers
            .where((m) => m.kind == ImuMarkerKind.tapReceived)
            .toList();
        expect(taps, hasLength(2));
        expect(taps[1].mono, const Duration(milliseconds: 700));
        expect(r.owner, [true, false], reason: 'one request, one release');
      });
    });

    test('the wearer\'s motion start and end are markers; an open one is kept '
        'open', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        r.mono = const Duration(milliseconds: 300);
        r.recorder.markMotionEnd(); // nothing open: ignored
        r.recorder.markMotionStart();
        expect(r.recorder.motionOpen, isTrue);
        r.mono = const Duration(milliseconds: 400);
        r.recorder.markMotionStart(); // already open: ignored
        r.mono = const Duration(milliseconds: 800);
        r.recorder.markMotionEnd();
        expect(r.recorder.motionOpen, isFalse);
        r.recorder.markMotionStart();
        r.recorder.stop();
        final rec = r.recorder.recording!;
        final kinds = rec.markers.map((m) => m.kind).toList();
        expect(kinds.where((k) => k == ImuMarkerKind.motionStart), hasLength(2));
        expect(kinds.where((k) => k == ImuMarkerKind.motionEnd), hasLength(1));
        expect(rec.motionLeftOpen, isTrue);
      });
    });

    test('motion marks and cues outside a capture are ignored', () {
      final r = _Rig()..arm();
      r.recorder.markMotionStart();
      r.recorder.addCue('start cue');
      expect(r.recorder.motionOpen, isFalse);
      r.recorder.onBandEvent(_tap());
      fakeAsync((_) {
        r.recorder.addCue('start cue');
        r.recorder.stop();
        expect(
            r.recorder.recording!.markers
                .where((m) => m.kind == ImuMarkerKind.cue)
                .single
                .note,
            'start cue');
      });
    });

    test('status reads: packets so far and time since the first packet', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        expect(r.recorder.elapsed, Duration.zero);
        r.packet(1000);
        r.packet(3500);
        expect(r.recorder.packetCount, 2);
        expect(r.recorder.elapsed, const Duration(milliseconds: 2500));
      });
    });
  });

  group('letting go of the stream', () {
    test('cancel while armed: nothing was held, back to idle', () {
      final r = _Rig()..arm();
      r.recorder.cancel();
      expect(r.recorder.phase, ImuLabPhase.idle);
      expect(r.recorder.holdsActions, isFalse);
      expect(r.owner, isEmpty);
    });

    test('cancel while starting or recording: released, nothing kept', () {
      fakeAsync((fa) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.recorder.cancel();
        expect(r.recorder.phase, ImuLabPhase.idle);
        expect(r.recorder.recording, isNull);
        expect(r.owner, [true, false]);
        expect(r.lab.isSessionActive, isFalse);
        expect(fa.pendingTimers, isEmpty);

        final r2 = _Rig()..arm();
        r2.recorder.onBandEvent(_tap());
        r2.packet(100);
        r2.recorder.cancel();
        expect(r2.recorder.recording, isNull);
        expect(r2.owner, [true, false]);
        expect(fa.pendingTimers, isEmpty);
      });
    });

    test('dispose while recording: released, timers gone, no later notification',
        () {
      fakeAsync((fa) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        var notified = 0;
        r.recorder.addListener(() => notified++);
        r.recorder.dispose();
        expect(r.owner, [true, false]);
        expect(r.recorder.holdsActions, isFalse);
        expect(fa.pendingTimers, isEmpty);
        expect(notified, 0);
        expect(() => r.packet(200), returnsNormally);
        fa.elapse(const Duration(minutes: 5));
        expect(notified, 0);
      });
    });

    test('dispose while armed or idle is harmless', () {
      final r = _Rig()..arm();
      r.recorder.dispose();
      expect(r.owner, isEmpty);
      final r2 = _Rig();
      expect(r2.recorder.dispose, returnsNormally);
    });

    test('disconnect while armed: back to idle with a reason', () {
      final r = _Rig()..arm();
      r.recorder.onDisconnected();
      expect(r.recorder.phase, ImuLabPhase.idle);
      expect(r.recorder.holdsActions, isFalse);
      expect(r.recorder.note, contains('disconnected'));
    });

    test('disconnect while recording: released, the partial capture is kept '
        'and labelled', () {
      fakeAsync((fa) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        r.packet(200);
        r.recorder.onDisconnected();
        expect(r.recorder.phase, ImuLabPhase.review);
        expect(r.recorder.recording!.status, ImuRecordingStatus.disconnected);
        expect(r.recorder.recording!.packetCount, 2);
        expect(r.owner, [true, false]);
        expect(fa.pendingTimers, isEmpty);
      });
    });

    test('a packet from a new connection generation ends it as disconnected',
        () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100, gen: 1);
        r.packet(200, gen: 2);
        expect(r.recorder.phase, ImuLabPhase.review);
        final rec = r.recorder.recording!;
        expect(rec.status, ImuRecordingStatus.disconnected);
        expect(rec.packetCount, 1, reason: 'the new link\'s packet is not added');
        expect(r.held, isFalse);
      });
    });

    test('disconnect while idle or in review changes nothing', () {
      fakeAsync((_) {
        final r = _Rig();
        r.recorder.onDisconnected();
        expect(r.recorder.phase, ImuLabPhase.idle);
        r.arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        r.recorder.stop();
        r.recorder.onDisconnected();
        expect(r.recorder.recording!.status, ImuRecordingStatus.stopped);
      });
    });

    test('a failing owner call cannot leave the recorder holding', () {
      fakeAsync((_) {
        var calls = 0;
        final r = _Rig(onOwner: (held) {
          calls++;
          if (!held) throw StateError('engine gone');
        })
          ..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        expect(() => r.recorder.stop(), returnsNormally);
        expect(r.recorder.phase, ImuLabPhase.review);
        expect(r.recorder.holdsActions, isFalse);
        expect(calls, 2);
      });
    });

    test('actions are held from Arm until the recording ends, however it ends',
        () {
      fakeAsync((fa) {
        for (final end in <void Function(_Rig)>[
          (r) => r.recorder.stop(),
          (r) => r.recorder.cancel(),
          (r) => r.recorder.onDisconnected(),
          (r) => r.recorder.dispose(),
          (r) => fa.elapse(const Duration(minutes: 1)),
        ]) {
          final r = _Rig()..arm();
          expect(r.recorder.holdsActions, isTrue);
          r.recorder.onBandEvent(_tap());
          expect(r.recorder.holdsActions, isTrue);
          r.packet(100);
          expect(r.recorder.holdsActions, isTrue);
          end(r);
          expect(r.recorder.holdsActions, isFalse);
          expect(r.held, isFalse);
        }
      });
    });
  });

  group('review', () {
    test('discard drops the capture and returns to idle', () {
      fakeAsync((_) {
        final r = _Rig()..arm();
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        r.recorder.stop();
        r.recorder.discard();
        expect(r.recorder.phase, ImuLabPhase.idle);
        expect(r.recorder.recording, isNull);
      });
    });

    test('listeners hear every change', () {
      fakeAsync((_) {
        final r = _Rig();
        var n = 0;
        r.recorder.addListener(() => n++);
        r.arm();
        final afterArm = n;
        expect(afterArm, greaterThan(0));
        r.recorder.onBandEvent(_tap());
        r.packet(100);
        r.recorder.stop();
        expect(n, greaterThan(afterArm + 2));
      });
    });
  });
}
