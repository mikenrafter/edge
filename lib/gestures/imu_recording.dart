// A lab recording of the live six-axis IMU stream, and its file format.
//
// A recording keeps what the band sent as it arrived: whole packets with their
// separate accel and gyro arrays and counts (a gen5 packet can carry different
// valid counts for the two sensors, so they are never zipped into rows), the
// device's own timestamp fields, and when the phone received each packet. Next
// to the packets sit markers: the tap that began it, the request for the
// stream, the first packet, the gyro-ready moment, a cue, and the wearer's own
// motion start and end. Packets before the gyro-ready marker stay in the file
// (the first four gyro samples of a stream are invalid, and the early packets
// say how long the band took), but the motion processing starts at it
// ([ImuRecording.motionPackets]). A file with no such marker is read whole.
//
// The file is versioned JSON Lines, one JSON object per line, written only when
// the wearer saves (the lab never persists a stream on its own):
//
//     {"type":"header","format":"openstrap-imu-recording","version":1,...}
//     {"type":"marker","kind":"tapReceived","monoUs":...,"wallUs":...}
//     {"type":"packet","monoUs":...,"wallUs":...,"kind":"gen5R21",...,
//      "accel":[[x,y,z],...],"gyro":[[x,y,z],...]}
//
// The header carries the metadata and the number of packet and marker lines, so
// a truncated file is refused instead of read as a shorter recording. Lines of
// a type this version does not know are skipped, so a later version can add
// line types. Times: `monoUs` is the phone's monotonic receipt clock in
// microseconds (process-local, only differences mean anything), `wallUs` is
// microseconds since the Unix epoch, UTC. Accel is in g, gyro in degrees per
// second, as ImuPacket holds them.
//
// Pure Dart: no clock, no file, no platform.
import 'dart:convert';

import '../state/imu_packet.dart';

const String kImuRecordingFormat = 'openstrap-imu-recording';
const int kImuRecordingVersion = 1;

/// What the wearer meant to capture.
enum ImuRecordingKind {
  action('action', 'Action'),
  ambient('ambient', 'Ambient'),
  unintendedTap('unintendedTap', 'Unintended tap');

  const ImuRecordingKind(this.id, this.label);
  final String id;
  final String label;
}

enum ImuWrist {
  left('left', 'Left'),
  right('right', 'Right');

  const ImuWrist(this.id, this.label);
  final String id;
  final String label;
}

/// How a recording ended. Anything other than [completed] is a partial
/// recording: what arrived is kept and the reason is in the file.
enum ImuRecordingStatus {
  /// The requested duration ran out.
  completed,

  /// The packet limit was reached first.
  packetLimit,

  /// The wearer stopped it early.
  stopped,

  /// The band disconnected while it ran.
  disconnected,

  /// No packet arrived in time after the stream was requested.
  streamTimeout,

  /// Packets arrived but none held a valid gyro sample in time (see
  /// ImuReadiness): the recording has no gyro-ready marker.
  gyroNeverReady,

  /// The lab closed while it ran.
  interrupted;

  bool get isComplete => this == completed;

  String get label => switch (this) {
        completed => 'Completed',
        packetLimit => 'Stopped at the packet limit',
        stopped => 'Stopped early',
        disconnected => 'Band disconnected',
        streamTimeout => 'No packets arrived',
        gyroNeverReady => 'Gyro never became valid',
        interrupted => 'Interrupted',
      };
}

enum ImuMarkerKind {
  /// The double tap that began the recording (or a later tap during it).
  tapReceived,

  /// The phone asked for the IMU stream.
  streamRequested,

  /// The first packet reached the phone.
  firstPacket,

  /// The first packet with a valid gyro sample and accel reached the phone: the
  /// moment the wearer was told to move (the band buzzed). Written once, only
  /// when it happened; files from before it existed have none. The note says
  /// how many invalid gyro samples came first.
  gyroReady,

  /// A cue the band or phone played.
  cue,

  /// The wearer says the motion began / ended.
  motionStart,
  motionEnd,
}

class ImuMarker {
  const ImuMarker({
    required this.kind,
    required this.mono,
    required this.at,
    this.bandEventAge,
    this.note,
  });

  final ImuMarkerKind kind;

  /// The phone's monotonic receipt clock.
  final Duration mono;

