// The IMU lab recording file: versioned JSON Lines that reads back exactly what
// was written, keeps unequal gen5 sensor counts as they came, labels a partial
// recording, and refuses a file it cannot trust.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_recording.dart';
import 'package:openstrap_edge/state/imu_packet.dart';

import 'support/imu_recording_fixtures.dart';

ImuRecording _recording({
  ImuRecordingStatus status = ImuRecordingStatus.completed,
  ImuRecordingMeta? meta,
  List<ImuPacket>? packets,
  List<ImuMarker>? markers,
}) =>
    ImuRecording(
      meta: meta ?? labMeta(),
      status: status,
      packets: packets ??
          [
            labPacket(1000, accel: 100, gyro: 100),
            labPacket(2000, accel: 3, gyro: 2),
            labPacket(3000, accel: 1, gyro: 100, gap: true, clipped: true),
          ],
      markers: markers ??
          [
            labMarker(ImuMarkerKind.tapReceived, 100,
                age: const Duration(milliseconds: 87)),
            labMarker(ImuMarkerKind.streamRequested, 105),
            labMarker(ImuMarkerKind.firstPacket, 1000),
            labMarker(ImuMarkerKind.cue, 1500, note: 'start cue'),
            labMarker(ImuMarkerKind.motionStart, 1800),
            labMarker(ImuMarkerKind.motionEnd, 2600),
          ],
    );

void _expectSame(ImuRecording a, ImuRecording b) {
  expect(b.status, a.status);
  expect(b.meta.id, a.meta.id);
  expect(b.meta.kind, a.meta.kind);
  expect(b.meta.label, a.meta.label);
  expect(b.meta.bandModel, a.meta.bandModel);
  expect(b.meta.bandFirmware, a.meta.bandFirmware);
  expect(b.meta.deviceId, a.meta.deviceId);
  expect(b.meta.wrist, a.meta.wrist);
  expect(b.meta.mounting, a.meta.mounting);
  expect(b.meta.posture, a.meta.posture);
  expect(b.meta.environment, a.meta.environment);
  expect(b.meta.appVersion, a.meta.appVersion);
  expect(b.meta.protocolVersion, a.meta.protocolVersion);
  expect(b.meta.createdAt, a.meta.createdAt);
  expect(b.meta.requestedDuration, a.meta.requestedDuration);
  expect(b.meta.maxPackets, a.meta.maxPackets);
  expect(b.packets, hasLength(a.packets.length));
  for (var i = 0; i < a.packets.length; i++) {
    expectSamePacket(a.packets[i], b.packets[i]);
  }
  expect(b.markers, hasLength(a.markers.length));
  for (var i = 0; i < a.markers.length; i++) {
    expect(b.markers[i].kind, a.markers[i].kind);
    expect(b.markers[i].mono, a.markers[i].mono);
    expect(b.markers[i].at, a.markers[i].at);
    expect(b.markers[i].bandEventAge, a.markers[i].bandEventAge);
    expect(b.markers[i].note, a.markers[i].note);
  }
}

