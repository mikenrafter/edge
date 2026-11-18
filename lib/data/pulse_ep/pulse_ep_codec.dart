// Owner: the Pulse evidence codec: one versioned, compressed, checksummed
// recording per episode revision (`pulse_ep_evidence.payload`).
//
// Format (schema 1): JSON, zlib level 6. Beats are COLUMNS so 20,000 of them fit
// in 1 MiB expanded: `k` record time and `t` placed time are offsets from
// `start`, `o` is original-minus-placed time, `i` the beat index in its record,
// `x` the detection ordinal, `r` raw ms, `c` corrected ms or null, `f` flag bits
// ([PulseBeat.plausible] ...), `l` an index into `labelSets`. A beat's id is
// `source:recordTsMs:beatIndex`. The checksum is SHA-256 over the expanded
// bytes and is verified before anything is parsed.
//
// CLAIM(pulse-evidence-atomic): bounds are enforced while inflating, before any
// allocation of the expanded payload [pulse_ep_codec_test].
import 'dart:convert';
import 'dart:io' show ZLibCodec, ZLibDecoder;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'pulse_ep_types.dart';

const int kPulseEvidenceSchema = 1;
const int kPulseEvidenceMaxBytes = 1024 * 1024;
const int kPulseMaxBeats = 20000;
const int kPulseMaxOverviewBins = 4096;
const int kPulseMaxWindowRows = 4096;

/// One retained beat. Identity is `source:recordTsMs:beatIndex`.
class PulseBeat {
  const PulseBeat({
    required this.recordTsMs,
    required this.beatIndex,
    required this.ordinal,
    required this.timeMs,
    required this.originalTimeMs,
    required this.rawMs,
    this.correctedMs,
    this.flags = 0,
    this.labels = const [],
  });
  final int recordTsMs, beatIndex, ordinal, timeMs, originalTimeMs;
  final double rawMs;
  final double? correctedMs;
  final int flags;
  final List<String> labels;

  static const plausible = 1,
      retained = 2,
      corrected = 4,
      dropped = 8,
      featureUse = 16,
      validAdjacent = 32;
  bool has(int flag) => flags & flag != 0;
  String idIn(String source) => '$source:$recordTsMs:$beatIndex';
}

class PulseOverviewBin {
  const PulseOverviewBin(this.startMs, this.n, this.p10, this.median, this.p90);
  final int startMs, n;
  final double p10, median, p90;
}

class PulseHrBin {
  const PulseHrBin(this.startMs, this.bpm);
  final int startMs;
  final double bpm;
}

class PulseEvidence {
  const PulseEvidence({
    required this.episodeId,
    required this.source,
    required this.startMs,
    required this.endMs,
    required this.ongoing,
    required this.beats,
    this.windows = const [],
    this.overview = const [],
    this.hr = const [],
    this.comparisonRrMs = const [],
    this.jumps = const [],
    this.omitted = const [],
  });
  final String episodeId, source;
  final int startMs, endMs;
  final bool ongoing;
  final List<PulseBeat> beats;
  final List<Map<String, Object?>> windows;
  final List<PulseOverviewBin> overview;
  final List<PulseHrBin> hr;
  final List<double> comparisonRrMs;
  final List<String> jumps;
  final List<PulseRange> omitted;
  bool get partial => omitted.isNotEmpty;
}

sealed class PulseEncodeResult {
  const PulseEncodeResult();
}

final class PulseEncoded extends PulseEncodeResult {
  const PulseEncoded({
    required this.bytes,
    required this.checksum,
    required this.expandedBytes,
    required this.evidence,
    required this.retainedJson,
    required this.omittedJson,
  });
  /// `[[start, end]]` of what the recording covers, and `[[start, end, reason]]`
  /// of what it declares missing, as stored beside the blob. Built here, in the
  /// worker, so the store never encodes JSON on the UI isolate.
  final String retainedJson, omittedJson;
  final Uint8List bytes;
  final String checksum;
  final int expandedBytes;
  final PulseEvidence evidence;
  int get encodedBytes => bytes.length;
}

final class PulseEncodeRefused extends PulseEncodeResult {
  const PulseEncodeRefused(this.reason);
  final String reason;
}

sealed class PulseEvidenceRead {
  const PulseEvidenceRead();
}

