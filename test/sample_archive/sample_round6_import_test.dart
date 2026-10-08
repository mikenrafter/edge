// Sample archive, round 6 C and D (RED).
//
//   C  a restore landing while the archiver is mid-encode must not lose a part:
//      coverage and the part number are decided INSIDE the insert transaction,
//      with a plain INSERT; the archiver and the import also serialize.
//   D  an opaque (unsupported-version) part imported twice is one part.
//   +  version-1 parts count as coverage and are inserted verbatim, never
//      carved (carving would re-encode a DCT part).
//
// Fixed dates, nowSec injected, real sqflite_ffi and real codec blobs. The
// "import lands mid-encode" is injected through an async hook, not a delay.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/sample_archive.dart';
import 'package:openstrap_edge/data/sample_codec.dart';
import 'package:openstrap_edge/data/sample_import.dart';
import 'package:openstrap_edge/data/sample_lock.dart';

import '../support/dart_source.dart';
import '../support/sample_v1_blobs.dart';

const _day = '2026-10-03';
const _now = 1791000000;

late int _d0;

double _hr(int i) => 80.0 + (i % 7);

List<double?> _series(int from, int to, double Function(int) f) =>
    [for (var i = 0; i < 86400; i++) (i >= from && i < to) ? f(i) : null];

Uint8List _blob(int from, int to, double Function(int) f) =>
    SampleCodec.encode('hr', _series(from, to, f),
            mode: SampleMode.quantized)
        .blob;

Future<void> _freshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory
      .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
}

Future<void> _seed(int from, int to) async {
  final db = await LocalDb.instance;
  final b = db.batch();
  for (var i = from; i < to; i++) {
    b.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': (_d0 + i) * 1000,
      'rec_ts': _d0 + i,
      'counter': _d0 + i,
      'hr': _hr(i).round(),
    });
  }
  await b.commit(noResult: true);
}

Map<String, Object?> _row(Uint8List blob,
        {String device = '',
        int part = 0,
        int? origin,
        int version = 2,
        String signal = 'hr'}) =>
    {
      'day_id': _day,
      'device_id': device,
      'signal': signal,
      'codec_version': version,
      'part': part,
      'blob': blob,
      'n_valid': 60,
      'rms_err': 0.5,
      'max_err': 1.4,
      'created_at': 5,
      'origin_sec': origin ?? _d0,
      'n_slots': 86400,
      'slot_sec': 1,
    };

