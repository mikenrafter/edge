// ECG trace replay (8V): run EcgTapSession over recorded packets, off the band.
//
// A trace is the Device lab's "ECG packets" export (lib/gestures/lab_log.dart,
// `labPacketFormat`): one `r17v1` line per live R17 packet with the phone's
// receipt time, the strap time and the raw samples. A fixture file may add
// `session tag=... | settings=... | count=...` lines (what the band run
// decided) and `#` comments.
//
// [replayTrace] feeds one session's packets to a real EcgTapSession on a
// virtual clock (the session's `now` is each packet's receipt time; its waits
// advance nothing), so a change to the counter or the session can be tried
// against what the hardware actually sent.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// Build a parsed live R17 packet from its parts (through the real parser).
LabradorR17 r17({
  required int strapSeconds,
  int subseconds = 0,
  required List<int> samples,
  int flags = 0,
  int s2State = 0,
  int progress = 0,
  int quality = 0,
  int unreadable = 0,
  int sequence = 0,
}) {
  final n = samples.length;
  final inner = Uint8List(26 + 2 * n);
  final v = ByteData.sublistView(inner);
  inner[0] = 0x2B; // REALTIME_RAW_DATA
  inner[1] = 17;
  v.setUint32(3, sequence, Endian.little);
  v.setUint32(7, strapSeconds, Endian.little);
  v.setUint16(11, subseconds, Endian.little);
  inner[13] = quality;
  inner[14] = flags;
  inner[16] = s2State;
  inner[17] = progress;
  inner[18] = unreadable;
  v.setUint16(21, 0xffff, Endian.little);
  v.setUint16(24, n, Endian.little);
  for (var i = 0; i < n; i++) {
    v.setInt16(26 + 2 * i, samples[i], Endian.little);
  }
  return LabradorR17.parse(inner)!;
}

class TracePacket {
  const TracePacket(this.tag, this.receivedAt, this.r);
  final String tag;
  final DateTime receivedAt;
  final LabradorR17 r;
}

/// What a fixture says the band run decided for a session.
class TraceSession {
  const TraceSession(this.tag, this.settings, this.count);
  final String tag;
  final String settings;
  final int? count;
}

class Trace {
  Trace(this.packets, this.sessions);
  final List<TracePacket> packets;
  final List<TraceSession> sessions;

  List<TracePacket> of(String tag) =>
      packets.where((p) => p.tag == tag).toList();

  /// Read a fixture file. A RECONSTRUCTED fixture (the 18:17 one: its log gave
  /// only where each packet had signal, so its samples are a constant 120
  /// there and 0 elsewhere) must be loaded with [reconstructed]: since 8X
  /// contact is a signal that MOVES, a constant plateau is no contact, so each
  /// run of signal samples becomes a +120/-120 alternation (the same samples
  /// are non-zero, the packets keep their shape). A real Device lab export
  /// needs nothing.
  static Trace load(String path, {bool reconstructed = false}) =>
      parse(File(path).readAsStringSync(), reconstructed: reconstructed);

  /// Each run of non-zero samples alternates +120, -120, ... from its start.
  static List<int> _moving(List<int> samples) {
    final out = List<int>.of(samples);
    var runStart = -1;
    for (var i = 0; i < out.length; i++) {
      if (samples[i] == 0) {
        runStart = -1;
        continue;
      }
      if (runStart < 0) runStart = i;
      out[i] = (i - runStart).isEven ? 120 : -120;
    }
    return out;
  }

  /// Parse `r17v1` and `session` lines; anything else is ignored, so a whole
  /// copied Device lab log parses too.
  static Trace parse(String text, {bool reconstructed = false}) {
    final packets = <TracePacket>[];
    final sessions = <TraceSession>[];
    for (var line in const LineSplitter().convert(text)) {
      line = line.trim();
      if (line.startsWith('session tag=')) {
        final parts = line.substring('session tag='.length).split(' | ');
        String field(String k) => parts
            .firstWhere((p) => p.startsWith('$k='), orElse: () => '$k=')
            .substring(k.length + 1);
        sessions.add(TraceSession(
            parts.first, field('settings'), int.tryParse(field('count'))));
        continue;
      }
      if (!line.startsWith('r17v1 tag=')) continue;
      final bar = line.indexOf(' | ');
      final tag = line.substring('r17v1 tag='.length, bar);
      final kv = <String, String>{
        for (final f in line.substring(bar + 3).split(' '))
          if (f.contains('=')) f.substring(0, f.indexOf('=')): f.substring(f.indexOf('=') + 1),
      };
      final n = int.parse(kv['n']!);
      final b64 = kv['b64']!;
      List<int> samples;
      if (b64 == '0') {
        samples = List.filled(n, 0);
      } else {
        final bytes = base64.decode(b64);
        samples = Int16List.view(Uint8List.fromList(bytes).buffer, 0, n);
      }
      if (reconstructed) samples = _moving(samples);
      packets.add(TracePacket(
        tag,
        DateTime.fromMillisecondsSinceEpoch(int.parse(kv['recv']!)),
        r17(
          strapSeconds: int.parse(kv['sec']!),
          subseconds: int.parse(kv['sub']!),
          samples: samples,
          flags: int.parse(kv['flags']!, radix: 16),
          s2State: int.parse(kv['s2']!),
          progress: int.parse(kv['progress']!),
          quality: int.parse(kv['quality']!),
          unreadable: int.parse(kv['unreadable']!, radix: 16),
        ),
      ));
    }
    return Trace(packets, sessions);
  }
}