final class PulseEvidenceAvailable extends PulseEvidenceRead {
  const PulseEvidenceAvailable(this.evidence);
  final PulseEvidence evidence;
}

final class PulseEvidencePartial extends PulseEvidenceRead {
  const PulseEvidencePartial(this.evidence);
  final PulseEvidence evidence;
}

final class PulseEvidenceUnsupported extends PulseEvidenceRead {
  const PulseEvidenceUnsupported(this.reason);
  final String reason;
}

final class PulseEvidenceCorrupt extends PulseEvidenceRead {
  const PulseEvidenceCorrupt(this.reason);
  final String reason;
}


const _labelSets = 'labelSets';

class _TooBig implements Exception {
  const _TooBig();
}

/// Collects inflated bytes and aborts the moment they pass the cap.
class _CappedSink implements Sink<List<int>> {
  final BytesBuilder _out = BytesBuilder(copy: false);
  int _total = 0;
  @override
  void add(List<int> chunk) {
    _total += chunk.length;
    if (_total > kPulseEvidenceMaxBytes) throw const _TooBig();
    _out.add(chunk);
  }

  @override
  void close() {}
  Uint8List bytes() => _out.takeBytes();
}

/// Sorted-index quantile: `floor((n - 1) * p)`. Empty populations have none.
double? pulseQuantile(List<double> sorted, double p) =>
    sorted.isEmpty ? null : sorted[((sorted.length - 1) * p).floor()];

Map<String, Object?> _document(PulseEvidence e, List<PulseBeat> beats) {
  final sets = <String>[];
  final setIndex = <String, int>{};
  int labelIndex(List<String> labels) {
    final key = jsonEncode(labels);
    return setIndex.putIfAbsent(key, () {
      sets.add(key);
      return sets.length - 1;
    });
  }

  setIndex[jsonEncode(const <String>[])] = 0;
  sets.add(jsonEncode(const <String>[]));
  final l = [for (final b in beats) labelIndex(b.labels)];
  return {
    'v': kPulseEvidenceSchema,
    'id': e.episodeId,
    'source': e.source,
    'start': e.startMs,
    'end': e.endMs,
    'ongoing': e.ongoing,
    'beats': {
      'k': [for (final b in beats) b.recordTsMs - e.startMs],
      'i': [for (final b in beats) b.beatIndex],
      'x': [for (final b in beats) b.ordinal],
      't': [for (final b in beats) b.timeMs - e.startMs],
      'o': [for (final b in beats) b.originalTimeMs - b.timeMs],
      'r': [for (final b in beats) b.rawMs],
      'c': [for (final b in beats) b.correctedMs],
      'f': [for (final b in beats) b.flags],
      'l': l,
    },
    _labelSets: [for (final s in sets) jsonDecode(s)],
    'windows': e.windows.take(kPulseMaxWindowRows).toList(),
    'overview': [
      for (final o in e.overview.take(kPulseMaxOverviewBins))
        [o.startMs, o.n, o.p10, o.median, o.p90],
    ],
    'hr': [for (final h in e.hr) [h.startMs, h.bpm]],
    'comparison': e.comparisonRrMs,
    'jumps': e.jumps,
    'omitted': [for (final r in e.omitted) [r.startMs, r.endMs, r.reason]],
  };
}

/// Keeps both ends and each jump neighborhood first, then fills the remaining
/// room in time order. Returns kept indexes (ascending).
List<int> _select(PulseEvidence e, int limit) {
  final n = e.beats.length;
  if (n <= limit) return [for (var i = 0; i < n; i++) i];
  final keep = <int>{};
  final end = limit < 1000 ? limit ~/ 2 : 500;
  for (var i = 0; i < end && i < n; i++) {
    keep.add(i);
    keep.add(n - 1 - i);
  }
  final at = <String, int>{
    for (var i = 0; i < n; i++) e.beats[i].idIn(e.source): i,
  };
  for (final id in e.jumps) {
    final i = at[id];
    if (i == null) continue;
    for (var j = i - 10; j <= i + 10; j++) {
      if (j >= 0 && j < n) keep.add(j);
    }
  }
  for (var i = 0; i < n && keep.length < limit; i++) {
    keep.add(i);
  }
  final out = keep.toList()..sort();
  if (out.length <= limit) return out;
  // Mandatory neighborhoods alone overflow: drop from the middle outward.
  return out.sublist(0, limit ~/ 2) + out.sublist(out.length - (limit - limit ~/ 2));
}

