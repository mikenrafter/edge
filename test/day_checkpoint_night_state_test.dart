// RED tests: the RAM-only incremental states survive an app restart by riding
// in the existing day checkpoint blob (no schema change, kDayCheckpointFmt 5).
//
//   * night RR        DayCalculationState.nightRr's RrCorrector (+ the settled
//                     corrected beats it already handed out),
//   * night spectral  HrvFreqStream / RsaRespStream fed the settled beats,
//   * cardio rows     the engine's main-isolate CardioRowCache (`_cardioRows`).
//
// CONTRACT (the green phase implements exactly this; names are pinned)
// --------------------------------------------------------------------
// 1. The day part is window-independent and stays so (dayContextSig is
//    untouched). The night states depend on the sleep window, so they are a
//    SEPARATE OPTIONAL suffix of the blob, never mixed into the day part:
//    the bytes of the day part do not depend on whether a night part or cardio
//    rows are present (test: 'optional suffix').
// 2. New file lib/compute/night_resume_part.dart:
//      typedef NightFoldTag = ({double startTsMs, int count, int fingerprint});
//        startTsMs    first beat timestamp (epoch ms) of the folded night slice
//        count        number of beats folded
//        fingerprint  nightBeatsFingerprint(rr, ts, count)
//      int nightBeatsFingerprint(List<double> rrMs, List<double> rrTsMs, int count)
//        64-bit FNV-1a (offset 0xcbf29ce484222325, prime 0x100000001b3,
//        wrapping 64-bit int arithmetic) over, for i in 0..count-1, the 8 bytes
//        of rrMs[i] then the 8 bytes of rrTsMs[i], each the raw IEEE-754 bits
//        written little-endian. Exact bits: -0.0 != 0.0, 1 ulp differs.
//        Deterministic across processes (no hashCode).
//      class NightResumePart   plain data only (sendable to a worker)
//        NightFoldTag get tag
//        Map<String, dynamic> toJson()   FIRST key 'v' (int, version 1), then
//            key 'tag': {'startTsMs': double, 'count': int, 'fp': String} where
//            'fp' is the fingerprint as a signed decimal string
//        factory NightResumePart.fromJson(Map<String, dynamic>)
//            versioned; throws FormatException on anything malformed (wrong
//            version, bad tag, a corrector / stream payload analytics rejects).
// 3. DayCalculationState (lib/compute/day_calculation_state.dart):
//      NightResumePart? exportNight()     null when no beats are folded
//      void seedNight(NightResumePart? part)
//        arms the part; it is ADOPTED by the next nightRr call only if the
//        slice has n >= tag.count, slice[0] ts == tag.startTsMs and
//        nightBeatsFingerprint(slice, tag.count) == tag.fingerprint; otherwise
//        it is dropped and that call rebuilds (nightRebuilds becomes 1 as for
//        a fresh state). An adopted part counts as NO rebuild and NO restart
//        (nightRebuilds stays 0, nightSpectralRestarts stays 0) and its beats
//        are not "processed" again (processedNightBeats counts only new ones);
//        the streams continue (nightSpectralFolded counts only new settled).
//      void seedFrom(DayResumeState)     also calls seedNight(resume.night)
//      NightFoldTag? get nightFoldTag    (count, fingerprint) of what is folded
//      int get nightRetainedInputBeats   input beats kept as COPIES for the
//        extension check. The same (count, fingerprint) rule serves the RAM and
//        the restored path, so this is always 0. (64-bit collision ~1e-19,
//        owner-accepted.)
// 4. DayResumeState (lib/compute/day_resume_state.dart), both NON-final fields,
//    both default null:
//      NightResumePart? night
//      ana.CardioRowCache? cardioRows          (ana = openstrap_analytics/onehz)
//    Constructor takes `night:` and `cardioRows:`.
//    ana.CardioRowCache restrictCardioRows(ana.CardioRowCache all,
//        {required int loSec, required int hiSec})   (lo inclusive, hi exclusive
//        on the row key's startSec): what the engine stores for a day's window.
//    Blob layout: after `curves`, two sections, night first then rows, each
//        u8 present | (if 1) i32 byteLength | payload
//      payload (UTF-8) is exactly jsonEncode(part.toJson()) for the night and
//      jsonEncode(rows.toJson()) for the rows. The whole-blob checksum still
//      covers everything. A section that fails to decode (FormatException, bad
//      JSON, tag disagreeing with its own content) yields night == null /
//      cardioRows == null while the day part decodes unchanged: dropped, the
//      night rebuilds / the rows recompute, never wrong output. Damage to the
//      day part or the checksum is still `decodeDayResumeState == null`.
// 5. foldDayCheckpoint (the @heavy worker entry) gains optional
//      NightResumePart? night, ana.CardioRowCache? cardioRows
//    which REPLACE the base's (null drops them, like `bills`). Encoding and
//    decoding therefore stay in the worker; the UI isolate hands plain data.
// 6. kDayCheckpointFmt = 5. A fmt-4 blob: decodeDayResumeState null and
//    decideResume reason 'fmt' (full pass). fmt 5 is accepted.
//
// All of these fail today on missing members / the fmt constant only.
//
// AMENDED by the isolate fix (AGENTS.md 3.10): the UI isolate holds the night
// part and the cardio rows ONLY as their encoded UTF-8 JSON text. So
// DayResumeState carries `Uint8List? nightJson` / `cardioRowsJson` (the section
// payloads as stored, never parsed), foldDayCheckpoint takes `nightJson` and the
// encoded `cardioRowChunks` (+ the window to cut them to) and encodes in the
// worker, and a damaged section is found where it is READ (the adopting worker
// rebuilds the night / recomputes the rows), not by the blob decoder. The
// helpers below turn the stored text back into objects for the assertions.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_analytics/onehz.dart' show CalculationMode, RrCorrector;
import 'package:openstrap_edge/compute/cardio_rows_blob.dart';
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/night_resume_part.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/resume_bytes.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/incremental_day_fixture.dart';

