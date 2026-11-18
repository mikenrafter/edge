// Pulse evidence codec: literal fixtures first, round trip second, then the
// bounds. CLAIM(pulse-evidence-atomic) CLAIM(pulse-no-fabricated-pairs)
import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_codec.dart';
import 'package:openstrap_edge/data/pulse_ep/pulse_ep_types.dart';

// The expanded JSON, written by hand: the independent oracle for the format.
// Times are offsets from "start"; ids are source:recordTsMs:beatIndex.
const _literal = '{"v":1,"id":"s:1000000","source":"s","start":1000000,"end":1900000,'
    '"ongoing":false,'
    '"beats":{"k":[0,1000,2000],"i":[0,0,1],"x":[0,1,2],"t":[0,1000,1800],"o":[0,0,0],'
    '"r":[1000.0,800.0,900.0],"c":[null,null,950.0],"f":[63,63,59],"l":[0,1,0]},'
    '"labelSets":[[],["suddenDown"]],"windows":[],'
    '"overview":[[1000000,3,800.0,900.0,1000.0]],"hr":[[1000000,66.0]],'
    '"comparison":[],"jumps":["s:1001000:0"],"omitted":[[1500000,1600000,"capped"]]}';

Uint8List _pack(String json) =>
    Uint8List.fromList(ZLibCodec(level: 6).encode(utf8.encode(json)));
String _sum(String json) => sha256.convert(utf8.encode(json)).toString();

List<PulseBeat> _beats(int n, {int start = 1000000}) => [
  for (var i = 0; i < n; i++)
    PulseBeat(
      recordTsMs: start + (i ~/ 2) * 1000,
      beatIndex: i % 2,
      ordinal: i,
      timeMs: start + i * 500,
      originalTimeMs: start + i * 500,
      rawMs: 700.0 + (i * 37) % 300,
      flags: PulseBeat.plausible | PulseBeat.retained | PulseBeat.featureUse | PulseBeat.validAdjacent,
    ),
];

PulseEvidence _evidence(int n, {List<String> jumps = const []}) => PulseEvidence(
  episodeId: 's:1000000',
  source: 's',
  startMs: 1000000,
  endMs: 1000000 + n * 500,
  ongoing: false,
  beats: _beats(n),
  jumps: jumps,
);