List<PulseRange> _omissions(PulseEvidence e, List<int> kept) {
  final out = <PulseRange>[];
  final keptSet = kept.toSet();
  final n = e.beats.length;
  var i = 0;
  while (i < n) {
    if (keptSet.contains(i)) {
      i++;
      continue;
    }
    final first = i;
    while (i < n && !keptSet.contains(i)) {
      i++;
    }
    final start = e.beats[first].timeMs;
    final last = e.beats[i - 1].timeMs;
    final next = i < n ? e.beats[i].timeMs : e.endMs;
    out.add(PulseRange(start, next > last ? next : last + 1, 'capped'));
  }
  return out;
}

PulseEncodeResult encodePulseEvidence(PulseEvidence evidence) {
  var limit = kPulseMaxBeats;
  for (var attempt = 0; attempt < 24; attempt++) {
    final kept = _select(evidence, limit);
    final beats = [for (final i in kept) evidence.beats[i]];
    final omitted = [
      ...evidence.omitted,
      if (kept.length < evidence.beats.length) ..._omissions(evidence, kept),
    ];
    final retained = PulseEvidence(
      episodeId: evidence.episodeId,
      source: evidence.source,
      startMs: evidence.startMs,
      endMs: evidence.endMs,
      ongoing: evidence.ongoing,
      beats: beats,
      windows: evidence.windows.take(kPulseMaxWindowRows).toList(),
      overview: evidence.overview.take(kPulseMaxOverviewBins).toList(),
      hr: evidence.hr,
      comparisonRrMs: evidence.comparisonRrMs,
      jumps: evidence.jumps,
      omitted: omitted,
    );
    final expanded = Uint8List.fromList(
      utf8.encode(jsonEncode(_document(retained, beats))),
    );
    if (expanded.length > kPulseEvidenceMaxBytes) {
      limit = (kept.length * 0.85).floor();
      if (limit < 2) break;
      continue;
    }
    final packed = Uint8List.fromList(ZLibCodec(level: 6).encode(expanded));
    if (packed.length > kPulseEvidenceMaxBytes) {
      limit = (kept.length * 0.85).floor();
      if (limit < 2) break;
      continue;
    }
    return PulseEncoded(
      bytes: packed,
      checksum: sha256.convert(expanded).toString(),
      expandedBytes: expanded.length,
      evidence: retained,
      retainedJson: jsonEncode([[retained.startMs, retained.endMs]]),
      omittedJson: jsonEncode([for (final r in omitted) [r.startMs, r.endMs, r.reason]]),
    );
  }
  return const PulseEncodeRefused('evidence does not fit the 1 MiB envelope');
}

PulseEvidenceRead decodePulseEvidence(List<int> bytes, {required String checksum}) {
  if (bytes.isEmpty) return const PulseEvidenceCorrupt('blank recording');
  final Uint8List expanded;
  try {
    final sink = _CappedSink();
    final conversion = ZLibDecoder().startChunkedConversion(sink);
    conversion.add(bytes);
    conversion.close();
    expanded = sink.bytes();
  } on _TooBig {
    return const PulseEvidenceCorrupt('expanded size exceeds the 1 MiB cap');
  } catch (_) {
    return const PulseEvidenceCorrupt('not a valid compressed recording');
  }
  if (sha256.convert(expanded).toString() != checksum) {
    return const PulseEvidenceCorrupt('checksum mismatch');
  }
  try {
    final doc = jsonDecode(utf8.decode(expanded));
    if (doc is! Map) return const PulseEvidenceCorrupt('not an object');
    final v = doc['v'];
    if (v is! int) return const PulseEvidenceCorrupt('missing version');
    if (v != kPulseEvidenceSchema) {
      return PulseEvidenceUnsupported('schema $v');
    }
    return _parse(doc);
  } on _Bad catch (e) {
    return PulseEvidenceCorrupt(e.reason);
  } catch (_) {
    return const PulseEvidenceCorrupt('malformed recording');
  }
}

class _Bad implements Exception {
  const _Bad(this.reason);
  final String reason;
}

List<T> _list<T>(Object? v, String what) {
  if (v is! List) throw _Bad('$what is not a list');
  return v.cast<T>();
}

