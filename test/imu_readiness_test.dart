// The gyro-ready detector: the stream is ready on the first packet with a
// valid gyro sample and accel present. The band's first four gyro samples of a
// stream read -2000 dps on all three axes (raw -32768, the invalid marker);
// those and NaN are not motion data. Pure Dart: times come from the packets
// and from poll(), never a clock.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_readiness.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

const _invalid = ImuVector(-2000, -2000, -2000);
const _ok = ImuVector(1.5, -0.5, 0.25);
const _accel = ImuVector(0, 0, 1);

ImuPacket _pkt(
  int ms, {
  List<ImuVector>? gyro,
  List<ImuVector>? accel,
  int generation = 1,
}) {
  final g = gyro ?? [_ok, _ok, _ok];
  final a = accel ?? [_accel, _accel, _accel];
  return ImuPacket(
    deviceId: 'band-a',
    connectionGeneration: generation,
    kind: ImuPacketKind.gen5R21,
    recordIndex: ms,
    deviceUnixSeconds: 1790000000,
    deviceSubseconds: 0,
    receivedAt: DateTime.utc(2026, 10, 6).add(Duration(milliseconds: ms)),
    monotonicReceipt: Duration(milliseconds: ms),
    accelSamples: a,
    gyroSamples: g,
    accelSampleCount: a.length,
    gyroSampleCount: g.length,
    nominalSampleSpacing: const Duration(milliseconds: 10),
    quality: const ImuPacketQuality(),
  );
}

ImuReadiness _armed({Duration timeout = const Duration(seconds: 10)}) =>
    ImuReadiness(timeout: timeout)..begin(Duration.zero);

