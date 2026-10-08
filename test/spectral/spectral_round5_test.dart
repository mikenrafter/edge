// Spectral archive, review round 5 (RED).
//
//   P1 isolate  the restore-path carve (SpectralCodec.restrict, ~360 ms on
//               real data) must not run on the calling (UI) isolate
//   P2 bound    a carved part's stored error bound is never smaller than the
//               incoming part's; its rms is recomputed, not copied
//
// Fixed dates, nowSec injected, real sqflite_ffi and real codec blobs.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/spectral_archive.dart';
import 'package:openstrap_edge/data/spectral_codec.dart';
import 'package:openstrap_edge/data/spectral_import.dart';

import '../support/dart_source.dart';

const _day = '2026-10-03';
const _now = 1791000000;
const _q = 0.004;

late int _d0;

double _hr(int i) => 80.0 + (i % 7);

List<double?> _series(int from, int to, double Function(int) f) =>
    [for (var i = 0; i < 86400; i++) (i >= from && i < to) ? f(i) : null];

Uint8List _blob(String sig, int from, int to, double Function(int) f,
        {SpectralMode mode = SpectralMode.adaptive}) =>
    SpectralCodec.encode(sig, _series(from, to, f), mode: mode).blob;

Future<void> _freshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory
      .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
}

/// Destination history covering slots 0-239 for hr, ax and ay.
Future<void> _destination() async {
  await _freshDb('spectral5.db');
  final db = await LocalDb.instance;
  final b = db.batch();
  for (var i = 0; i < 240; i++) {
    b.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': (_d0 + i) * 1000,
      'rec_ts': _d0 + i,
      'counter': _d0 + i,
      'hr': _hr(i).round(),
      'ax': 0.5,
      'ay': 0.5,
    });
  }
  await b.commit(noResult: true);
  await SpectralArchiver.archiveDay(_day, nowSec: _now);
}

Future<String> _source(List<Map<String, Object?>> rows) async {
  final path = p.join(await databaseFactory.getDatabasesPath(), 'spectral5_src.db');
  await databaseFactory.deleteDatabase(path);
  final src = await databaseFactory.openDatabase(path);
  await src.execute('CREATE TABLE spectral_archive ('
      "day_id TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT '', "
      'signal TEXT NOT NULL, codec_version INTEGER NOT NULL, '
      'part INTEGER NOT NULL DEFAULT 0, blob BLOB NOT NULL, '
      'n_valid INTEGER NOT NULL, rms_err REAL NOT NULL, '
      'max_err REAL NOT NULL, created_at INTEGER NOT NULL, '
      'origin_sec INTEGER, n_slots INTEGER, '
      'slot_sec INTEGER NOT NULL DEFAULT 1, '
      'PRIMARY KEY (day_id, device_id, signal, codec_version, part))');
  for (final r in rows) {
    await src.insert('spectral_archive', r);
  }
  await src.close();
  return path;
}

Map<String, Object?> _row(String signal, Uint8List blob,
        {double rms = 0.5, double max = 2.0, int nValid = 180, int part = 0}) =>
    {
      'day_id': _day,
      'device_id': '',
      'signal': signal,
      'codec_version': SpectralCodec.codecVersion,
      'part': part,
      'blob': blob,
      'n_valid': nValid,
      'rms_err': rms,
      'max_err': max,
      'created_at': 5,
      'origin_sec': _d0,
      'n_slots': 86400,
      'slot_sec': 1,
    };