PulseEvidenceRead _parse(Map doc) {
  final source = doc['source'];
  final id = doc['id'];
  final start = doc['start'], end = doc['end'];
  if (source is! String || id is! String || start is! int || end is! int) {
    throw const _Bad('header');
  }
  final cols = doc['beats'];
  if (cols is! Map) throw const _Bad('beats');
  final k = _list<int>(cols['k'], 'k');
  final n = k.length;
  if (n > kPulseMaxBeats) throw const _Bad('too many beats');
  final i = _list<int>(cols['i'], 'i');
  final x = _list<int>(cols['x'], 'x');
  final t = _list<int>(cols['t'], 't');
  final o = _list<int>(cols['o'], 'o');
  final r = _list<num>(cols['r'], 'r');
  final c = _list<num?>(cols['c'], 'c');
  final f = _list<int>(cols['f'], 'f');
  final l = _list<int>(cols['l'], 'l');
  for (final col in [i.length, x.length, t.length, o.length, r.length, c.length, f.length, l.length]) {
    if (col != n) throw const _Bad('beat columns differ in length');
  }
  final sets = [
    for (final s in _list<Object?>(doc[_labelSets], _labelSets)) _list<String>(s, 'label set'),
  ];
  final beats = <PulseBeat>[];
  for (var j = 0; j < n; j++) {
    final raw = r[j].toDouble();
    final corrected = c[j]?.toDouble();
    if (!raw.isFinite || raw <= 0) throw const _Bad('nonpositive interval');
    if (corrected != null && (!corrected.isFinite || corrected <= 0)) {
      throw const _Bad('nonpositive corrected interval');
    }
    if (f[j] < 0 || f[j] > 63) throw const _Bad('flags');
    if (l[j] < 0 || l[j] >= sets.length) throw const _Bad('label index');
    beats.add(PulseBeat(
      recordTsMs: start + k[j],
      beatIndex: i[j],
      ordinal: x[j],
      timeMs: start + t[j],
      originalTimeMs: start + t[j] + o[j],
      rawMs: raw,
      correctedMs: corrected,
      flags: f[j],
      labels: sets[l[j]],
    ));
  }
  final omitted = <PulseRange>[];
  for (final e in _list<Object?>(doc['omitted'], 'omitted')) {
    final row = _list<Object?>(e, 'omitted row');
    if (row.length != 3 || row[0] is! int || row[1] is! int || row[2] is! String) {
      throw const _Bad('omitted row');
    }
    if ((row[0] as int) > (row[1] as int)) throw const _Bad('omitted range');
    omitted.add(PulseRange(row[0] as int, row[1] as int, row[2] as String));
  }
  final windows = [
    for (final w in _list<Object?>(doc['windows'], 'windows'))
      if (w is Map) w.cast<String, Object?>() else throw const _Bad('window row'),
  ];
  if (windows.length > kPulseMaxWindowRows) throw const _Bad('too many windows');
  final overview = [
    for (final row in _list<Object?>(doc['overview'], 'overview'))
      () {
        final v = _list<num>(row, 'overview row');
        if (v.length != 5) throw const _Bad('overview row');
        return PulseOverviewBin(v[0].toInt(), v[1].toInt(), v[2].toDouble(), v[3].toDouble(), v[4].toDouble());
      }(),
  ];
  if (overview.length > kPulseMaxOverviewBins) throw const _Bad('too many bins');
  final hr = [
    for (final row in _list<Object?>(doc['hr'], 'hr'))
      () {
        final v = _list<num>(row, 'hr row');
        if (v.length != 2) throw const _Bad('hr row');
        return PulseHrBin(v[0].toInt(), v[1].toDouble());
      }(),
  ];
  final evidence = PulseEvidence(
    episodeId: id,
    source: source,
    startMs: start,
    endMs: end,
    ongoing: doc['ongoing'] == true,
    beats: beats,
    windows: windows,
    overview: overview,
    hr: hr,
    comparisonRrMs: [for (final v in _list<num>(doc['comparison'], 'comparison')) v.toDouble()],
    jumps: _list<String>(doc['jumps'], 'jumps'),
    omitted: omitted,
  );
  return evidence.partial ? PulseEvidencePartial(evidence) : PulseEvidenceAvailable(evidence);
}
