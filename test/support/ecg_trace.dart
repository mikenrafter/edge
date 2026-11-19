// Parse the Device lab ECG packet export for hardware-probe tests.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  /// there and 0 elsewhere) must be loaded with [reconstructed]: since
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