Future<SpectralArchiveRow> _carved(String sig) async => (await SpectralArchiver.rows(_day))
    .where((r) => r.signal == sig && r.part >= 1)
    .last;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _d0 = localDayStartSec(_day)!;
  });
  tearDownAll(() async => LocalDb.close());
  tearDown(() => spectralCarveRunner = Isolate.run);

  group('P1: the carve runs through Isolate.run', () {
    test('importing an overlapping part hands the carve to the runner', () async {
      await _destination();
      var calls = 0;
      spectralCarveRunner = <R>(FutureOr<R> Function() f) {
        calls++;
        return Isolate.run<R>(f);
      };
      final src = await _source([_row('hr', _blob('hr', 180, 360, _hr))]);
      await LocalDb.importFromDbFile(src);
      expect(calls, 1);
      expect(await SpectralArchiver.rows(_day), hasLength(greaterThan(3)));
    });

    test('a verbatim insert and a fully covered part never spin up a worker',
        () async {
      await _destination();
      var calls = 0;
      spectralCarveRunner = <R>(FutureOr<R> Function() f) {
        calls++;
        return Isolate.run<R>(f);
      };
      final src = await _source([
        _row('hr', _blob('hr', 1000, 1100, _hr)), // disjoint
        _row('hr', _blob('hr', 50, 150, _hr), part: 1), // fully covered
      ]);
      await LocalDb.importFromDbFile(src);
      expect(calls, 0);
    });

    test('byte-identical to carving in-isolate with the same predicate',
        () async {
      await _destination();
      final blob = _blob('hr', 180, 360, (i) => 200.0 - (i % 3));
      final src = await _source([_row('hr', blob)]);
      await LocalDb.importFromDbFile(src);
      // Minutes 0..3 hold slots 0-239 (covered); 4 and 5 are new.
      final direct = SpectralCodec.restrict(blob, (m) => m >= 4)!;
      expect((await _carved('hr')).blob, direct.blob);
    });

    test('guard: spectral_import.dart calls restrict only inside the worker '
        'closure handed to the runner', () {
      final code = stripCommentsAndStrings(
          File('lib/data/spectral_import.dart').readAsStringSync());
      expect(RegExp(r'SpectralCodec\s*\.\s*restrict').allMatches(code).length, 1,
          reason: 'one carve site');
      // The only callers of the sync carve: its definition and the closure
      // handed to the runner.
      final sites = RegExp(r'carveSpectralPartSync\s*\(').allMatches(code).toList();
      expect(sites.length, 2);
      final runner = RegExp(r'spectralCarveRunner\s*\(').firstMatch(code);
      expect(runner, isNotNull, reason: 'the carve must go through the runner');
      var depth = 0;
      for (final c in code.substring(runner!.start, sites.first.start).split('')) {
        if (c == '(') depth++;
        if (c == ')') depth--;
      }
      expect(depth, greaterThan(0), reason: 'the call sits inside the runner call');
      expect(code.indexOf('SpectralCodec.restrict'), greaterThan(sites.last.start),
          reason: 'restrict lives only in the sync carve');
      expect(code.contains('Isolate.run'), isTrue);
    });
  });

  group('P2: a carved part never understates its error bound', () {
    test('lossless: max never below the incoming; rms is the subset bound '
        '(sqrt(N/n) larger than the whole, not copied)', () async {
      await _destination();
      final blob = _blob('ax', 180, 360, (i) => 0.3 + (i % 11) * _q,
          mode: SpectralMode.losslessAtQuantum);
      final src = await _source([_row('ax', blob, rms: 0.001, max: 0.002)]);
      await LocalDb.importFromDbFile(src);
      final c = await _carved('ax');
      expect(c.nValid, 120);
      expect(c.maxErr, greaterThanOrEqualTo(0.002));
      expect(c.rmsErr, isNot(0.001), reason: 'copied from the whole');
      expect(c.rmsErr, closeTo(0.001 * math.sqrt(180 / 120), 1e-9));
    });

    test('lossy: the whole\'s max bound exceeds the subset\'s real error and '
        'is still the floor; rms is recomputed and never above max', () async {
      await _destination();
      final raw = _series(180, 360, (i) => 100.0 + (i % 5) * 2);
      final blob = SpectralCodec.encode('hr', raw).blob;
      final src = await _source([_row('hr', blob, rms: 0.1, max: 5.0)]);
      await LocalDb.importFromDbFile(src);
      final c = await _carved('hr');
      expect(c.maxErr, greaterThanOrEqualTo(5.0));
      expect(c.rmsErr, greaterThanOrEqualTo(0.1 * math.sqrt(180 / 120) - 1e-9));
      expect(c.rmsErr, lessThanOrEqualTo(c.maxErr));
      final r = (await SpectralArchiver.reconstruct(_day, 'hr'))!;
      var mx = 0.0;
      for (var i = 240; i < 360; i++) {
        mx = math.max(mx, (r[i]! - raw[i]!).abs());
      }
      expect(c.maxErr, greaterThanOrEqualTo(mx));
    });

    test('pyramid-only: the incoming max is kept, not zeroed', () async {
      await _destination();
      final blob = _blob('ay', 180, 360, (i) => 0.1 * (i % 4),
          mode: SpectralMode.pyramidOnly);
      final src = await _source([_row('ay', blob, rms: 0, max: 1.0)]);
      await LocalDb.importFromDbFile(src);
      expect((await _carved('ay')).maxErr, greaterThanOrEqualTo(1.0));
    });
  });
}