/// Thresholds from a lab settings summary ("start 500 ms, gap 200 ms, confirm
/// 1000 ms, extra sensitive").
EcgTapThresholds thresholdsOf(String summary) {
  int ms(String name) =>
      int.parse(RegExp('$name (\\d+) ms').firstMatch(summary)!.group(1)!);
  return EcgTapThresholds(
    startMs: ms('start'),
    gapMs: ms('gap'),
    confirmMs: ms('confirm'),
    extraSensitive: summary.contains('extra sensitive'),
  );
}

class ReplayResult {
  ReplayResult(this.steps, this.buzzes, this.results);
  final List<String> steps;

  /// Pulses of every buzz call, in order (one command per pulse by default).
  final List<int> buzzes;
  final List<(int?, String?)> results;

  /// The count decided, or null when the trace ended first.
  int? get count => results.isEmpty ? null : results.single.$1;

  /// Taps counted so far, decided or not: 3 once the three-pulse buzz was
  /// asked for, plus one per later one-pulse buzz that is not the final
  /// confirmation (which shares its sample time with the "Final count" line).
  int get counted {
    final decided = count;
    if (decided != null) return decided;
    final asked = <(int, String)>[];
    String? finalAt;
    for (final s in steps) {
      final b = RegExp(r'^Buzz x(\d+) requested at sample time (\d+) ms')
          .firstMatch(s);
      if (b != null) asked.add((int.parse(b.group(1)!), b.group(2)!));
      final f = RegExp(r'^Final count \d+ at sample time (\d+) ms').firstMatch(s);
      if (f != null) finalAt = f.group(1);
    }
    if (asked.isEmpty || asked.first.$1 != 3) return 2;
    return 3 +
        asked.skip(1).where((a) => a.$1 == 1 && a.$2 != finalAt).length;
  }
}

/// Replay [packets] through a fresh EcgTapSession. The tap is taken to have
/// arrived [tapLead] before the first packet. [max] is the session's tap limit.
Future<ReplayResult> replayTrace(
  List<TracePacket> packets, {
  required EcgTapThresholds thresholds,
  int max = 5,
  Duration? reacquire,
  Duration? settle,
  Duration tapLead = const Duration(seconds: 1),
}) async {
  final steps = <String>[];
  final buzzes = <int>[];
  final results = <(int?, String?)>[];
  var now = packets.first.receivedAt.subtract(tapLead);
  final s = EcgTapSession(
    // The pacing rig: one pulse per call, as 8W measured the band (a count is
    // one call by default since 8AF.6).
    maxPulsesPerBurst: 1,
    beginStream: () async => true,
    endStream: () async {},
    isStreamAlive: () => true,
    buzz: (pulses, _) async {
      buzzes.add(pulses);
      return true;
    },
    maxTaps: () => max,
    thresholds: () => thresholds,
    onFinished: (c, r) => results.add((c, r)),
    step: steps.add,
    now: () => now,
    wait: (_) async {},
    pollEvery: const Duration(hours: 1),
    sensorReacquire: reacquire ?? const Duration(milliseconds: 1500),
    sensorSettle: settle ?? const Duration(milliseconds: 2500),
  );
  final tap = StrapEvent(
    eventId: 14,
    tsEpoch: now.millisecondsSinceEpoch ~/ 1000,
    receivedAt: now,
    hex: '',
    deviceId: 'band',
  );
  await s.start(tap);
  for (final p in packets) {
    now = p.receivedAt;
    s.onFrame(p.r);
    await Future<void>.delayed(Duration.zero);
  }
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return ReplayResult(steps, buzzes, results);
}