// ── helpers ─────────────────────────────────────────────────────────────────

void _expectIdentical(Object? actual, Object? expected, [String path = r'$']) {
  if (expected is double && actual is double) {
    final same = expected.isNaN
        ? actual.isNaN
        : (actual == expected && actual.isNegative == expected.isNegative);
    expect(same, isTrue, reason: '$path: $actual != $expected');
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    final a = actual as Map;
    expect(a.keys.toSet(), expected.keys.toSet(), reason: '$path keys');
    for (final k in expected.keys) {
      _expectIdentical(a[k], expected[k], '$path.$k');
    }
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    final a = actual as List;
    expect(a.length, expected.length, reason: '$path length');
    for (var i = 0; i < expected.length; i++) {
      _expectIdentical(a[i], expected[i], '$path[$i]');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

List<double> _dbls(Object? v) => [for (final x in v as List) (x as num).toDouble()];

Map<String, dynamic> _upTo(Map<String, dynamic> full, int beats) {
  final d = copyDay(full);
  d['sleep_rr_ms'] = (d['sleep_rr_ms'] as List).take(beats).toList();
  d['sleep_rr_ts_ms'] = (d['sleep_rr_ts_ms'] as List).take(beats).toList();
  return d;
}

Map<String, dynamic> _withSlice(
  Map<String, dynamic> base,
  List<double> rr,
  List<double> ts,
) {
  final d = copyDay(base);
  d['sleep_rr_ms'] = rr;
  d['sleep_rr_ts_ms'] = ts;
  return d;
}

({List<double> rr, List<double> ts}) _beats(Map<String, dynamic> d) =>
    (rr: _dbls(d['sleep_rr_ms']), ts: _dbls(d['sleep_rr_ts_ms']));

int _settledOf(List<double> rr, List<double> ts) =>
    RrCorrector().fold(rr, tsMs: ts).nn.length;

const _mode = CalculationMode.heavy;

/// The bundle a stateless batch pass gives: the oracle for every comparison.
Map<String, dynamic> _oracle(Map<String, dynamic> input) =>
    deriveDayBundle(copyDay(input));

void _expectBundle(
  Map<String, dynamic> input,
  DayCalculationState state, {
  String where = '',
}) {
  final got = deriveDayBundle(copyDay(input), state: state, mode: _mode);
  _expectIdentical(got, _oracle(input), where);
}

/// Reference FNV-1a over raw IEEE-754 bits (little-endian), written
/// independently of the implementation.
int _refFingerprint(List<double> rr, List<double> ts, int count) {
  var h = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  final b = ByteData(8);
  for (var i = 0; i < count; i++) {
    for (final v in [rr[i], ts[i]]) {
      b.setFloat64(0, v, Endian.little);
      for (var k = 0; k < 8; k++) {
        h ^= b.getUint8(k);
        h *= prime;
      }
    }
  }
  return h;
}

// A small, valid day part (900 s, 15-minute aligned) for the blob container.
const _t0 = 1800000000; // divisible by 900
Uint8List _blob({
  Uint8List? base,
  int alreadyFolded = 0,
  int n = 900,
  NightResumePart? night,
  ana.CardioRowCache? cardioRows,
}) {
  final lo = alreadyFolded;
  final out = foldDayCheckpoint(
    base: base,
    alreadyFolded: alreadyFolded,
    ts: [for (var i = lo; i < n; i++) _t0 + i],
    hr: [for (var i = lo; i < n; i++) 60 + i % 5],
    ax: [for (var i = lo; i < n; i++) 0.01 * (i % 3)],
    ay: [for (var i = lo; i < n; i++) 0.0],
    az: [for (var i = lo; i < n; i++) 1.0],
    stepCounter: [for (var i = lo; i < n; i++) -1],
    age: 35,
    stepModulus: null,
    throughSec: _t0 + n,
    nightJson: night == null ? null : _nightBytes(night),
    cardioRowChunks: cardioRows == null ? const [] : [encodeCardioRowsHeavy(cardioRows)],
    cardioRowsLoSec: 0,
    cardioRowsHiSec: 1 << 62,
  );
  expect(out, isNotNull, reason: 'fixture: the day part folds');
  return out!;
}

Uint8List _nightBytes(NightResumePart p) =>
    Uint8List.fromList(utf8.encode(jsonEncode(p.toJson())));

/// The stored night text as an object; null when it cannot be read (what the
/// adopting worker would treat as "rebuild").
NightResumePart? _nightOf(DayResumeState s) {
  final raw = s.nightJson;
  if (raw == null) return null;
  try {
    return NightResumePart.fromJson(
        (jsonDecode(utf8.decode(raw)) as Map).cast<String, dynamic>());
  } catch (_) {
    return null;
  }
}

/// The stored rows text as a cache; null when it cannot be read (what the
/// staging worker would treat as "recompute").
ana.CardioRowCache? _rowsOf(DayResumeState s) {
  final raw = s.cardioRowsJson;
  if (raw == null) return null;
  final rows = mergeCardioRowChunksHeavy([raw]);
  return rows.length == 0 ? null : rows;
}

Uint8List _withFmt(Uint8List blob, int fmt) {
  final out = Uint8List.fromList(blob);
  final d = ByteData.sublistView(out);
  d.setInt32(4, fmt);
  d.setUint32(out.length - 4, checksum32(out, out.length - 4));
  return out;
}

int _indexOf(Uint8List hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var k = 0; k < needle.length; k++) {
      if (hay[i + k] != needle[k]) continue outer;
    }
    return i;
  }
  return -1;
}

/// [blob] with the bytes of [from] replaced by [to] (same length), checksum
/// recomputed, so only that section is damaged.
Uint8List _patch(Uint8List blob, String from, String to) {
  final f = utf8.encode(from), t = utf8.encode(to);
  expect(t.length, f.length);
  final at = _indexOf(blob, f);
  expect(at, greaterThanOrEqualTo(0), reason: 'section payload found in blob');
  final out = Uint8List.fromList(blob)..setRange(at, at + t.length, t);
  ByteData.sublistView(out)
      .setUint32(out.length - 4, checksum32(out, out.length - 4));
  return out;
}

/// A state that has folded the first [n] beats of [full] through the pipeline.
DayCalculationState _folded(Map<String, dynamic> full, int n) {
  final s = DayCalculationState();
  _expectBundle(_upTo(full, n), s, where: 'warm-up n=$n');
  return s;
}

NightResumePart _roundTrip(NightResumePart p) {
  final back = _nightOf(decodeDayResumeState(_blob(night: p))!);
  expect(back, isNotNull, reason: 'a good night part survives the blob');
  return back!;
}

// Cardio rows through the real staging path (same synthetic night as
// test/derive_cardio_row_cache_test.dart).
final DateTime _mid = DateTime(2026, 6, 27);
const String _day = '2026-06-27';
int _h(double hours) =>
    _mid.add(Duration(minutes: (hours * 60).round())).millisecondsSinceEpoch ~/ 1000;

Substrate _build(double from, double to, bool Function(int) asleep) {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  final rrTs = <double>[], rr = <double>[];
  var nextBeatMs = _h(from) * 1000.0;
  for (var t = _h(from); t < _h(to); t++) {
    final s = asleep(t);
    final bpm = s ? 52 + (t % 7) : 80 + (t ~/ 60) % 20 + t % 3;
    ts.add(t);
    hr.add(bpm);
    ax.add(s ? 0.0 : .3 * math.sin(t * .21));
    ay.add(s ? 0.0 : .2 * math.cos(t * .13));
    az.add(s ? 1.0 : 1 + .05 * math.sin(t * .07));
    while (nextBeatMs < (t + 1) * 1000.0) {
      final ibi = 60000.0 / bpm + (s ? 40 : 12) * math.sin(t * (s ? .35 : .9));
      rrTs.add(nextBeatMs);
      rr.add(ibi);
      nextBeatMs += ibi;
    }
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: rrTs,
    rrMs: rr,
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List.filled(ts.length, 1),
    spo2Ir: List.filled(ts.length, 1),
    skinTemp: List.filled(ts.length, 3000),
    skinContact: List.filled(ts.length, 1),
    deviceFamily: 'gen4',
  );
}

bool _night(int t) => t >= _h(-1) && t < _h(6);
bool _twoNights(int t) => _night(t) || (t >= _h(23) && t < _h(30));

String _json(SleepSessionCandidate c) => jsonEncode(c.toJson());

void main() {
  final full = incrementalDay(seed: 42, gaps: true, nightSeconds: 1500);
  final b = _beats(full);
  final total = b.rr.length;

  group('format version', () {
    test('kDayCheckpointFmt is 5; a fmt-4 blob is refused, fmt 5 accepted', () {
      expect(kDayCheckpointFmt, 5);
      final blob = _blob();
      expect(decodeDayResumeState(blob), isNotNull);
      expect(decodeDayResumeState(_withFmt(blob, 4)), isNull,
          reason: 'a layout-4 blob is not read');
      expect(decodeDayResumeState(_withFmt(blob, 5)), isNotNull);
    });

    test('decideResume: stored fmt 4 is a full pass (reason fmt), 5 resumes',
        () {
      DayCheckpoint cp(int fmt) => DayCheckpoint(
            dayId: 'd',
            algoVersion: 1,
            fmt: fmt,
            ctxSig: 's',
            cpRecTs: 900,
            revVec: encodeRevVec(const {}),
            state: Uint8List(0),
            nightRef: null,
            computedAt: 1,
          );
      ResumeDecision decide(int fmt) => decideResume(
          cp: cp(fmt), algoVersion: 1, ctxSig: 's', liveRevs: const {});
      expect(decide(4).reason, 'fmt');
      expect(decide(5).resume, isTrue);
    });
  });

  group('fingerprint and the shared extension rule', () {
    test('nightBeatsFingerprint is FNV-1a over raw IEEE-754 bits', () {
      for (final n in [0, 1, 7, 300, total]) {
        expect(nightBeatsFingerprint(b.rr, b.ts, n), _refFingerprint(b.rr, b.ts, n),
            reason: 'count=$n');
      }
      // Exact bits: one ulp, and a signed zero, are different beats.
      final rr = [...b.rr.take(50)], ts = [...b.ts.take(50)];
      final base = nightBeatsFingerprint(rr, ts, 50);
      rr[10] = rr[10] + 1e-12;
      expect(nightBeatsFingerprint(rr, ts, 50), isNot(base));
      expect(nightBeatsFingerprint([0.0], [1.0], 1),
          isNot(nightBeatsFingerprint([-0.0], [1.0], 1)));
      // Only the first `count` beats count.
      expect(nightBeatsFingerprint(b.rr, b.ts, 40),
          nightBeatsFingerprint(b.rr.take(40).toList(), b.ts.take(40).toList(), 40));
    });

    test('the state reports (start, count, fingerprint) of what it folded', () {
      final s = DayCalculationState();
      expect(s.nightFoldTag, isNull);
      s.nightRr(b.rr.sublist(0, 400), b.ts.sublist(0, 400));
      expect(s.nightFoldTag,
          (startTsMs: b.ts.first, count: 400, fingerprint: _refFingerprint(b.rr, b.ts, 400)));
      s.nightRr(b.rr.sublist(0, 650), b.ts.sublist(0, 650));
      expect(s.nightFoldTag!.count, 650);
      expect(s.nightFoldTag!.fingerprint, _refFingerprint(b.rr, b.ts, 650));
    });

    test('no input beats are retained as copies, however long the night', () {
      final s = DayCalculationState();
      for (final n in [100, 400, total]) {
        s.nightRr(b.rr.sublist(0, n), b.ts.sublist(0, n));
        expect(s.nightRetainedInputBeats, 0, reason: 'n=$n');
      }
      // Still an extension from fresh copies, and a one-ulp edit still is not.
      final rebuilds = s.nightRebuilds;
      s.nightRr([...b.rr], [...b.ts]);
      expect(s.nightRebuilds, rebuilds, reason: 'equal values extend');
      final edited = [...b.rr];
      edited[17] = edited[17] + 1e-12;
      s.nightRr(edited, [...b.ts]);
      expect(s.nightRebuilds, rebuilds + 1, reason: 'one ulp is a different beat');
      expect(s.nightRetainedInputBeats, 0);
    });

    test('a restored state keeps no copies either', () {
      final warm = _folded(full, 500);
      final s = DayCalculationState()..seedNight(_roundTrip(warm.exportNight()!));
      _expectBundle(_upTo(full, 700), s);
      expect(s.nightRetainedInputBeats, 0);
    });
  });

  group('round trip: encode, decode, continue the night', () {
    test('byte-identical to an uninterrupted run, no rebuild, no restart', () {
      final warm = _folded(full, 400);
      final part = warm.exportNight()!;
      expect(part.tag.count, 400);

      final blob = _blob(night: part);
      final decoded = decodeDayResumeState(blob)!;
      expect(_nightOf(decoded), isNotNull);
      expect(_nightOf(decoded)!.tag, part.tag);
      expect(encodeDayResumeState(decoded), blob, reason: 'stable re-encode');

      final restored = DayCalculationState()..seedFrom(decoded);
      final next = _upTo(full, 900);
      final got = deriveDayBundle(copyDay(next), state: restored, mode: _mode);

      final straight = _folded(full, 400);
      final want = deriveDayBundle(copyDay(next), state: straight, mode: _mode);
      _expectIdentical(got, want, 'vs uninterrupted');
      _expectIdentical(got, _oracle(next), 'vs batch');

      expect(restored.nightRebuilds, 0, reason: 'adopted, not rebuilt');
      expect(restored.nightSpectralRestarts, 0, reason: 'streams continued');
      expect(restored.processedNightBeats, 900 - 400,
          reason: 'only the new beats are corrected');
      expect(restored.nightSpectralFolded,
          _settledOf(b.rr.sublist(0, 900), b.ts.sublist(0, 900)) -
              _settledOf(b.rr.sublist(0, 400), b.ts.sublist(0, 400)),
          reason: 'only newly settled beats feed the streams');
      expect(restored.nightFoldTag!.count, 900);
    });

    test('a restart between every pass (random chunks) still equals batch', () {
      final rnd = math.Random(11);
      NightResumePart? carried;
      var n = 0, processed = 0, rebuilds = 0, restarts = 0;
      while (n < total) {
        n = math.min(total, n + 1 + rnd.nextInt(180));
        final s = DayCalculationState()..seedNight(carried);
        _expectBundle(_upTo(full, n), s, where: 'n=$n');
        processed += s.processedNightBeats;
        rebuilds += s.nightRebuilds;
        restarts += s.nightSpectralRestarts;
        carried = _roundTrip(s.exportNight()!);
      }
      expect(processed, total, reason: 'each beat corrected exactly once overall');
      expect(rebuilds, 1, reason: 'only the very first pass builds a corrector');
      expect(restarts, 1);
    });

    test('the part is plain data that survives JSON', () {
      final part = _folded(full, 300).exportNight()!;
      final wire = jsonDecode(jsonEncode(part.toJson())) as Map<String, dynamic>;
      expect(wire['v'], 1);
      expect(part.buildCorrectorHeavy().snapshot().n, 300,
          reason: 'the capped corrector reports its folded count via the API');
      final back = NightResumePart.fromJson(wire);
      expect(back.tag, part.tag);
      final tag = wire['tag'] as Map;
      expect(tag['fp'], part.tag.fingerprint.toString());
    });

    test('foldDayCheckpoint replaces the night part; null drops it', () {
      final part = _folded(full, 400).exportNight()!;
      final withNight = _blob(n: 600, night: part);
      expect(_nightOf(decodeDayResumeState(withNight)!)!.tag, part.tag);

      final part2 = _folded(full, 700).exportNight()!;
      final replaced =
          _blob(base: withNight, alreadyFolded: 600, night: part2);
      expect(_nightOf(decodeDayResumeState(replaced)!)!.tag, part2.tag);
      expect(decodeDayResumeState(replaced)!.folded, 900);

      final dropped = _blob(base: withNight, alreadyFolded: 600);
      expect(_nightOf(decodeDayResumeState(dropped)!), isNull);
    });
  });

  group('the night part is dropped (rebuild), the day part still restores', () {
    final cases = <String,
        ({List<double> rr, List<double> ts}) Function(
            List<double> rr, List<double> ts)>{
      'slice start moved later': (rr, ts) =>
          (rr: rr.sublist(25, 650), ts: ts.sublist(25, 650)),
      'slice start moved earlier': (rr, ts) =>
          (rr: [rr[0] + 1, ...rr.sublist(0, 650)], ts: [ts[0] - 900, ...ts.sublist(0, 650)]),
      'earlier beat value edited': (rr, ts) {
        final r = [...rr.sublist(0, 650)];
        r[17] += 333;
        return (rr: r, ts: ts.sublist(0, 650));
      },
      'earlier beat timestamp edited': (rr, ts) {
        final t = [...ts.sublist(0, 650)];
        t[250] += 5000;
        return (rr: rr.sublist(0, 650), ts: t);
      },
      'last folded beat edited': (rr, ts) {
        final r = [...rr.sublist(0, 650)];
        r[399] += 41;
        return (rr: r, ts: ts.sublist(0, 650));
      },
      'slice shorter than the folded count': (rr, ts) =>
          (rr: rr.sublist(0, 250), ts: ts.sublist(0, 250)),
    };

    for (final c in cases.entries) {
      test(c.key, () {
        final part = _folded(full, 400).exportNight()!;
        final decoded = decodeDayResumeState(_blob(night: part))!;
        expect(decoded.folded, 900, reason: 'the day part restored');

        final slice = c.value(b.rr, b.ts);
        final input = _withSlice(full, slice.rr, slice.ts);
        final s = DayCalculationState()..seedFrom(decoded);
        _expectBundle(input, s, where: c.key);
        expect(s.nightRebuilds, 1, reason: 'the part was refused, not used');
        expect(s.processedNightBeats, slice.rr.length,
            reason: 'the whole slice is folded again');
        expect(s.nightFoldTag!.fingerprint,
            _refFingerprint(slice.rr, slice.ts, slice.rr.length));
      });
    }

    test('a part whose stored fingerprint disagrees with the slice', () {
      final part = _folded(full, 400).exportNight()!;
      final wire = jsonDecode(jsonEncode(part.toJson())) as Map<String, dynamic>;
      (wire['tag'] as Map)['fp'] = (part.tag.fingerprint ^ 1).toString();
      final tampered = NightResumePart.fromJson(wire);

      final s = DayCalculationState()..seedNight(tampered);
      _expectBundle(_upTo(full, 600), s);
      expect(s.nightRebuilds, 1);
      expect(s.processedNightBeats, 600);
    });
  });

  group('malformed night part or rows are dropped, never wrong output', () {
    // Built in setUpAll: _folded calls expect, which may not run at load time.
    late final NightResumePart warmPart;
    late final String partJson;
    setUpAll(() {
      warmPart = _folded(full, 400).exportNight()!;
      partJson = jsonEncode(warmPart.toJson());
    });

    test('fromJson refuses malformed input with FormatException', () {
      Map<String, dynamic> good() =>
          jsonDecode(partJson) as Map<String, dynamic>;
      expect(NightResumePart.fromJson(good()).tag, warmPart.tag);
      final bad = <Map<String, dynamic>>[
        {},
        good()..['v'] = 9,
        good()..['v'] = 'x',
        good()..remove('tag'),
        good()..['tag'] = {'startTsMs': 1.0, 'count': -1, 'fp': '1'},
        good()..['tag'] = {'startTsMs': 1.0, 'count': 3, 'fp': 'nope'},
      ];
      for (final j in bad) {
        expect(() => NightResumePart.fromJson(j), throwsFormatException,
            reason: jsonEncode(j).substring(0, math.min(80, jsonEncode(j).length)));
      }
    });

    test('syntax-damaged night section: night null, day part and rows intact',
        () {
      final rows = ana.CardioRowCache();
      prepareSleepSessionCandidate(_build(-2, 7, _night),
          targetDay: _day, rowCache: rows);
      final blob = _blob(night: warmPart, cardioRows: rows);
      final bad = _patch(blob, partJson.substring(0, 8), '~${partJson.substring(1, 8)}');
      final decoded = decodeDayResumeState(bad);
      expect(decoded, isNotNull, reason: 'the day part is fine');
      expect(decoded!.folded, 900);
      expect(_nightOf(decoded), isNull);
      expect(_rowsOf(decoded)?.length, rows.length);

      final s = DayCalculationState()..seedFrom(decoded);
      _expectBundle(_upTo(full, 700), s);
      expect(s.nightRebuilds, 1);
    });

    test('wrong-version night section is dropped the same way', () {
      final blob = _blob(night: warmPart);
      final m = jsonDecode(partJson) as Map<String, dynamic>..['v'] = 7;
      final bad = _patch(blob, partJson, jsonEncode(m));
      final decoded = decodeDayResumeState(bad)!;
      expect(_nightOf(decoded), isNull);
      expect(decoded.folded, 900);
    });

    test('damaged rows section: rows null, night and day part intact, rows '
        'recompute to the same output', () {
      final sub = _build(-2, 7, _night);
      final plain = prepareSleepSessionCandidate(sub, targetDay: _day);
      final rows = ana.CardioRowCache();
      prepareSleepSessionCandidate(sub, targetDay: _day, rowCache: rows);
      final rowsJson = jsonEncode(rows.toJson());
      final blob = _blob(night: warmPart, cardioRows: rows);

      final m = jsonDecode(rowsJson) as Map<String, dynamic>..['version'] = 7;
      for (final bad in [
        // 30 chars: the first 8 ('{"versio') also occur in the day part's corrector JSON.
        _patch(blob, rowsJson.substring(0, 30), '~${rowsJson.substring(1, 30)}'),
        _patch(blob, rowsJson, jsonEncode(m)),
      ]) {
        final decoded = decodeDayResumeState(bad)!;
        expect(_rowsOf(decoded), isNull);
        expect(_nightOf(decoded)?.tag, warmPart.tag,
            reason: 'night section is whole');
        expect(decoded.folded, 900);
        final cache = _rowsOf(decoded) ?? ana.CardioRowCache();
        final got = prepareSleepSessionCandidate(sub,
            targetDay: _day, rowCache: cache);
        expect(_json(got), _json(plain));
        expect(cache.misses, greaterThan(0), reason: 'recomputed');
      }
    });

    test('damage to the day part or the checksum is still null', () {
      final blob = _blob(night: warmPart);
      final bad = Uint8List.fromList(blob)..[40] ^= 0x10;
      expect(decodeDayResumeState(bad), isNull);
      expect(decodeDayResumeState(Uint8List.sublistView(blob, 0, blob.length - 3)),
          isNull);
    });
  });

  group('optional suffix: the day part does not depend on it', () {
    test('absent, night only, rows only and both decode the same day part', () {
      final part = _folded(full, 400).exportNight()!;
      final rows = ana.CardioRowCache();
      prepareSleepSessionCandidate(_build(-2, 7, _night),
          targetDay: _day, rowCache: rows);

      final bare = _blob();
      final bareDecoded = decodeDayResumeState(bare)!;
      expect(bareDecoded.nightJson, isNull);
      expect(bareDecoded.cardioRowsJson, isNull);
      for (final blob in [
        _blob(night: part),
        _blob(cardioRows: rows),
        _blob(night: part, cardioRows: rows),
      ]) {
        final d = decodeDayResumeState(blob)!;
        expect(d.folded, bareDecoded.folded);
        d
          ..nightJson = null
          ..cardioRowsJson = null;
        expect(encodeDayResumeState(d), bare,
            reason: 'with the suffix removed, the bytes are the bare blob');
      }
    });

    test('a hand-built state carries both through encode and decode', () {
      final part = _folded(full, 400).exportNight()!;
      final rows = ana.CardioRowCache();
      prepareSleepSessionCandidate(_build(-2, 7, _night),
          targetDay: _day, rowCache: rows);
      final s = DayResumeState(
          nightJson: _nightBytes(part), cardioRowsJson: encodeCardioRowsHeavy(rows));
      final back = decodeDayResumeState(encodeDayResumeState(s))!;
      expect(_nightOf(back)!.tag, part.tag);
      expect(jsonEncode(_rowsOf(back)!.toJson()), jsonEncode(rows.toJson()));
    });
  });

  group('cardio rows ride the checkpoint', () {
    test('restored rows give hits, no misses, and the same candidate', () {
      final sub = _build(-2, 7, _night);
      final plain = prepareSleepSessionCandidate(sub, targetDay: _day);
      expect(plain.present, isTrue, reason: 'guard: the fixture stages a night');

      final warm = ana.CardioRowCache();
      prepareSleepSessionCandidate(sub, targetDay: _day, rowCache: warm);
      expect(warm.length, greaterThan(0));

      final decoded = decodeDayResumeState(_blob(cardioRows: warm))!;
      final rows = _rowsOf(decoded)!;
      expect(rows.length, warm.length);
      final got = prepareSleepSessionCandidate(sub, targetDay: _day, rowCache: rows);
      expect(_json(got), _json(plain));
      expect(rows.hits, greaterThan(0));
      expect(rows.misses, 0, reason: 'every row was restored');
    });

    test('restrictCardioRows keeps the window [lo, hi) of startSec only', () {
      final sub = _build(-2, 31, _twoNights);
      final all = ana.CardioRowCache();
      prepareSleepSessionCandidate(sub, targetDay: _day, rowCache: all);
      prepareSleepSessionCandidate(sub, targetDay: '2026-06-28', rowCache: all);

      List<int> starts(ana.CardioRowCache c) => [
            for (final r in (c.toJson()['rows'] as List))
              (r as Map)['startSec'] as int
          ];
      final all0 = starts(all)..sort();
      final lo = _h(0), hi = _h(24);
      final cut = restrictCardioRows(all, loSec: lo, hiSec: hi);
      final kept = starts(cut);
      expect(kept, isNotEmpty);
      expect(kept.length, lessThan(all0.length), reason: 'something was outside');
      expect(kept.every((s) => s >= lo && s < hi), isTrue);
      expect(kept.length, all0.where((s) => s >= lo && s < hi).length);
      expect(starts(all).length, all0.length, reason: 'the source is untouched');
    });
  });
}
