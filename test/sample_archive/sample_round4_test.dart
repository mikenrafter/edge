// Sample archive, review round 4 (RED).
//
//   P1 import      restoring a backup whose parts were accumulated
//                  independently must never overwrite a local part, lose a
//                  slot, or double-count: coverage-aware reconciliation
//   P1 time zone   a part stores its absolute origin; coverage and overlay
//                  reconcile by absolute timestamp (Denver -> New York)
//
// Fixed dates, injected zone seam (SampleZone.fixedOffset), nowSec injected.
// Real sqflite_ffi, real codec blobs.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sample_archive.dart';
import 'package:openstrap_edge/data/sample_codec.dart';

const _day = '2026-10-03';
const _now = 1791000000;
const _q = 0.004;

late int _d0; // local (UTC in tests) midnight of _day

double _hr(int i) => 80.0 + (i % 7);

List<double?> _series(int from, int to, double Function(int) f,
        {int length = 86400}) =>
    [for (var i = 0; i < length; i++) (i >= from && i < to) ? f(i) : null];

Uint8List _blob(String sig, int from, int to, double Function(int) f,
        {SampleMode mode = SampleMode.adaptive}) =>
    SampleCodec.encode(sig, _series(from, to, f), mode: mode).blob;

Future<void> _freshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory
      .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
}

Future<void> _seed(int from, int to,
    {String device = '', double Function(int)? hr, double? ax}) async {
  final db = await LocalDb.instance;
  final b = db.batch();
  for (var i = from; i < to; i++) {
    b.insert('decoded_onehz', {
      'device_id': device,
      'ts_ms': (_d0 + i) * 1000,
      'rec_ts': _d0 + i,
      'counter': _d0 + i,
      'hr': (hr ?? _hr)(i).round(),
      'ax': ax,
    });
  }
  await b.commit(noResult: true);
}

/// A backup file holding [rows] in the CURRENT spectral_archive shape (or the
/// 67 shape when [legacy]).
Future<String> _source(List<Map<String, Object?>> rows,
    {bool legacy = false, String name = 'sample4_src.db'}) async {
  final path = p.join(await databaseFactory.getDatabasesPath(), name);
  await databaseFactory.deleteDatabase(path);
  final src = await databaseFactory.openDatabase(path);
  await src.execute('CREATE TABLE spectral_archive ('
      "day_id TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT '', "
      'signal TEXT NOT NULL, codec_version INTEGER NOT NULL, '
      'part INTEGER NOT NULL DEFAULT 0, blob BLOB NOT NULL, '
      'n_valid INTEGER NOT NULL, rms_err REAL NOT NULL, '
      'max_err REAL NOT NULL, created_at INTEGER NOT NULL, '
      '${legacy ? '' : 'origin_sec INTEGER, n_slots INTEGER, '
          'slot_sec INTEGER NOT NULL DEFAULT 1, '}'
      'PRIMARY KEY (day_id, device_id, signal, codec_version, part))');
  for (final r in rows) {
    final m = <String, Object?>{};
    for (final e in r.entries) {
      if (legacy && const {'origin_sec', 'n_slots', 'slot_sec'}.contains(e.key)) {
        continue;
      }
      m[e.key] = e.value;
    }
    await src.insert('spectral_archive', m);
  }
  await src.close();
  return path;
}

Map<String, Object?> _row(Uint8List blob,
        {String signal = 'hr',
        String device = '',
        int part = 0,
        int nValid = 100,
        double rms = 0.5,
        double max = 2.0,
        int? origin}) =>
    {
      'day_id': _day,
      'device_id': device,
      'signal': signal,
      'codec_version': SampleCodec.codecVersion,
      'part': part,
      'blob': blob,
      'n_valid': nValid,
      'rms_err': rms,
      'max_err': max,
      'created_at': 5,
      'origin_sec': origin ?? _d0,
      'n_slots': 86400,
      'slot_sec': 1,
    };

int _validCount(List<double?>? r) => r == null ? 0 : r.where((e) => e != null).length;