void main() {
  group('what counts as a valid gyro sample', () {
    test('the -2000 triple is the invalid marker; a lone rail axis is not', () {
      expect(isValidGyroSample(_invalid), isFalse);
      expect(isValidGyroSample(const ImuVector(-2000, 0, 0)), isTrue,
          reason: 'one pinned axis is a clipped real sample, not the marker');
      expect(isValidGyroSample(const ImuVector(2000, 2000, 2000)), isTrue);
      expect(isValidGyroSample(_ok), isTrue);
    });

    test('NaN and infinity are not valid', () {
      expect(isValidGyroSample(const ImuVector(double.nan, 0, 0)), isFalse);
      expect(isValidGyroSample(const ImuVector(0, double.infinity, 0)), isFalse);
    });
  });

  group('turning ready', () {
    test('idle until begun: a packet before begin() is ignored', () {
      final r = ImuReadiness();
      expect(r.state, ImuReadyState.idle);
      expect(r.packet(_pkt(100)), isFalse);
      expect(r.isReady, isFalse);
    });

    test('a packet whose first four gyro samples are invalid is ready, and '
        'says it skipped four', () {
      final r = _armed();
      final turned = r.packet(_pkt(1800, gyro: [
        _invalid, _invalid, _invalid, _invalid, _ok, _ok,
      ]));
      expect(turned, isTrue);
      expect(r.state, ImuReadyState.ready);
      expect(r.readyAt, const Duration(milliseconds: 1800));
      expect(r.skippedSamples, 4);
      expect(r.reason, isNull);
    });

    test('invalid-first packets: a packet of nothing but the marker is not '
        'ready; the next valid packet is, and the skips add up', () {
      final r = _armed();
      expect(r.packet(_pkt(1300, gyro: [_invalid, _invalid, _invalid])), isFalse);
      expect(r.state, ImuReadyState.waiting);
      expect(r.skippedSamples, 3);
      expect(r.packet(_pkt(2300, gyro: [_invalid, _ok])), isTrue);
      expect(r.readyAt, const Duration(milliseconds: 2300));
      expect(r.skippedSamples, 4);
    });

    test('all-invalid packets never make it ready', () {
      final r = _armed();
      for (var i = 1; i <= 5; i++) {
        expect(r.packet(_pkt(i * 1000, gyro: [_invalid, _invalid])), isFalse);
      }
      expect(r.isReady, isFalse);
      expect(r.skippedSamples, 10);
      expect(r.reason, contains('10'));
    });

    test('a NaN gyro sample is skipped, not taken as motion', () {
      final r = _armed();
      expect(
          r.packet(_pkt(1000,
              gyro: [const ImuVector(double.nan, 1, 1), _invalid])),
          isFalse);
      expect(r.skippedSamples, 2);
      expect(r.packet(_pkt(2000, gyro: [const ImuVector(0, double.nan, 0), _ok])),
          isTrue);
      expect(r.skippedSamples, 3);
    });

    test('no gyro in the packet: not ready, and nothing counted as skipped', () {
      final r = _armed();
      expect(r.packet(_pkt(1000, gyro: const [])), isFalse);
      expect(r.state, ImuReadyState.waiting);
      expect(r.skippedSamples, 0);
    });

    test('valid gyro but no accel: not ready yet', () {
      final r = _armed();
      expect(r.packet(_pkt(1000, accel: const [])), isFalse);
      expect(r.isReady, isFalse);
      expect(r.packet(_pkt(2000)), isTrue);
    });

    test('turns ready exactly once; later packets change nothing', () {
      final r = _armed();
      expect(r.packet(_pkt(1000)), isTrue);
      expect(r.packet(_pkt(2000)), isFalse);
      expect(r.readyAt, const Duration(milliseconds: 1000));
      expect(r.skippedSamples, 0);
    });
  });

  group('timeout', () {
    test('no packet by the deadline: timed out, with a reason that says so',
        () {
      final r = _armed(timeout: const Duration(seconds: 4));
      expect(r.poll(const Duration(seconds: 3)), isFalse);
      expect(r.state, ImuReadyState.waiting);
      expect(r.poll(const Duration(seconds: 4)), isTrue);
      expect(r.state, ImuReadyState.timedOut);
      expect(r.isReady, isFalse);
      expect(r.reason, contains('No motion data'));
      expect(r.poll(const Duration(seconds: 9)), isFalse,
          reason: 'it reports the change once');
    });

    test('only invalid data by the deadline: the reason names the invalid '
        'gyro, not a missing stream', () {
      final r = _armed(timeout: const Duration(seconds: 4));
      r.packet(_pkt(1000, gyro: [_invalid, _invalid]));
      r.poll(const Duration(seconds: 5));
      expect(r.state, ImuReadyState.timedOut);
      expect(r.reason, contains('gyro'));
      expect(r.reason, contains('invalid'));
      expect(r.reason, isNot(contains('No motion data')));
    });

    test('packets with no gyro at all say so', () {
      final r = _armed(timeout: const Duration(seconds: 4));
      r.packet(_pkt(1000, gyro: const []));
      r.poll(const Duration(seconds: 5));
      expect(r.reason, contains('no gyro'));
    });

    test('valid gyro without accel says so', () {
      final r = _armed(timeout: const Duration(seconds: 4));
      r.packet(_pkt(1000, accel: const []));
      r.poll(const Duration(seconds: 5));
      expect(r.reason, contains('acceleration'));
    });

    test('a valid packet that arrives after the deadline is not ready', () {
      final r = _armed(timeout: const Duration(seconds: 4));
      expect(r.packet(_pkt(4500)), isFalse);
      expect(r.state, ImuReadyState.timedOut);
    });

    test('a valid packet inside the deadline is ready; poll afterwards does '
        'not undo it', () {
      final r = _armed(timeout: const Duration(seconds: 4));
      expect(r.packet(_pkt(3900)), isTrue);
      expect(r.poll(const Duration(seconds: 30)), isFalse);
      expect(r.state, ImuReadyState.ready);
    });
  });

  group('connection generation', () {
    test('a new generation starts the detection over', () {
      final r = _armed();
      r.packet(_pkt(1000, gyro: [_invalid, _invalid], generation: 1));
      expect(r.skippedSamples, 2);
      expect(r.packet(_pkt(2000, generation: 2, gyro: [_invalid, _ok])), isTrue);
      expect(r.generation, 2);
      expect(r.skippedSamples, 1, reason: 'the old link\'s skips do not carry');
    });

    test('ready on one link is not ready on the next: it waits again and '
        'turns ready again', () {
      final r = _armed();
      expect(r.packet(_pkt(1000, generation: 1)), isTrue);
      expect(
          r.packet(_pkt(5000, generation: 2, gyro: [_invalid, _invalid])), isFalse);
      expect(r.state, ImuReadyState.waiting);
      expect(r.readyAt, isNull);
      expect(r.packet(_pkt(6000, generation: 2)), isTrue);
      expect(r.readyAt, const Duration(milliseconds: 6000));
    });

    test('begin() forgets everything', () {
      final r = _armed();
      r.packet(_pkt(1000));
      r.begin(const Duration(seconds: 20));
      expect(r.state, ImuReadyState.waiting);
      expect(r.readyAt, isNull);
      expect(r.skippedSamples, 0);
      expect(r.generation, isNull);
      expect(r.packet(_pkt(21000)), isTrue);
    });
  });
}