  /// Wall time, UTC.
  final DateTime at;

  /// For a tap: how long before its receipt the band says it happened, when
  /// the band's clock allows saying.
  final Duration? bandEventAge;
  final String? note;
}

/// Everything about a recording except what was measured.
class ImuRecordingMeta {
  const ImuRecordingMeta({
    required this.id,
    required this.kind,
    required this.label,
    required this.bandModel,
    required this.deviceId,
    required this.createdAt,
    required this.requestedDuration,
    required this.maxPackets,
    this.bandFirmware,
    this.wrist,
    this.mounting = '',
    this.posture = '',
    this.environment = '',
    this.appVersion = '',
    this.protocolVersion = '',
  });

  /// File-name safe: letters, digits, `-` and `_`.
  final String id;
  final ImuRecordingKind kind;
  final String label;

  /// `WHOOP 4.0`, `WHOOP 5.0`, `WHOOP MG`, or what the app could tell.
  final String bandModel;
  final String? bandFirmware;
  final String deviceId;

  /// Null: not said.
  final ImuWrist? wrist;
  final String mounting;
  final String posture;
  final String environment;
  final String appVersion;
  final String protocolVersion;

  /// UTC.
  final DateTime createdAt;

  /// How long to record once the first packet arrived, and the packet limit.
  final Duration requestedDuration;
  final int maxPackets;
}

class ImuRecording {
  ImuRecording({
    required this.meta,
    required this.status,
    required List<ImuPacket> packets,
    required List<ImuMarker> markers,
  })  : packets = List.unmodifiable(packets),
        markers = List.unmodifiable(markers);

  final ImuRecordingMeta meta;
  final ImuRecordingStatus status;
  final List<ImuPacket> packets;
  final List<ImuMarker> markers;

  int get packetCount => packets.length;
  bool get isComplete => status.isComplete;

  /// First to last packet receipt; null with fewer than two packets.
  Duration? get span => packets.length < 2
      ? null
      : packets.last.monotonicReceipt - packets.first.monotonicReceipt;

  /// Tap receipt to first packet; null without both.
  Duration? get startup {
    final tap = _firstMarker(ImuMarkerKind.tapReceived);
    final first = packets.isEmpty ? null : packets.first.monotonicReceipt;
    return tap == null || first == null ? null : first - tap.mono;
  }

  /// The moment the wearer was told to move; null when it never happened or the
  /// file predates it.
  ImuMarker? get readyMarker => _firstMarker(ImuMarkerKind.gyroReady);

  /// Tap receipt to the gyro-ready moment; null without both.
  Duration? get tapToReady {
    final tap = _firstMarker(ImuMarkerKind.tapReceived), ready = readyMarker;
    return tap == null || ready == null ? null : ready.mono - tap.mono;
  }

  /// What the motion processing reads: the packets from the gyro-ready marker
  /// on (the ready packet included, it is the first usable one), or all of
  /// them when there is no marker.
  List<ImuPacket> get motionPackets {
    final ready = readyMarker;
    if (ready == null) return packets;
    return [
      for (final p in packets)
        if (p.monotonicReceipt >= ready.mono) p,
    ];
  }

  /// Packets the adapter flagged as following a gap.
  int get gapCount => packets.where((p) => p.quality.gapFromPrevious).length;
  int get clippedCount => packets.where((p) => p.quality.clipped).length;
  int get partialCount => packets.where((p) => p.quality.partialBlock).length;

  /// A motion start with no end after it (the wearer never closed it).
  bool get motionLeftOpen {
    var open = false;
    for (final m in markers) {
      if (m.kind == ImuMarkerKind.motionStart) open = true;
      if (m.kind == ImuMarkerKind.motionEnd) open = false;
    }
    return open;
  }

  ImuMarker? _firstMarker(ImuMarkerKind k) {
    for (final m in markers) {
      if (m.kind == k) return m;
    }
    return null;
  }

  /// The file's text. Markers and packets are interleaved by monotonic time,
  /// a marker first on a tie.
  String toJsonLines() {
    final out = StringBuffer()
      ..writeln(jsonEncode(_header()));
    var m = 0, p = 0;
    while (m < markers.length || p < packets.length) {
      final takeMarker = p >= packets.length ||
          (m < markers.length &&
              markers[m].mono <= packets[p].monotonicReceipt);
      out.writeln(jsonEncode(
          takeMarker ? _markerJson(markers[m++]) : _packetJson(packets[p++])));
    }
    return out.toString();
  }

