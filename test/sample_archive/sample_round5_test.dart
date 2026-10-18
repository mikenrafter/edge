// Sample archive, review round 5 (RED).
//
//   P1 isolate  the restore-path carve (SampleCodec.restrict, ~360 ms on
//               real data) must not run on the calling (UI) isolate
//   P2 bound    a carved part's stored error bound is never smaller than the
//               incoming part's; its rms is recomputed, not copied
//
// Fixed dates, nowSec injected, real sqflite_ffi and real codec blobs.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sample_archive.dart';
import 'package:openstrap_edge/data/sample_codec.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';

import '../support/dart_source.dart';

const _day = '2026-10-03';
const _now = 1791000000;
const _q = 0.004;

late int _d0;

double _hr(int i) => 80.0 + (i % 7);

List<double?> _series(int from, int to, double Function(int) f) =>
    [for (var i = 0; i < 86400; i++) (i >= from && i < to) ? f(i) : null];

Uint8List _blob(String sig, int from, int to, double Function(int) f,
        {SampleMode mode = SampleMode.adaptive}) =>
    SampleCodec.encode(sig, _series(from, to, f), mode: mode).blob;

Future<void> _freshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory
      .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
}

/// Destination history covering slots 0-239 for hr, ax and ay.
Future<void> _destination() async {
  await _freshDb('sample5.db');
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
  await SampleArchiver.archiveDay(_day, nowSec: _now);
}

Future<String> _source(List<Map<String, Object?>> rows) async {
  final path = p.join(await databaseFactory.getDatabasesPath(), 'sample5_src.db');
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
      'codec_version': SampleCodec.codecVersion,
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

Future<SampleArchiveRow> _carved(String sig) async => (await SampleArchiver.rows(_day))
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
  // The carve is the registered entry `carveSamplePartHeavy`, dispatched through
  // `Isolate.run` and reported to the dispatcher audit as 'sample carve'. The
  // old `sampleCarveRunner` test seam is gone (the guard could not see through a
  // function-typed static, so it could not know the entry was ever dispatched);
  // the audit hook records the same fact: "the work was handed off".
  final carves = <DispatchEvent>[];
  setUp(() {
    carves.clear();
    WorkerAudit.onDispatch = (e) {
      if (e.label == 'sample carve') carves.add(e);
    };
  });
  tearDown(WorkerAudit.reset);

  group('P1: the carve runs through Isolate.run', () {
    test('importing an overlapping part hands the carve to a worker', () async {
      await _destination();
      final src = await _source([_row('hr', _blob('hr', 180, 360, _hr))]);
      await LocalDb.importFromDbFile(src);
      expect(carves, hasLength(1));
      expect(carves.single.kind, Dispatcher.run);
      expect(await SampleArchiver.rows(_day), hasLength(greaterThan(3)));
    });

    test('a verbatim insert and a fully covered part never spin up a worker',
        () async {
      await _destination();
      final src = await _source([
        _row('hr', _blob('hr', 1000, 1100, _hr)), // disjoint
        _row('hr', _blob('hr', 50, 150, _hr), part: 1), // fully covered
      ]);
      await LocalDb.importFromDbFile(src);
      expect(carves, isEmpty);
    });

    test('byte-identical to carving in-isolate with the same predicate',
        () async {
      await _destination();
      final blob = _blob('hr', 180, 360, (i) => 200.0 - (i % 3));
      final src = await _source([_row('hr', blob)]);
      await LocalDb.importFromDbFile(src);
      // Minutes 0..3 hold slots 0-239 (covered); 4 and 5 are new.
      final direct = SampleCodec.restrict(blob, (m) => m >= 4)!;
      expect((await _carved('hr')).blob, direct.blob);
    });

    // Source-scan guard, rewritten when the carve became a registered entry
    // (before: restrict reachable only inside the closure handed to the
    // `sampleCarveRunner` seam, with `carveSamplePartSync` called twice). Now:
    // the pure carve is `carveSamplePartSync`, called by exactly one place, the
    // entry in sample_heavy.dart, and `carveSamplePart` reaches that entry only
    // from inside an `Isolate.run(` call.
    test('guard: restrict lives only in the sync carve, which only the '
        'registered entry calls, and the entry runs inside Isolate.run', () {
      final code = stripCommentsAndStrings(
          File('lib/data/sample_import.dart').readAsStringSync());
      expect(RegExp(r'SampleCodec\s*\.\s*restrict').allMatches(code).length, 1,
          reason: 'one carve site');
      expect(RegExp(r'carveSamplePartSync\s*\(').allMatches(code).length, 1,
          reason: 'sample_import.dart only defines the sync carve');
      expect(code.indexOf('SampleCodec.restrict'),
          greaterThan(code.indexOf('carveSamplePartSync')),
          reason: 'restrict lives only in the sync carve');
      final heavy = stripCommentsAndStrings(
          File('lib/data/sample_heavy.dart').readAsStringSync());
      expect(RegExp(r'carveSamplePartSync\s*\(').allMatches(heavy).length, 1,
          reason: 'the registered entry is the only caller of the sync carve');

      final run = RegExp(r'Isolate\s*\.\s*run\s*\(').firstMatch(code);
      final entry = RegExp(r'carveSamplePartHeavy\s*\(').firstMatch(code);
      expect(run, isNotNull, reason: 'the carve must go through Isolate.run');
      expect(entry, isNotNull);
      var depth = 0;
      for (final c in code.substring(run!.start, entry!.start).split('')) {
        if (c == '(') depth++;
        if (c == ')') depth--;
      }
      expect(depth, greaterThan(0), reason: 'the entry call sits inside Isolate.run');
    });
  });

  group('P2: a carved part never understates its error bound', () {
    test('lossless: max never below the incoming; rms is the subset bound '
        '(sqrt(N/n) larger than the whole, not copied)', () async {
      await _destination();
      final blob = _blob('ax', 180, 360, (i) => 0.3 + (i % 11) * _q,
          mode: SampleMode.losslessAtQuantum);
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
      final blob = SampleCodec.encode('hr', raw).blob;
      final src = await _source([_row('hr', blob, rms: 0.1, max: 5.0)]);
      await LocalDb.importFromDbFile(src);
      final c = await _carved('hr');
      expect(c.maxErr, greaterThanOrEqualTo(5.0));
      expect(c.rmsErr, greaterThanOrEqualTo(0.1 * math.sqrt(180 / 120) - 1e-9));
      expect(c.rmsErr, lessThanOrEqualTo(c.maxErr));
      final r = (await SampleArchiver.reconstruct(_day, 'hr'))!;
      var mx = 0.0;
      for (var i = 240; i < 360; i++) {
        mx = math.max(mx, (r[i]! - raw[i]!).abs());
      }
      expect(c.maxErr, greaterThanOrEqualTo(mx));
    });

    test('pyramid-only: the incoming max is kept, not zeroed', () async {
      await _destination();
      final blob = _blob('ay', 180, 360, (i) => 0.1 * (i % 4),
          mode: SampleMode.pyramidOnly);
      final src = await _source([_row('ay', blob, rms: 0, max: 1.0)]);
      await LocalDb.importFromDbFile(src);
      expect((await _carved('ay')).maxErr, greaterThanOrEqualTo(1.0));
    });
  });
}