void main() {
  test('a recording reads back field for field, and re-encodes to the same text',
      () {
    final r = _recording();
    final text = r.toJsonLines();
    final back = ImuRecording.parse(text);
    _expectSame(r, back);
    expect(back.toJsonLines(), text);
  });

  test('unequal gen5 counts stay as sent: no aligned rows are invented', () {
    final back = ImuRecording.parse(_recording().toJsonLines());
    final p = back.packets[1];
    expect(p.accelSampleCount, 3);
    expect(p.gyroSampleCount, 2);
    expect(p.accelSamples, hasLength(3));
    expect(p.gyroSamples, hasLength(2));
    final line = const LineSplitter()
        .convert(_recording().toJsonLines())
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .where((o) => o['type'] == 'packet')
        .elementAt(1);
    expect((line['accel'] as List), hasLength(3));
    expect((line['gyro'] as List), hasLength(2));
    expect(line['accelCount'], 3);
    expect(line['gyroCount'], 2);
  });

  test('doubles survive exactly, including awkward fractions', () {
    final packet = ImuPacket(
      deviceId: 'band-a',
      connectionGeneration: 4,
      kind: ImuPacketKind.gen4R10,
      recordIndex: null,
      deviceUnixSeconds: null,
      deviceSubseconds: null,
      receivedAt: DateTime.utc(2026, 10, 5, 1, 2, 3, 4, 5),
      monotonicReceipt: const Duration(microseconds: 123456789),
      accelSamples: const [ImuVector(1 / 3, -2 / 7, 1e-12)],
      gyroSamples: const [ImuVector(-2000.0 / 32768, 1e9 + 0.1, 0)],
      accelSampleCount: 1,
      gyroSampleCount: 1,
      nominalSampleSpacing: const Duration(milliseconds: 10),
      quality: const ImuPacketQuality(),
    );
    final back = ImuRecording.parse(
        _recording(packets: [packet], markers: const []).toJsonLines());
    expectSamePacket(packet, back.packets.single);
    expect(back.packets.single.deviceUnixSeconds, isNull,
        reason: 'an unset device clock stays unset, not 0');
  });

  test('a partial recording keeps its status and is not complete', () {
    for (final s in ImuRecordingStatus.values) {
      final back = ImuRecording.parse(_recording(status: s).toJsonLines());
      expect(back.status, s);
      expect(back.isComplete, s == ImuRecordingStatus.completed);
    }
  });

  test('a recording with no packets or markers is still a valid file', () {
    final r = _recording(
        status: ImuRecordingStatus.streamTimeout,
        packets: const [],
        markers: [labMarker(ImuMarkerKind.tapReceived, 5)]);
    _expectSame(r, ImuRecording.parse(r.toJsonLines()));
  });

  test('metadata that is absent stays absent', () {
    final r = _recording(meta: labMeta(wrist: null, firmware: null));
    final back = ImuRecording.parse(r.toJsonLines());
    expect(back.meta.wrist, isNull);
    expect(back.meta.bandFirmware, isNull);
  });

  test('the header names the format and version; one line per packet and marker',
      () {
    final lines = const LineSplitter().convert(_recording().toJsonLines());
    final header = jsonDecode(lines.first) as Map<String, Object?>;
    expect(header['type'], 'header');
    expect(header['format'], 'openstrap-imu-recording');
    expect(header['version'], 1);
    expect(header['packetCount'], 3);
    expect(header['markerCount'], 6);
    expect(header['createdUtc'], '2026-10-05T12:00:00.123456Z');
    expect(lines, hasLength(1 + 3 + 6));
    for (final l in lines) {
      expect(() => jsonDecode(l), returnsNormally);
    }
  });

  test('markers and packets are interleaved in time order, marker first on a tie',
      () {
    final lines = const LineSplitter().convert(_recording().toJsonLines());
    final order = [
      for (final l in lines.skip(1))
        (jsonDecode(l) as Map<String, Object?>)['monoUs'] as int,
    ];
    expect(order, [...order]..sort());
    final types = [
      for (final l in lines.skip(1))
        '${(jsonDecode(l) as Map)['type']}:${(jsonDecode(l) as Map)['kind']}',
    ];
    expect(types.indexOf('marker:firstPacket'),
        lessThan(types.indexOf('packet:gen5R21')));
  });

  test('a packet from another device keeps its own id', () {
    final r = _recording(packets: [
      labPacket(1000),
      labPacket(2000, deviceId: 'band-b'),
    ]);
    final back = ImuRecording.parse(r.toJsonLines());
    expect(back.packets.map((p) => p.deviceId), ['band-a', 'band-b']);
  });

  group('refuses what it cannot trust', () {
    test('empty text, a stranger\'s JSON, and a later version', () {
      expect(() => ImuRecording.parse(''), throwsFormatException);
      expect(() => ImuRecording.parse('{"type":"header","format":"other"}'),
          throwsFormatException);
      final text = _recording().toJsonLines();
      final later = text.replaceFirst('"version":1', '"version":2');
      expect(() => ImuRecording.parse(later), throwsFormatException);
    });

    test('a file cut short', () {
      final lines = const LineSplitter().convert(_recording().toJsonLines());
      final cut = lines.take(lines.length - 2).join('\n');
      expect(() => ImuRecording.parse(cut), throwsFormatException);
    });

    test('a damaged line or a missing field is a FormatException, not a crash',
        () {
      final lines = const LineSplitter().convert(_recording().toJsonLines());
      final broken = [lines.first, '{not json', ...lines.skip(2)].join('\n');
      expect(() => ImuRecording.parse(broken), throwsFormatException);
      final noField = lines
          .map((l) => l.replaceFirst('"monoUs"', '"monoUsX"'))
          .join('\n');
      expect(() => ImuRecording.parse(noField), throwsFormatException);
    });
  });

  test('lines of a type this version does not know are skipped', () {
    final lines = const LineSplitter().convert(_recording().toJsonLines());
    final withExtra = [
      lines.first,
      '{"type":"annotation","text":"later version"}',
      ...lines.skip(1),
    ].join('\n');
    _expectSame(_recording(), ImuRecording.parse(withExtra));
  });

  group('review figures', () {
    test('span, startup, gaps, clipped and partial blocks', () {
      final r = _recording();
      expect(r.packetCount, 3);
      expect(r.span, const Duration(seconds: 2));
      expect(r.startup, const Duration(milliseconds: 900));
      expect(r.gapCount, 1);
      expect(r.clippedCount, 1);
      expect(r.partialCount, 2);
      expect(r.motionLeftOpen, isFalse);
    });

    test('nothing to measure is null, and an unclosed motion is flagged', () {
      final r = _recording(
        packets: [labPacket(1000)],
        markers: [
          labMarker(ImuMarkerKind.motionStart, 1200),
        ],
      );
      expect(r.span, isNull);
      expect(r.startup, isNull, reason: 'no tap marker, no startup');
      expect(r.motionLeftOpen, isTrue);
    });
  });

  group('the gyro-ready marker', () {
    ImuRecording withReady() => _recording(
          packets: [
            labPacket(1000, invalidGyro: 3),
            labPacket(2000, invalidGyro: 1),
            labPacket(3000),
          ],
          markers: [
            labMarker(ImuMarkerKind.tapReceived, 100),
            labMarker(ImuMarkerKind.streamRequested, 105),
            labMarker(ImuMarkerKind.firstPacket, 1000),
            labMarker(ImuMarkerKind.gyroReady, 2000,
                note: 'skipped 4 invalid gyro samples'),
          ],
        );

    test('round-trips: kind, time and note survive, and so do the invalid '
        'samples before it', () {
      final r = withReady();
      final text = r.toJsonLines();
      expect(text, contains('"kind":"gyroReady"'));
      final back = ImuRecording.parse(text);
      _expectSame(r, back);
      expect(back.toJsonLines(), text);
      expect(back.readyMarker!.mono, const Duration(milliseconds: 2000));
      expect(back.packets.first.gyroSamples.first.x, -2000);
    });

    test('the ready marker sorts before the packet that made it ready', () {
      final lines = const LineSplitter().convert(withReady().toJsonLines());
      final types = [
        for (final l in lines.skip(1))
          '${(jsonDecode(l) as Map)['type']}:${(jsonDecode(l) as Map)['kind']}',
      ];
      expect(types.indexOf('marker:gyroReady'), 4);
      expect(types[5], startsWith('packet'));
    });

    test('a file written before the marker existed still loads; with no marker '
        'every packet is motion data', () {
      final old = _recording(); // the default markers have no gyroReady
      final back = ImuRecording.parse(old.toJsonLines());
      expect(back.readyMarker, isNull);
      expect(back.motionPackets, hasLength(back.packets.length));
      expect(back.tapToReady, isNull);
    });

    test('motionPackets start at the ready packet; tapToReady says how long '
        'the wait was', () {
      final back = ImuRecording.parse(withReady().toJsonLines());
      expect(back.motionPackets.map((p) => p.monotonicReceipt.inMilliseconds),
          [2000, 3000]);
      expect(back.tapToReady, const Duration(milliseconds: 1900));
      expect(back.packets, hasLength(3), reason: 'nothing is dropped');
    });

    test('the never-ready status round-trips and is not complete', () {
      final r = _recording(status: ImuRecordingStatus.gyroNeverReady);
      final back = ImuRecording.parse(r.toJsonLines());
      expect(back.status, ImuRecordingStatus.gyroNeverReady);
      expect(back.isComplete, isFalse);
      expect(back.status.label, contains('Gyro'));
    });
  });
}