  /// Read a file written by [toJsonLines]. Throws [FormatException] for text
  /// that is not a recording of a version this app reads, or that has fewer
  /// lines than its header says.
  static ImuRecording parse(String text) {
    try {
      return _parse(text);
    } on TypeError {
      // A field of the wrong type or a missing one.
      throw const FormatException('The recording has a missing or malformed field.');
    } on RangeError {
      throw const FormatException('The recording has a malformed sample.');
    }
  }

  static ImuRecording _parse(String text) {
    final lines = const LineSplitter()
        .convert(text)
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) throw const FormatException('Empty recording file.');
    final header = _object(lines.first, 'header');
    if (header['type'] != 'header' || header['format'] != kImuRecordingFormat) {
      throw const FormatException('Not an OpenStrap IMU recording.');
    }
    final version = header['version'];
    if (version is! int || version != kImuRecordingVersion) {
      throw FormatException('Unsupported recording version: $version.');
    }
    final meta = _metaOf(header);
    final status = _enum(ImuRecordingStatus.values, header['status'], 'status');
    final deviceId = meta.deviceId;
    final packets = <ImuPacket>[];
    final markers = <ImuMarker>[];
    for (var i = 1; i < lines.length; i++) {
      final o = _object(lines[i], 'line ${i + 1}');
      switch (o['type']) {
        case 'packet':
          packets.add(_packetOf(o, deviceId));
        case 'marker':
          markers.add(_markerOf(o));
        default:
          break; // A line type from a later version.
      }
    }
    final wantPackets = header['packetCount'], wantMarkers = header['markerCount'];
    if (wantPackets != packets.length || wantMarkers != markers.length) {
      throw FormatException(
          'The file is cut short: the header lists $wantPackets packets and '
          '$wantMarkers markers, the file has ${packets.length} and '
          '${markers.length}.');
    }
    return ImuRecording(
        meta: meta, status: status, packets: packets, markers: markers);
  }

  Map<String, Object?> _header() => {
        'type': 'header',
        'format': kImuRecordingFormat,
        'version': kImuRecordingVersion,
        'id': meta.id,
        'recordingKind': meta.kind.id,
        'label': meta.label,
        'status': status.name,
        'createdUtc': meta.createdAt.toUtc().toIso8601String(),
        'band': {
          'model': meta.bandModel,
          if (meta.bandFirmware != null) 'firmware': meta.bandFirmware,
          'deviceId': meta.deviceId,
        },
        if (meta.wrist != null) 'wrist': meta.wrist!.id,
        'mounting': meta.mounting,
        'posture': meta.posture,
        'environment': meta.environment,
        'app': {
          'version': meta.appVersion,
          'protocol': meta.protocolVersion,
        },
        'requestedDurationMs': meta.requestedDuration.inMilliseconds,
        'maxPackets': meta.maxPackets,
        'packetCount': packets.length,
        'markerCount': markers.length,
      };

  Map<String, Object?> _markerJson(ImuMarker m) => {
        'type': 'marker',
        'kind': m.kind.name,
        'monoUs': m.mono.inMicroseconds,
        'wallUs': m.at.microsecondsSinceEpoch,
        if (m.bandEventAge != null) 'eventAgeUs': m.bandEventAge!.inMicroseconds,
        if (m.note != null) 'note': m.note,
      };

  Map<String, Object?> _packetJson(ImuPacket p) => {
        'type': 'packet',
        'monoUs': p.monotonicReceipt.inMicroseconds,
        'wallUs': p.receivedAt.microsecondsSinceEpoch,
        'kind': p.kind.name,
        'generation': p.connectionGeneration,
        if (p.deviceId != meta.deviceId) 'deviceId': p.deviceId,
        if (p.recordIndex != null) 'recordIndex': p.recordIndex,
        if (p.deviceUnixSeconds != null) 'deviceUnix': p.deviceUnixSeconds,
        if (p.deviceSubseconds != null) 'deviceSubsec': p.deviceSubseconds,
        'accelCount': p.accelSampleCount,
        'gyroCount': p.gyroSampleCount,
        'spacingUs': p.nominalSampleSpacing.inMicroseconds,
        'quality': {
          'gap': p.quality.gapFromPrevious,
          'accelClipped': p.quality.accelClipped,
          'gyroClipped': p.quality.gyroClipped,
          'partial': p.quality.partialBlock,
        },
        'accel': [for (final s in p.accelSamples) [s.x, s.y, s.z]],
        'gyro': [for (final s in p.gyroSamples) [s.x, s.y, s.z]],
      };

  static Map<String, Object?> _object(String line, String where) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (e) {
      throw FormatException('Unreadable $where: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException('The $where is not a JSON object.');
    }
    return decoded;
  }

  static T _enum<T extends Enum>(List<T> values, Object? name, String what) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    throw FormatException('Unknown $what: $name.');
  }

  static ImuRecordingMeta _metaOf(Map<String, Object?> h) {
    final band = h['band'];
    final app = h['app'];
    if (band is! Map || app is! Map) {
      throw const FormatException('The header lacks band or app details.');
    }
    final kindId = h['recordingKind'];
    final kind = ImuRecordingKind.values.firstWhere((k) => k.id == kindId,
        orElse: () => throw FormatException('Unknown kind: $kindId.'));
    final wristId = h['wrist'];
    final ImuWrist? wrist = wristId == null
        ? null
        : ImuWrist.values.firstWhere((w) => w.id == wristId,
            orElse: () => throw FormatException('Unknown wrist: $wristId.'));
    return ImuRecordingMeta(
      id: h['id'] as String,
      kind: kind,
      label: h['label'] as String,
      bandModel: band['model'] as String,
      bandFirmware: band['firmware'] as String?,
      deviceId: band['deviceId'] as String,
      wrist: wrist,
      mounting: h['mounting'] as String,
      posture: h['posture'] as String,
      environment: h['environment'] as String,
      appVersion: app['version'] as String,
      protocolVersion: app['protocol'] as String,
      createdAt: DateTime.parse(h['createdUtc'] as String).toUtc(),
      requestedDuration: Duration(milliseconds: h['requestedDurationMs'] as int),
      maxPackets: h['maxPackets'] as int,
    );
  }

  static ImuMarker _markerOf(Map<String, Object?> o) {
    final age = o['eventAgeUs'] as int?;
    return ImuMarker(
      kind: _enum(ImuMarkerKind.values, o['kind'], 'marker kind'),
      mono: Duration(microseconds: o['monoUs'] as int),
      at: DateTime.fromMicrosecondsSinceEpoch(o['wallUs'] as int, isUtc: true),
      bandEventAge: age == null ? null : Duration(microseconds: age),
      note: o['note'] as String?,
    );
  }

  static ImuPacket _packetOf(Map<String, Object?> o, String deviceId) {
    final q = o['quality'] as Map<String, Object?>;
    return ImuPacket(
      deviceId: (o['deviceId'] as String?) ?? deviceId,
      connectionGeneration: o['generation'] as int,
      kind: _enum(ImuPacketKind.values, o['kind'], 'packet kind'),
      recordIndex: o['recordIndex'] as int?,
      deviceUnixSeconds: o['deviceUnix'] as int?,
      deviceSubseconds: o['deviceSubsec'] as int?,
      receivedAt:
          DateTime.fromMicrosecondsSinceEpoch(o['wallUs'] as int, isUtc: true),
      monotonicReceipt: Duration(microseconds: o['monoUs'] as int),
      accelSamples: _vectors(o['accel']),
      gyroSamples: _vectors(o['gyro']),
      accelSampleCount: o['accelCount'] as int,
      gyroSampleCount: o['gyroCount'] as int,
      nominalSampleSpacing: Duration(microseconds: o['spacingUs'] as int),
      quality: ImuPacketQuality(
        gapFromPrevious: q['gap'] as bool,
        accelClipped: q['accelClipped'] as bool,
        gyroClipped: q['gyroClipped'] as bool,
        partialBlock: q['partial'] as bool,
      ),
    );
  }

  static List<ImuVector> _vectors(Object? raw) => List.unmodifiable([
        for (final v in raw as List)
          ImuVector((v[0] as num).toDouble(), (v[1] as num).toDouble(),
              (v[2] as num).toDouble()),
      ]);
}
