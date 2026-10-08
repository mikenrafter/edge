// Accelerometer archive options (RED): the owner narrowed the lossy DCT to hr
// and skin temperature. ax/ay/az get either
//   (a) SampleMode.losslessAtQuantum - delta + deflate, exact relative to the
//       0.004 g quantum recorded in the header, or
//   (b) SampleMode.pyramidOnly - the validity mask and the TRUE summary
//       pyramid (count/min/mean/max per level), no samples at all,
// behind a per-signal choice (SampleArchiver.defaultModes / modes: param).
// All round-2 guarantees (parts, per-device, coverage union) must keep holding.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sample_archive.dart';
import 'package:openstrap_edge/data/sample_codec.dart';
import 'package:openstrap_edge/data/sample_progressive.dart';

import '../support/sample_fixtures.dart';

const _q = 0.004;
const _lossless = SampleMode.losslessAtQuantum;
const _pyr = SampleMode.pyramidOnly;
const _day1 = '2026-10-03';
const _now = 1791000000;

Uint8List _enc(String s, List<double?> v, SampleMode m) =>
    SampleCodec.encode(s, v, mode: m).blob;

double _snap(double v) => (v / _q).round() * _q;

void main() {
  late int d1;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    d1 = localDayStartSec(_day1)!;
  });
  tearDownAll(() async => LocalDb.close());

  group('losslessAtQuantum', () {
    test('every valid slot decodes to EXACTLY round(v/q)*q; nulls stay null; '
        'header names the mode and the quantum', () {
      for (final axis in [0, 1, 2]) {
        final s = withGaps(correlatedAccel(axis), 30 + axis);
        final e = SampleCodec.encode('ax', s, mode: _lossless);
        final d = SampleCodec.decode(e.blob);
        expect(d.length, s.length);
        for (var i = 0; i < s.length; i++) {
          if (s[i] == null) {
            expect(d[i], isNull, reason: 'slot $i');
          } else {
            expect(d[i], _snap(s[i]!), reason: 'slot $i');
          }
        }
        final h = SampleCodec.readHeader(e.blob);
        expect(h.mode, _lossless);
        expect(h.quantum, _q);
        expect(h.segmentCount, 0);
        expect(SampleCodec.segments(e.blob), isEmpty);
        expect(e.stats.coefficientCount, 0);
        expect(e.stats.maxErr, lessThanOrEqualTo(_q / 2 + 1e-12));
      }
    });

    test('white noise, gaps at block edges, DST lengths, all-null, one '
        'sample: always exact', () {
      final noise = withGaps(whiteNoiseAccel(0), 4);
      final cases = <List<double?>>[
        noise,
        List<double?>.filled(500, null),
        List<double?>.filled(1000, null)..[0] = 0.5,
        List<double?>.filled(1000, null)..[999] = -1.2,
        List<double?>.generate(82800, (t) => t % 997 < 5 ? null : 0.3),
        List<double?>.generate(90000, (t) => t.isEven ? 1.0 : null),
      ];
      for (final s in cases) {
        final d = SampleCodec.decode(_enc('ax', s, _lossless));
        expect(d.length, s.length);
        for (var i = 0; i < s.length; i++) {
          expect(d[i], s[i] == null ? isNull : _snap(s[i]!), reason: 'slot $i');
        }
      }
    });

    test('deterministic across calls and isolates', () async {
      final s = withGaps(correlatedAccel(1), 7);
      final a = _enc('ay', s, _lossless);
      expect(_enc('ay', List<double?>.of(s), _lossless), a);
      expect(await Isolate.run(() => _enc('ay', s, _lossless)), a);
    });

    test('costs no more than the plain delta+deflate baseline plus its mask '
        'and pyramid (the reference figure for "accel lossless")', () {
      final s = withGaps(correlatedAccel(0), 31);
      final e = SampleCodec.encode('ax', s, mode: _lossless);
      final payload = e.stats.bytes - e.stats.summaryBytes;
      expect(payload, lessThanOrEqualTo((losslessBytes(s, _q) * 1.05).ceil() + 64));
    });

    test('the pyramid is the same raw pyramid the lossy codec stores', () {
      final s = withGaps(correlatedAccel(2), 9);
      List<(int, double?, double?, double?)> flat(Uint8List b) => [
            for (final l in SampleCodec.summary(b))
              for (final c in l.cells) (c.count, c.min, c.mean, c.max)
          ];
      expect(flat(_enc('az', s, _lossless)),
          flat(_enc('az', s, SampleMode.adaptive)));
    });

    test('decodeCoarse and progressive degrade to the one exact step', () {
      final blob = _enc('ax', withGaps(correlatedAccel(0), 3), _lossless);
      expect(SampleCodec.decodeCoarse(blob, maxOrder: 0),
          SampleCodec.decode(blob));
      final steps = SampleCodec.progressive(blob).toList();
      expect(steps, hasLength(1));
      expect(steps.single.isFull, isTrue);
      expect(steps.single.samples, SampleCodec.decode(blob));
    });

    test('truncated or corrupted lossless blobs are FormatException', () {
      final blob = _enc('ax', withGaps(correlatedAccel(0), 3), _lossless);
      expect(() => SampleCodec.decode(Uint8List.sublistView(blob, 0, blob.length ~/ 2)),
          throwsA(isA<FormatException>()));
      final bad = Uint8List.fromList(blob)..[blob.length - 3] ^= 0xff;
      expect(() => SampleCodec.decode(bad), throwsA(anything));
    });
  });

  group('pyramidOnly', () {
    test('no samples: decode refuses, hasSamples is false, mask is exact, '
        'header names the mode', () {
      final s = withGaps(correlatedAccel(0), 31);
      final blob = _enc('ax', s, _pyr);
      expect(SampleCodec.hasSamples(blob), isFalse);
      expect(SampleCodec.hasSamples(_enc('ax', s, _lossless)), isTrue);
      expect(SampleCodec.hasSamples(_enc('hr', [70.0], SampleMode.adaptive)),
          isTrue);
      expect(() => SampleCodec.decode(blob), throwsA(isA<FormatException>()));
      expect(() => SampleCodec.decodeCoarse(blob, maxOrder: 3),
          throwsA(isA<FormatException>()));
      expect(SampleCodec.readHeader(blob).mode, _pyr);
      expect(SampleCodec.segments(blob), isEmpty);
      final runs = SampleCodec.validRuns(blob);
      final covered = List<bool>.filled(s.length, false);
      for (final (a, b) in runs) {
        for (var i = a; i < b; i++) {
          covered[i] = true;
        }
      }
      for (var i = 0; i < s.length; i++) {
        expect(covered[i], s[i] != null, reason: 'slot $i');
      }
    });

    test('the pyramid is TRUE raw count/min/mean/max (min/max exact at the '
        'quantum, mean within q/2), gaps count 0 with no stats', () {
      final s = withGaps(correlatedAccel(1), 12);
      final lv = SampleCodec.summary(_enc('ay', s, _pyr));
      expect(lv.map((l) => l.cellSeconds), [60, 900, 3600, s.length]);
      for (final l in lv) {
        for (var i = 0; i < l.cells.length; i++) {
          final from = i * l.cellSeconds;
          final to = math.min(s.length, from + l.cellSeconds);
          final v = [for (var k = from; k < to; k++) if (s[k] != null) s[k]!];
          final c = l.cells[i];
          expect(c.count, v.length);
          if (v.isEmpty) {
            expect([c.min, c.mean, c.max], [null, null, null]);
            continue;
          }
          expect(c.min, closeTo(v.reduce(math.min), _q / 2 + 1e-9));
          expect(c.max, closeTo(v.reduce(math.max), _q / 2 + 1e-9));
          expect(c.mean, closeTo(v.reduce((a, b) => a + b) / v.length, _q / 2 + 1e-9));
        }
      }
    });

    test('tiny: far smaller than the lossless blob, and bounded', () {
      final s = withGaps(correlatedAccel(0), 31);
      final p = SampleCodec.encode('ax', s, mode: _pyr);
      final l = SampleCodec.encode('ax', s, mode: _lossless);
      expect(p.stats.bytes, lessThan(l.stats.bytes ~/ 5));
      expect(p.stats.bytes, lessThanOrEqualTo(8 * 1024));
      expect(p.stats.coefficientCount, 0);
      expect(p.stats.segmentCount, 0);
      expect(p.stats.nValid, validCount(s));
      expect(p.stats.rmsErr, 0, reason: 'no reconstruction, no error');
    });

    test('all-null and empty inputs encode', () {
      for (final n in [0, 1, 500]) {
        final blob = _enc('ax', List<double?>.filled(n, null), _pyr);
        expect(SampleCodec.readHeader(blob).nValid, 0);
        expect(SampleCodec.hasSamples(blob), isFalse);
      }
    });
  });

  group('SampleDetail: lossless parts carry no approximation label', () {
    test('exact vs approximate', () {
      final blob = _enc('ax', withGaps(correlatedAccel(0), 3), _lossless);
      final full = SampleCodec.progressive(blob).last;
      final exact = SampleDetail.of(full, exact: true);
      expect(exact.isApproximation, isFalse);
      expect(exact.labelKey, isNull);
      expect(exact.isLoadingDetail, isFalse);
      final i = full.samples.indexWhere((e) => e != null);
      expect(exact.readout(i), full.samples[i]);
      final lossy = SampleDetail.of(full);
      expect(lossy.isApproximation, isTrue);
      expect(lossy.labelKey, 'sampleArchiveApproximation');
    });
  });

  group('archiver: per-signal choice', () {
    Future<void> freshDb(String name) async {
      await LocalDb.close();
      LocalDb.dbName = name;
      await databaseFactory.deleteDatabase(
          p.join(await databaseFactory.getDatabasesPath(), name));
    }

    Future<void> seed(int from, int to,
        {String device = '', double ax = 0.5, bool ramp = true}) async {
      final db = await LocalDb.instance;
      final b = db.batch();
      for (var i = from; i < to; i++) {
        b.insert('decoded_onehz', {
          'device_id': device,
          'ts_ms': (d1 + i) * 1000,
          'rec_ts': d1 + i,
          'counter': d1 + i,
          'hr': 60 + i % 30,
          'ax': ax + (ramp ? (i % 25) * 0.004 : 0),
          'ay': -0.25,
          'az': 0.9,
          'skin_temp_c': 33.0 + (i % 10) * 0.01,
        });
      }
      await b.commit(noResult: true);
    }

    test('defaults: hr and skin temperature are quantized; the three accel '
        'axes share one non-DCT mode', () {
      expect(SampleArchiver.defaultModes['hr'], SampleMode.quantized);
      expect(SampleArchiver.defaultModes['skin_temp_c'], SampleMode.quantized);
      final a = {
        for (final s in ['ax', 'ay', 'az']) SampleArchiver.defaultModes[s]
      };
      expect(a, hasLength(1));
      // Recommended default from the real-data numbers (see the report):
      // pyramid-only costs ~15 KB/day for all three axes against ~170 KB/day
      // lossless, and the samples feed nothing.
      expect(a.single, _pyr);
      expect(SampleArchiver.defaultModes.keys.toSet(),
          SampleArchiver.signals.toSet());
    });

    test('lossless accel: parts are exact, isExact, no approximation; hr '
        'stays lossy and approximate', () async {
      await freshDb('sample_accel1.db');
      await seed(0, 400);
      await SampleArchiver.archiveDay(_day1,
          nowSec: _now, modes: {...SampleArchiver.defaultModes, 'ax': _lossless, 'ay': _lossless, 'az': _lossless});
      final rows = await SampleArchiver.rows(_day1);
      expect(rows.where((r) => r.signal == 'ax').single.mode, _lossless);
      expect(rows.where((r) => r.signal == 'hr').single.mode, SampleMode.quantized);
      final r = (await SampleArchiver.reconstruct(_day1, 'ax'))!;
      for (var i = 0; i < 400; i++) {
        expect(r[i], _snap(0.5 + (i % 25) * 0.004), reason: 'slot $i');
      }
      expect(r[400], isNull);
      expect(await SampleArchiver.isExact(_day1, 'ax'), isTrue);
      expect(await SampleArchiver.isExact(_day1, 'hr'), isFalse);
      expect(rows.firstWhere((x) => x.signal == 'ax').maxErr,
          lessThanOrEqualTo(_q / 2 + 1e-12));
    });

    test('pyramid-only accel: no samples (reconstruct null, not exact), true '
        'summary present, coverage still dedupes the next pass', () async {
      await freshDb('sample_accel2.db');
      await seed(0, 600);
      final modes = {...SampleArchiver.defaultModes, 'ax': _pyr, 'ay': _pyr, 'az': _pyr};
      await SampleArchiver.archiveDay(_day1, nowSec: _now, modes: modes);
      expect(await SampleArchiver.reconstruct(_day1, 'ax'), isNull);
      expect(await SampleArchiver.isExact(_day1, 'ax'), isFalse);
      final lv = (await SampleArchiver.summary(_day1, 'ay'))!;
      expect(lv.last.cells.single.count, 600);
      expect(lv.last.cells.single.min, closeTo(-0.25, _q));
      final row = (await SampleArchiver.rows(_day1)).firstWhere((r) => r.signal == 'ax');
      expect(row.mode, _pyr);
      expect(row.rmsErr, 0);
      expect(row.maxErr, 0);
      expect(await SampleArchiver.archiveDay(_day1, nowSec: _now + 1, modes: modes), 0,
          reason: 'nothing new anywhere: nothing written');
      await seed(600, 650);
      expect(await SampleArchiver.archiveDay(_day1, nowSec: _now + 2, modes: modes), 5,
          reason: 'one new part per signal that has new slots');
      final lv2 = (await SampleArchiver.summary(_day1, 'ay'))!;
      expect(lv2.last.cells.single.count, 650);
      expect((await SampleArchiver.status(_day1)).single.outcome, 'ok');
    });

    test('round-2 guarantees hold for lossless parts: partial prune then '
        'backfill loses no slot; devices stay separate', () async {
      await freshDb('sample_accel3.db');
      final modes = {...SampleArchiver.defaultModes, 'ax': _lossless};
      await seed(0, 100);
      await seed(0, 100, device: 'oura-x', ax: 1.5, ramp: false);
      await SampleArchiver.archiveDay(_day1, nowSec: _now, modes: modes);
      final db = await LocalDb.instance;
      await db.delete('decoded_onehz', where: 'rec_ts < ?', whereArgs: [d1 + 50]);
      await seed(100, 151);
      await SampleArchiver.archiveDay(_day1, nowSec: _now + 1, modes: modes);
      final r = (await SampleArchiver.reconstruct(_day1, 'ax'))!;
      for (var i = 0; i < 151; i++) {
        expect(r[i], _snap(0.5 + (i % 25) * 0.004), reason: 'slot $i');
      }
      final o = (await SampleArchiver.reconstruct(_day1, 'ax', deviceId: 'oura-x'))!;
      expect(o[10], _snap(1.5));
      expect(o[120], isNull);
    });

    test('a signal whose mode changes between passes keeps both parts: a '
        'pyramid-only part is summary-only, the later lossless part has '
        'samples for ITS slots, the summary counts the union', () async {
      await freshDb('sample_accel4.db');
      await seed(0, 200);
      await SampleArchiver.archiveDay(_day1,
          nowSec: _now, modes: {...SampleArchiver.defaultModes, 'ax': _pyr});
      await seed(200, 260);
      await SampleArchiver.archiveDay(_day1,
          nowSec: _now + 1,
          modes: {...SampleArchiver.defaultModes, 'ax': _lossless});
      final r = (await SampleArchiver.reconstruct(_day1, 'ax'))!;
      expect(r[100], isNull, reason: 'the pyramid-only slots have no samples');
      expect(r[230], _snap(0.5 + (230 % 25) * 0.004));
      expect((await SampleArchiver.summary(_day1, 'ax'))!.last.cells.single.count,
          260);
      expect(await SampleArchiver.isExact(_day1, 'ax'), isTrue,
          reason: 'every part that carries samples is lossless');
    });
  });
}