void main() {
  // WHY: the on-disk format is a contract; this literal was not produced by the
  // writer, so a writer and reader that agree on a wrong format cannot pass.
  test('decodes a hand-written versioned recording with known beat ids', () {
    final read = decodePulseEvidence(_pack(_literal), checksum: _sum(_literal));
    expect(read, isA<PulseEvidencePartial>());
    final e = (read as PulseEvidencePartial).evidence;
    expect(e.episodeId, 's:1000000');
    expect([for (final b in e.beats) b.idIn(e.source)],
        ['s:1000000:0', 's:1001000:0', 's:1002000:1']);
    expect(e.beats[1].timeMs, 1001000);
    expect(e.beats[2].timeMs, 1001800);
    expect(e.beats[2].rawMs, 900.0);
    expect(e.beats[2].correctedMs, 950.0);
    expect(e.beats[0].correctedMs, isNull);
    expect(e.beats[1].labels, ['suddenDown']);
    expect(e.beats[2].has(PulseBeat.corrected), isFalse);
    expect(e.jumps, ['s:1001000:0']);
    expect(e.omitted, [const PulseRange(1500000, 1600000, 'capped')]);
    expect(e.overview.single.median, 900.0);
    expect(e.hr.single.bpm, 66.0);
  });

  test('an episode with no omitted range reads as Available', () {
    final json = _literal.replaceFirst(
        '"omitted":[[1500000,1600000,"capped"]]', '"omitted":[]');
    expect(decodePulseEvidence(_pack(json), checksum: _sum(json)),
        isA<PulseEvidenceAvailable>());
  });

  // WHY: writer-reader parity supplements the literal; it alone could hide a
  // symmetric bug.
  test('the writer output round-trips through the reader unchanged', () {
    final result = encodePulseEvidence(_evidence(50, jumps: ['s:1005000:0']));
    expect(result, isA<PulseEncoded>());
    final enc = result as PulseEncoded;
    final read = decodePulseEvidence(enc.bytes, checksum: enc.checksum);
    expect(read, isA<PulseEvidenceAvailable>());
    final back = (read as PulseEvidenceAvailable).evidence;
    expect(back.beats, hasLength(50));
    expect(back.beats[7].rawMs, _beats(50)[7].rawMs);
    expect(back.beats[7].idIn('s'), _beats(50)[7].idIn('s'));
    expect(back.jumps, ['s:1005000:0']);
  });

  // WHY: the checksum is over the canonical EXPANDED bytes, so it detects
  // corruption the compressor would otherwise hide.
  test('the checksum is the SHA-256 of the expanded bytes', () {
    final enc = encodePulseEvidence(_evidence(10)) as PulseEncoded;
    final expanded = ZLibCodec().decode(enc.bytes);
    expect(enc.checksum, sha256.convert(expanded).toString());
    expect(enc.expandedBytes, expanded.length);
  });

  test('a wrong checksum is corrupt, never drawn', () {
    final read = decodePulseEvidence(_pack(_literal), checksum: 'f' * 64);
    expect(read, isA<PulseEvidenceCorrupt>());
  });

  test('an unknown schema version is unsupported, not corrupt', () {
    final json = _literal.replaceFirst('"v":1', '"v":2');
    expect(decodePulseEvidence(_pack(json), checksum: _sum(json)),
        isA<PulseEvidenceUnsupported>());
  });

  // WHY (checklist 18/21): blank and malformed input degrade to an explicit
  // unavailable result.
  test('blank, non-zlib and malformed JSON are corrupt', () {
    expect(decodePulseEvidence(const [], checksum: _sum('')), isA<PulseEvidenceCorrupt>());
    expect(decodePulseEvidence([1, 2, 3, 4], checksum: 'x'), isA<PulseEvidenceCorrupt>());
    const bad = '{"v":1,"beats":';
    expect(decodePulseEvidence(_pack(bad), checksum: _sum(bad)), isA<PulseEvidenceCorrupt>());
  });

  test('a nonpositive interval is corrupt evidence', () {
    final json = _literal.replaceFirst('"r":[1000.0,800.0,900.0]', '"r":[1000.0,0.0,900.0]');
    expect(decodePulseEvidence(_pack(json), checksum: _sum(json)), isA<PulseEvidenceCorrupt>());
  });

  test('columns of unequal length are corrupt', () {
    final json = _literal.replaceFirst('"i":[0,0,1]', '"i":[0,0]');
    expect(decodePulseEvidence(_pack(json), checksum: _sum(json)), isA<PulseEvidenceCorrupt>());
  });

  // WHY (spec 4.2): the expanded cap is enforced DURING inflation. A 4 MiB run
  // of zeros compresses to a few KB; it must be refused without allocating it.
  test('a compression bomb is refused at the expanded cap', () {
    final bomb = Uint8List.fromList(ZLibCodec(level: 9).encode(Uint8List(4 * 1024 * 1024)));
    expect(bomb.length, lessThan(64 * 1024));
    final read = decodePulseEvidence(bomb, checksum: 'x');
    expect(read, isA<PulseEvidenceCorrupt>());
    expect((read as PulseEvidenceCorrupt).reason, contains('expanded'));
  });

  // WHY: 25,000 beats exceed the 20,000 cap. The writer clips, declares what
  // is missing, keeps both ends and the jump neighborhoods, and stays in bounds.
  test('an oversize episode is clipped with declared omissions', () {
    final jumpBeat = _beats(25000)[12000];
    final result = encodePulseEvidence(
        _evidence(25000, jumps: [jumpBeat.idIn('s')])) as PulseEncoded;
    final e = result.evidence;
    expect(e.beats.length, lessThanOrEqualTo(kPulseMaxBeats));
    expect(result.expandedBytes, lessThanOrEqualTo(kPulseEvidenceMaxBytes));
    expect(result.encodedBytes, lessThanOrEqualTo(kPulseEvidenceMaxBytes));
    expect(e.omitted, isNotEmpty);
    expect(e.beats.first.ordinal, 0);
    expect(e.beats.last.ordinal, 24999);
    final kept = {for (final b in e.beats) b.ordinal};
    for (var o = 11990; o <= 12010; o++) {
      expect(kept, contains(o), reason: 'jump neighborhood beat $o');
    }
    // every missing ordinal lies in a declared omitted range
    final missing = [for (var o = 0; o < 25000; o++) if (!kept.contains(o)) o];
    final times = {for (final b in _beats(25000)) b.ordinal: b.timeMs};
    for (final o in missing) {
      expect(e.omitted.any((r) => times[o]! >= r.startMs && times[o]! < r.endMs), isTrue,
          reason: 'ordinal $o is silently missing');
    }
    final read = decodePulseEvidence(result.bytes, checksum: result.checksum);
    expect(read, isA<PulseEvidencePartial>());
  });

  test('a small episode is encoded whole', () {
    final result = encodePulseEvidence(_evidence(200)) as PulseEncoded;
    expect(result.evidence.beats, hasLength(200));
    expect(result.evidence.omitted, isEmpty);
  });

  // WHY (6.1): quantiles use the declared index rule over the declared
  // population; a bpm band must be derived from sorted bpm, not from 60000/p.
  test('quantiles use floor((n - 1) * p)', () {
    expect(pulseQuantile([800, 1000], 0.1), 800);
    expect(pulseQuantile([800, 1000], 0.5), 800);
    expect(pulseQuantile([800, 1000], 0.9), 800);
    expect(pulseQuantile([60.0, 75.0], 0.1), 60);
    expect(pulseQuantile([1, 2, 3, 4, 5], 0.9), 4);
    expect(pulseQuantile(const [], 0.5), isNull);
  });
}