/// Parts of the day are pairwise disjoint in absolute time.
Future<void> _expectDisjoint(String signal, {String device = ''}) async {
  final db = await LocalDb.instance;
  final seen = <int>{};
  for (final r in await db.query('spectral_archive',
      where: 'day_id = ? AND device_id = ? AND signal = ?',
      whereArgs: [_day, device, signal])) {
    final o = r['origin_sec'] as int;
    for (final (a, b)
        in SampleCodec.validRuns(Uint8List.fromList((r['blob'] as List).cast<int>()))) {
      for (var i = a; i < b; i++) {
        expect(seen.add(o + i), isTrue, reason: 'second ${o + i} archived twice');
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _d0 = localDayStartSec(_day)!;
  });
  tearDownAll(() async => LocalDb.close());
  tearDown(() => SampleArchiver.zone = SampleZone.local);

  group('codec: restrict (carve a part at 60 s cell granularity)', () {
    test('lossless: kept slots identical to the original, dropped cells '
        'removed, pyramid cells are the original TRUE cells', () {
      double f(int i) => 0.2 + (i % 13) * _q;
      final blob = _blob('ax', 30, 400, f, mode: SampleMode.losslessAtQuantum);
      final out = SampleCodec.restrict(blob, (m) => m >= 2 && m != 4)!;
      final d = SampleCodec.decode(out.blob);
      final o = SampleCodec.decode(blob);
      for (var i = 0; i < d.length; i++) {
        final keep = i >= 30 && i < 400 && (i ~/ 60) >= 2 && (i ~/ 60) != 4;
        expect(d[i], keep ? o[i] : isNull, reason: 'slot $i');
      }
      expect(SampleCodec.readHeader(out.blob).mode, SampleMode.losslessAtQuantum);
      final a = SampleCodec.summary(blob).first.cells;
      final b = SampleCodec.summary(out.blob).first.cells;
      for (var j = 0; j < a.length; j++) {
        final kept = j >= 2 && j != 4 && a[j].count > 0;
        expect(b[j].count, kept ? a[j].count : 0, reason: 'cell $j');
        if (kept) {
          expect([b[j].min, b[j].mean, b[j].max], [a[j].min, a[j].mean, a[j].max]);
        }
      }
      expect(SampleCodec.summary(out.blob).last.cells.single.count,
          _validCount(d));
    });

    test('pyramid-only: still no samples, mask and cells carved', () {
      final blob = _blob('ay', 0, 600, (i) => 0.1 * (i % 5), mode: SampleMode.pyramidOnly);
      final out = SampleCodec.restrict(blob, (m) => m < 3)!;
      expect(SampleCodec.hasSamples(out.blob), isFalse);
      expect(SampleCodec.readHeader(out.blob).nValid, 180);
      expect(SampleCodec.summary(out.blob).last.cells.single.count, 180);
    });

    test('lossy: kept samples are the original reconstruction re-encoded '
        '(within the bound of that), the pyramid stays the original RAW '
        'cells, nothing kept -> null', () {
      final raw = _series(0, 900, _hr);
      final blob = SampleCodec.encode('hr', raw).blob;
      final out = SampleCodec.restrict(blob, (m) => m >= 5 && m < 10)!;
      final d = SampleCodec.decode(out.blob);
      final o = SampleCodec.decode(blob);
      for (var i = 0; i < 900; i++) {
        final keep = i >= 300 && i < 600;
        if (!keep) {
          expect(d[i], isNull);
        } else {
          expect((d[i]! - o[i]!).abs(), lessThanOrEqualTo(3.0), reason: 'slot $i');
        }
      }
      final a = SampleCodec.summary(blob).first.cells;
      final b = SampleCodec.summary(out.blob).first.cells;
      for (var j = 5; j < 10; j++) {
        expect([b[j].count, b[j].min, b[j].max], [a[j].count, a[j].min, a[j].max]);
      }
      expect(SampleCodec.restrict(blob, (_) => false), isNull);
    });
  });

  group('codec: mergeSummaries (absolute grid, no double counting)', () {
    test('same origin, disjoint slots inside the same minute: counts add, '
        'min/max are extremes, mean count-weighted', () {
      final a = SampleCodec.summary(_blob('hr', 0, 30, (_) => 70, mode: SampleMode.pyramidOnly));
      final b = SampleCodec.summary(_blob('hr', 30, 60, (_) => 90, mode: SampleMode.pyramidOnly));
      final m = SampleCodec.mergeSummaries([
        SamplePartSummary(_d0, a),
        SamplePartSummary(_d0, b),
      ]);
      final c = m.first.cells.first;
      expect(c.count, 60);
      expect(c.min, 70);
      expect(c.max, 90);
      expect(c.mean, closeTo(80, 0.25));
      expect(m.last.cells.single.count, 60);
      expect(m.map((l) => l.cellSeconds).toList().sublist(0, 3), [60, 900, 3600]);
    });

    test('shifted origins land on one absolute grid anchored at the earliest '
        'origin; the whole-series cell spans both', () {
      final a = SampleCodec.summary(_blob('hr', 0, 120, (_) => 70, mode: SampleMode.pyramidOnly));
      final b = SampleCodec.summary(_blob('hr', 0, 120, (_) => 90, mode: SampleMode.pyramidOnly));
      // part b starts two hours (7200 s) after part a.
      final m = SampleCodec.mergeSummaries([
        SamplePartSummary(_d0 + 7200, b),
        SamplePartSummary(_d0, a),
      ]);
      expect(m.first.cells[0].mean, 70);
      expect(m.first.cells[120].mean, 90, reason: '7200 s = minute 120');
      expect(m.first.cells[60].count, 0, reason: 'a gap between them stays a gap');
      expect(m.last.cells.single.count, 240);
      expect(m.last.cellSeconds, 7200 + 86400);
    });

    test('a single part passes through unchanged', () {
      final s = SampleCodec.summary(_blob('hr', 0, 500, _hr));
      final m = SampleCodec.mergeSummaries([SamplePartSummary(_d0, s)]);
      expect([for (final l in m) for (final c in l.cells) c.count],
          [for (final l in s) for (final c in l.cells) c.count]);
    });
  });

  group('P1 import: coverage-aware, never overwrites', () {
    // Destination history: part 0 = slots 0-119, part 1 = slots 120-239.
    Future<void> destination() async {
      await _freshDb('sample4_imp.db');
      await _seed(0, 120);
      await SampleArchiver.archiveDay(_day, nowSec: _now);
      await _seed(120, 240);
      await SampleArchiver.archiveDay(_day, nowSec: _now + 1);
    }

    test('the review case: an incoming part inside existing coverage changes '
        'nothing (no overwrite, no overlap, no double count)', () async {
      await destination();
      final before = await SampleArchiver.rows(_day);
      final src = await _source([
        _row(_blob('hr', 50, 150, (i) => 150.0)),
      ]);
      await LocalDb.importFromDbFile(src);
      final after = await SampleArchiver.rows(_day);
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(after[i].blob, before[i].blob);
        expect(after[i].part, before[i].part);
      }
      final r = (await SampleArchiver.reconstruct(_day, 'hr'))!;
      expect(_validCount(r), 240);
      expect((r[60]! - _hr(60)).abs(), lessThanOrEqualTo(3),
          reason: 'the local value stays, not the incoming 150');
      expect((await SampleArchiver.summary(_day, 'hr'))!.last.cells.single.count,
          240);
      await _expectDisjoint('hr');
    });

    test('partial overlap: only the not-yet-covered minute cells come in, '
        'as a NEW part with a fresh local number; both histories survive',
        () async {
      await destination();
      // incoming 180-359 (part number 0 - collides with the local part 0).
      final src = await _source([
        _row(_blob('hr', 180, 360, (i) => 200.0 - (i % 3)), part: 0),
      ]);
      await LocalDb.importFromDbFile(src);
      final rows = (await SampleArchiver.rows(_day)).where((r) => r.signal == 'hr').toList();
      expect(rows.map((r) => r.part).toList(), [0, 1, 2]);
      final r = (await SampleArchiver.reconstruct(_day, 'hr'))!;
      expect(_validCount(r), 360);
      expect((r[200]! - _hr(200)).abs(), lessThanOrEqualTo(3),
          reason: 'covered slot keeps the LOCAL value');
      expect((r[300]! - 198.0).abs(), lessThanOrEqualTo(7),
          reason: 'new slot comes from the backup (second-generation bound)');
      expect((await SampleArchiver.summary(_day, 'hr'))!.last.cells.single.count,
          360);
      await _expectDisjoint('hr');
    });

    test('a disjoint incoming part is inserted VERBATIM under a fresh part '
        'number', () async {
      await destination();
      final blob = _blob('hr', 1000, 1100, _hr);
      final src = await _source([_row(blob, part: 0, nValid: 100)]);
      await LocalDb.importFromDbFile(src);
      final rows = (await SampleArchiver.rows(_day)).where((r) => r.signal == 'hr').toList();
      expect(rows.map((r) => r.part).toList(), [0, 1, 2]);
      expect(rows.last.blob, blob);
      expect(rows.last.originSec, _d0);
      expect(rows.last.nSlots, 86400);
    });

    test('idempotent: importing the same backup twice changes nothing',
        () async {
      await destination();
      final src = await _source([_row(_blob('hr', 180, 360, _hr))]);
      await LocalDb.importFromDbFile(src);
      final once = await SampleArchiver.rows(_day);
      await LocalDb.importFromDbFile(src);
      final twice = await SampleArchiver.rows(_day);
      expect(twice.length, once.length);
      for (var i = 0; i < once.length; i++) {
        expect(twice[i].blob, once[i].blob);
      }
    });

    test('devices stay separate on import', () async {
      await destination();
      final src = await _source([
        _row(_blob('hr', 0, 100, (i) => 150.0), device: 'oura-x'),
      ]);
      await LocalDb.importFromDbFile(src);
      final o = (await SampleArchiver.reconstruct(_day, 'hr', deviceId: 'oura-x'))!;
      expect((o[10]! - 150).abs(), lessThanOrEqualTo(3));
      final prim = (await SampleArchiver.reconstruct(_day, 'hr'))!;
      expect((prim[10]! - _hr(10)).abs(), lessThanOrEqualTo(3));
    });

    test('lossless incoming carve is exact; pyramid-only incoming keeps its '
        'true cells', () async {
      await destination();
      double f(int i) => 0.3 + (i % 11) * _q;
      final lq = _blob('ax', 180, 360, f, mode: SampleMode.losslessAtQuantum);
      final py = _blob('ay', 180, 360, (i) => 0.1 * (i % 4), mode: SampleMode.pyramidOnly);
      final src = await _source([
        _row(lq, signal: 'ax'),
        _row(py, signal: 'ay'),
      ]);
      await LocalDb.importFromDbFile(src);
      final ax = (await SampleArchiver.reconstruct(_day, 'ax'))!;
      expect(_validCount(ax), 180);
      for (var i = 180; i < 360; i++) {
        expect(ax[i], (f(i) / _q).round() * _q, reason: 'slot $i');
      }
      expect((await SampleArchiver.summary(_day, 'ay'))!.last.cells.single.count, 180);
      expect(await SampleArchiver.reconstruct(_day, 'ay'), isNull);
    });

    test('a carved LOSSY part records an honest upper bound: the stored max '
        'error is at least the real error vs the original raw', () async {
      await destination();
      final raw = _series(180, 360, (i) => 100.0 + (i % 5) * 2);
      final blob = SampleCodec.encode('hr', raw).blob;
      final first = SampleCodec.encode('hr', raw).stats;
      final src = await _source([
        _row(blob, rms: first.rmsErr, max: first.maxErr, nValid: 180),
      ]);
      await LocalDb.importFromDbFile(src);
      final carved = (await SampleArchiver.rows(_day))
          .where((r) => r.signal == 'hr' && r.part == 2)
          .single;
      final r = (await SampleArchiver.reconstruct(_day, 'hr'))!;
      var mx = 0.0;
      for (var i = 240; i < 360; i++) {
        mx = (r[i]! - raw[i]!).abs() > mx ? (r[i]! - raw[i]!).abs() : mx;
      }
      expect(carved.maxErr, greaterThanOrEqualTo(mx));
      expect(carved.maxErr, greaterThanOrEqualTo(first.maxErr));
    });

    test('an unreadable incoming blob is skipped, never stored', () async {
      await destination();
      final before = (await SampleArchiver.rows(_day)).length;
      final src = await _source([_row(Uint8List.fromList([9, 8, 7]))]);
      await LocalDb.importFromDbFile(src);
      expect((await SampleArchiver.rows(_day)).length, before);
    });

    test('a LEGACY backup (no origin columns) is placed by its day id in the '
        'restoring zone', () async {
      await destination();
      final src = await _source([
        _row(_blob('hr', 1000, 1100, _hr)),
      ], legacy: true);
      await LocalDb.importFromDbFile(src);
      final last = (await SampleArchiver.rows(_day)).where((r) => r.signal == 'hr').last;
      expect(last.originSec, _d0);
      expect(last.nSlots, 86400);
    });
  });

  group('read side asserts disjointness', () {
    test('overlapping parts (corrupt state) make summary / reconstruct throw '
        'instead of double counting', () async {
      await _freshDb('sample4_overlap.db');
      await _seed(0, 120);
      await SampleArchiver.archiveDay(_day, nowSec: _now);
      final db = await LocalDb.instance;
      final r = (await db.query('spectral_archive')).first;
      await db.insert('spectral_archive', {...r, 'part': 7});
      await expectLater(SampleArchiver.summary(_day, 'hr'), throwsA(isA<StateError>()));
      await expectLater(SampleArchiver.reconstruct(_day, 'hr'), throwsA(isA<StateError>()));
    });
  });

  group('P1 time zone: absolute origins (Denver -> New York)', () {
    final denver = SampleZone.fixedOffset(-6 * 3600);
    final newYork = SampleZone.fixedOffset(-4 * 3600);
    late int denverStart, nyStart;
    setUp(() {
      denverStart = denver.startOf(_day);
      nyStart = newYork.startOf(_day);
    });

    Future<void> put(int absSec, double hr, {String device = ''}) async {
      final db = await LocalDb.instance;
      await db.insert('decoded_onehz', {
        'device_id': device, 'ts_ms': absSec * 1000, 'rec_ts': absSec,
        'counter': absSec, 'hr': hr.round(),
      });
    }

    test('the review case: slot 6000 means 07:40 UTC in Denver and 05:40 UTC '
        'in New York - the fresh New York reading is archived, not dropped '
        'as "covered"', () async {
      await _freshDb('sample4_tz1.db');
      SampleArchiver.zone = denver;
      for (var i = 5990; i < 6010; i++) {
        await put(denverStart + i, 60);
      }
      await SampleArchiver.archiveDay(_day, nowSec: _now);
      // Travel. A backfill lands for the SAME day label in the new zone.
      SampleArchiver.zone = newYork;
      for (var i = 5990; i < 6010; i++) {
        await put(nyStart + i, 110);
      }
      final n = await SampleArchiver.archiveDay(_day, nowSec: _now + 1);
      expect(n, 1, reason: 'a new part for the new slots');
      final rows = (await SampleArchiver.rows(_day)).where((r) => r.signal == 'hr').toList();
      expect(rows.map((r) => r.originSec).toList(), [denverStart, nyStart]);
      expect(rows.map((r) => r.nValid).toList(), [20, 20]);
      final rec = (await SampleArchiver.reconstructWithOrigin(_day, 'hr'))!;
      expect(rec.originSec, nyStart, reason: 'the earliest origin');
      expect((rec.samples[5995]! - 110).abs(), lessThanOrEqualTo(3));
      expect((rec.samples[(denverStart - nyStart) + 5995]! - 60).abs(),
          lessThanOrEqualTo(3));
      expect(_validCount(rec.samples), 40);
      final lv = (await SampleArchiver.summary(_day, 'hr'))!;
      expect(lv.last.cells.single.count, 40);
      expect(lv.last.cellSeconds, rec.samples.length);
    });

    test('the same absolute second is covered once, whichever zone sees it: '
        'a re-read in the new zone writes nothing', () async {
      await _freshDb('sample4_tz2.db');
      SampleArchiver.zone = denver;
      for (var i = 6000; i < 6020; i++) {
        await put(denverStart + i, 60);
      }
      await SampleArchiver.archiveDay(_day, nowSec: _now);
      SampleArchiver.zone = newYork;
      expect(await SampleArchiver.archiveDay(_day, nowSec: _now + 1), 0);
      expect((await SampleArchiver.rows(_day)).length, 1);
    });

    test('coverage is checked across day labels too: seconds archived under '
        "Denver's 10-03 are not archived again under New York's 10-04",
        () async {
      await _freshDb('sample4_tz3.db');
      SampleArchiver.zone = denver;
      // Denver 10-03 ends at denverStart + 86400 = 06:00 UTC on 10-04, which is
      // 02:00 New York time on 10-04.
      final late = denverStart + 86000;
      for (var i = 0; i < 20; i++) {
        await put(late + i, 60);
      }
      await SampleArchiver.archiveDay(_day, nowSec: _now);
      SampleArchiver.zone = newYork;
      expect(await SampleArchiver.archiveDay('2026-10-04', nowSec: _now + 1), 0);
      expect(await SampleArchiver.rows('2026-10-04'), isEmpty);
    });

    test('archiveBefore labels days with the zone in force', () async {
      await _freshDb('sample4_tz4.db');
      SampleArchiver.zone = denver;
      await put(denverStart + 100, 60);
      await SampleArchiver.archiveBefore(denverStart + 86400, nowSec: _now);
      expect((await SampleArchiver.rows(_day)).single.originSec, denverStart);
    });

    test('legacy parts without an origin read as the day id in the current '
        'zone', () async {
      await _freshDb('sample4_tz5.db');
      final db = await LocalDb.instance;
      await db.insert('spectral_archive', {
        'day_id': _day, 'device_id': '', 'signal': 'hr',
        'codec_version': SampleCodec.codecVersion, 'part': 0,
        'blob': _blob('hr', 0, 100, _hr), 'n_valid': 100, 'rms_err': 0.1,
        'max_err': 0.2, 'created_at': 1,
      });
      final rec = (await SampleArchiver.reconstructWithOrigin(_day, 'hr'))!;
      expect(rec.originSec, _d0);
    });
  });
}