Future<String> _source(List<Map<String, Object?>> rows) async {
  final path = p.join(await databaseFactory.getDatabasesPath(), 'sample6_src.db');
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

Future<List<SampleArchiveRow>> _hrRows() async =>
    (await SampleArchiver.rows(_day)).where((r) => r.signal == 'hr').toList();

/// Every second of every hr part, asserting no second is held twice.
Future<Set<int>> _covered() async {
  final seen = <int>{};
  for (final r in await _hrRows()) {
    for (final (a, b) in SampleCodec.validRuns(r.blob)) {
      for (var i = a; i < b; i++) {
        expect(seen.add(r.originSec + i), isTrue,
            reason: 'second ${r.originSec + i} archived twice');
      }
    }
  }
  return seen;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _d0 = localDayStartSec(_day)!;
  });
  tearDownAll(() async => LocalDb.close());
  tearDown(() {
    SampleArchiver.debugBeforeWrite = null;
  });

  group('C: a restore landing mid-encode loses nothing', () {
    test('Sol\'s case: archive 0-1799 while a disjoint part 3600-3659 is '
        'imported mid-encode -> both survive, slot 3600 reconstructs',
        () async {
      await _freshDb('sample6_c1.db');
      await _seed(0, 1800);
      final db = await LocalDb.instance;
      SampleArchiver.debugBeforeWrite = () async {
        // The restore's own merge, run straight at the table (no lock): the
        // archiver's insert transaction must cope regardless.
        await db.transaction((txn) async {
          expect(
              await importSamplePart(
                  txn, _row(_blob(3600, 3660, (i) => 120.0))),
              isTrue);
        });
      };
      expect(await SampleArchiver.archiveDay(_day, nowSec: _now), 1);
      final rows = await _hrRows();
      expect(rows, hasLength(2), reason: 'the imported part was not erased');
      expect(rows.map((r) => r.part).toSet(), hasLength(2),
          reason: 'distinct part numbers');
      final cov = await _covered();
      expect(cov.length, 1800 + 60);
      final r = (await SampleArchiver.reconstruct(_day, 'hr'))!;
      expect(r[3600], isNotNull, reason: 'slot 3600 reconstructs');
      expect((r[3600]! - 120).abs(), lessThanOrEqualTo(1.4 + 1e-9));
      expect(r[100], isNotNull);
    });

    test('an import that OVERLAPS what the archiver is about to write: the '
        'archiver\'s part is carved to the still-free minutes', () async {
      await _freshDb('sample6_c2.db');
      await _seed(0, 1800);
      final db = await LocalDb.instance;
      SampleArchiver.debugBeforeWrite = () async {
        await db.transaction((txn) async {
          await importSamplePart(
              txn, _row(_blob(900, 1800, (i) => 150.0)));
        });
      };
      await SampleArchiver.archiveDay(_day, nowSec: _now);
      final cov = await _covered(); // asserts disjoint
      expect(cov.length, 1800);
      final r = (await SampleArchiver.reconstruct(_day, 'hr'))!;
      expect((r[1000]! - 150).abs(), lessThanOrEqualTo(1.4 + 1e-9),
          reason: 'the imported value stays');
      expect((r[100]! - _hr(100)).abs(), lessThanOrEqualTo(1.4 + 1e-9),
          reason: 'the archiver kept the free minutes');
    });

    test('an import that covers everything the archiver encoded: the '
        'archiver writes nothing more', () async {
      await _freshDb('sample6_c3.db');
      await _seed(0, 1800);
      final db = await LocalDb.instance;
      SampleArchiver.debugBeforeWrite = () async {
        await db.transaction((txn) async {
          await importSamplePart(txn, _row(_blob(0, 1800, (i) => 99.0)));
        });
      };
      await SampleArchiver.archiveDay(_day, nowSec: _now);
      expect(await _hrRows(), hasLength(1));
      expect((await _covered()).length, 1800);
    });

    test('no REPLACE on the part table: the only one left is the status '
        'ledger', () {
      final code = stripCommentsAndStrings(
          File('lib/data/sample_archive.dart').readAsStringSync());
      final all = RegExp(r'ConflictAlgorithm\s*\.\s*replace').allMatches(code);
      expect(all, hasLength(1));
      expect(all.single.start, greaterThan(code.indexOf('_setStatus(Database')),
          reason: 'inside _setStatus');
    });
  });

  group('C: archiver and restore serialize', () {
    test('SampleLock runs jobs one at a time, in order, and a failure does '
        'not wedge the queue', () async {
      final log = <String>[];
      final gate = Completer<void>();
      final a = SampleLock.run(() async {
        log.add('a start');
        await gate.future;
        log.add('a end');
        return 1;
      });
      final b = SampleLock.run(() async {
        log.add('b start');
        throw StateError('boom');
      });
      final c = SampleLock.run(() async {
        log.add('c start');
        return 3;
      });
      await pumpEventQueue();
      expect(log, ['a start'], reason: 'b and c wait for a');
      gate.complete();
      expect(await a, 1);
      await expectLater(b, throwsStateError);
      expect(await c, 3);
      expect(log, ['a start', 'a end', 'b start', 'c start']);
    });

    test('guard: archiveDay and the restore merge both take the lock', () {
      final arch = stripCommentsAndStrings(
          File('lib/data/sample_archive.dart').readAsStringSync());
      final db = stripCommentsAndStrings(
          File('lib/data/db.dart').readAsStringSync());
      expect(RegExp(r'SampleLock\s*\.\s*run').hasMatch(arch), isTrue);
      expect(RegExp(r'SampleLock\s*\.\s*run\s*\(\s*\(\s*\)\s*=>\s*_mergeFromDbFile')
              .hasMatch(db),
          isTrue,
          reason: 'taken before the merge opens its transaction');
    });
  });

  group('D: opaque and old-version parts import idempotently', () {
    Uint8List opaque(Uint8List b) => Uint8List.fromList(b)..[4] = 9;

    test('an unsupported-version part imported twice is ONE part', () async {
      await _freshDb('sample6_d1.db');
      final src = await _source([
        _row(opaque(_blob(0, 100, _hr)), version: 9),
      ]);
      await LocalDb.importFromDbFile(src);
      await LocalDb.importFromDbFile(src);
      final rows = (await SampleArchiver.rows(_day))
          .where((r) => r.codecVersion == 9);
      expect(rows, hasLength(1));
    });

    test('...but different bytes, a different origin or a different device '
        'are different parts', () async {
      await _freshDb('sample6_d2.db');
      final a = opaque(_blob(0, 100, _hr));
      final b = opaque(_blob(0, 100, (i) => _hr(i) + 5));
      final src = await _source([
        _row(a, version: 9, part: 0),
        _row(b, version: 9, part: 1),
        _row(a, version: 9, part: 2, origin: _d0 + 3600),
        _row(a, version: 9, part: 3, device: 'oura-x'),
      ]);
      await LocalDb.importFromDbFile(src);
      await LocalDb.importFromDbFile(src);
      final rows = (await SampleArchiver.rows(_day))
          .where((r) => r.codecVersion == 9)
          .toList();
      expect(rows, hasLength(4));
    });

    test('a version-1 part is inserted verbatim once, however often it '
        'comes', () async {
      await _freshDb('sample6_d3.db');
      final src = await _source([_row(v1HrAdaptive.bytes, version: 1)]);
      await LocalDb.importFromDbFile(src);
      await LocalDb.importFromDbFile(src);
      final rows = await _hrRows();
      expect(rows, hasLength(1));
      expect(rows.single.codecVersion, 1);
      expect(rows.single.blob, v1HrAdaptive.bytes);
    });

    test('a version-1 part partly covered is skipped, not carved: carving '
        'would re-encode a DCT part', () async {
      await _freshDb('sample6_d4.db');
      final db = await LocalDb.instance;
      await db.transaction((txn) async {
        await importSamplePart(txn, _row(_blob(200, 260, _hr)));
      });
      final before = await _hrRows();
      final src = await _source([_row(v1HrAdaptive.bytes, version: 1)]);
      await LocalDb.importFromDbFile(src); // overlaps 200-260
      final after = await _hrRows();
      expect(after.length, before.length);
      expect(after.where((r) => r.codecVersion == 1), isEmpty);
    });

    test('a version-1 part fully covered is skipped', () async {
      await _freshDb('sample6_d4b.db');
      final db = await LocalDb.instance;
      await db.transaction((txn) async {
        await importSamplePart(txn, _row(_blob(0, 400, (i) => 70.0)));
      });
      final before = await _hrRows();
      final src = await _source([_row(v1HrAdaptive.bytes, version: 1)]);
      await LocalDb.importFromDbFile(src);
      expect((await _hrRows()).length, before.length);
    });

    test('version-1 parts are coverage: the archiver encodes only what a v1 '
        'part does not hold, and the day reconstructs across both versions',
        () async {
      await _freshDb('sample6_d5.db');
      final db = await LocalDb.instance;
      await db.transaction((txn) async {
        await importSamplePart(txn, _row(v1HrAdaptive.bytes, version: 1));
      });
      await _seed(0, 400); // v1 holds 0-129 and 160-399
      expect(await SampleArchiver.archiveDay(_day, nowSec: _now), 1);
      final rows = await _hrRows();
      expect(rows.map((r) => r.codecVersion).toSet(), {1, 2});
      final cov = await _covered(); // disjoint across versions
      expect(cov.length, 400 - 0); // 370 from v1 + 30 new, all 400 seconds
      final r = (await SampleArchiver.reconstruct(_day, 'hr'))!;
      for (var i = 0; i < 400; i++) {
        expect(r[i], isNotNull, reason: 'slot $i');
      }
      expect((r[140]! - _hr(140).round()).abs(), lessThanOrEqualTo(1.4 + 1e-9));
    });
  });
}
