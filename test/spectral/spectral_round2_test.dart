// Spectral archive, review round 2 (RED): the defects Sol found, pinned.
//
//   P1 coverage   an archive must never lose a slot it once held, and must add
//                 slots that arrive later - by coverage, not by count
//   P1 devices    archives are per device_id; devices are never merged
//   P1 delete     deleteDays removes the archive (all codec versions) + status
//   P2 backup     restore, salvage and the selected-day export carry the tables
//   P2 race       an offload landing between the archive read and the prune
//                 must not be pruned unarchived
//   status        a failed archive is distinguishable from absent input
//
// Fixed dates, TZ=UTC, nowSec injected. Real sqflite_ffi.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/spectral_archive.dart';
import 'package:openstrap_edge/data/spectral_codec.dart';

const _day1 = '2026-10-03';
const _day2 = '2026-10-04';
const _now = 1791000000;
const _second = 'oura-a1b2c3d4';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

late int _d1, _d2;
late Directory _tmp;

Future<void> _freshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
}

/// hr varies with the slot so a wrong slot is visible; everything else NULL
/// unless given.
Future<void> _put(int dayStart, int fromSlot, int toSlot,
    {String device = '', double hr = 60, bool ramp = true, double? ax}) async {
  final db = await LocalDb.instance;
  final b = db.batch();
  for (var i = fromSlot; i < toSlot; i++) {
    final ts = dayStart + i;
    b.insert('decoded_onehz', {
      'device_id': device,
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': (hr + (ramp ? (i % 40) : 0)).round(),
      'ax': ax,
    });
  }
  await b.commit(noResult: true);
}

double _truthHr(int slot, {double base = 60}) => base + (slot % 40);

void _expectSlots(List<double?> r, int from, int to, double Function(int) truth,
    {double tol = 3.0}) {
  for (var i = from; i < to; i++) {
    expect(r[i], isNotNull, reason: 'slot $i lost');
    expect((r[i]! - truth(i)).abs(), lessThanOrEqualTo(tol), reason: 'slot $i');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _d1 = localDayStartSec(_day1)!;
    _d2 = localDayStartSec(_day2)!;
    _tmp = await Directory.systemTemp.createTemp('openstrap_spectral2_');
    PathProviderPlatform.instance = _FakePathProvider(_tmp.path);
  });
  tearDownAll(() async {
    await LocalDb.close();
    if (await _tmp.exists()) await _tmp.delete(recursive: true);
  });

  group('P1 coverage: an archive never loses a slot it held', () {
    test('archive 0-99, prune 0-49, backfill 100-150: the union survives '
        '(slots 0-49 are NOT nulled by a bigger-count replacement)', () async {
      await _freshDb('spectral2_cov1.db');
      await _put(_d1, 0, 100);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      final db = await LocalDb.instance;
      await db.delete('decoded_onehz',
          where: 'rec_ts < ?', whereArgs: [_d1 + 50]);
      await _put(_d1, 100, 151);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now + 1);
      final r = (await SpectralArchiver.reconstruct(_day1, 'hr'))!;
      _expectSlots(r, 0, 151, _truthHr);
      expect(r[151], isNull);
      final lv = (await SpectralArchiver.summary(_day1, 'hr'))!;
      expect(lv.last.cells.single.count, 151,
          reason: 'the pyramid describes the union too');
    });

    test('equal-or-smaller new data is still archived: 0-99 archived, 0-49 '
        'pruned, 100-149 arrive (50 new samples, count would tie)', () async {
      await _freshDb('spectral2_cov2.db');
      await _put(_d1, 0, 100);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      final db = await LocalDb.instance;
      await db.delete('decoded_onehz',
          where: 'rec_ts < ?', whereArgs: [_d1 + 50]);
      await _put(_d1, 100, 150);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now + 1);
      // The raw for 100-149 is pruned next; what the archive holds is all
      // that is left.
      await db.delete('decoded_onehz');
      final r = (await SpectralArchiver.reconstruct(_day1, 'hr'))!;
      _expectSlots(r, 0, 150, _truthHr);
    });

    test('a slot is never double-archived and a re-run with nothing new '
        'writes nothing (parts are append-only)', () async {
      await _freshDb('spectral2_cov3.db');
      await _put(_d1, 0, 300);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      final a = await SpectralArchiver.rows(_day1);
      expect(await SpectralArchiver.archiveDay(_day1, nowSec: _now + 5), 0);
      final b = await SpectralArchiver.rows(_day1);
      expect(b.length, a.length);
      for (var i = 0; i < a.length; i++) {
        expect(b[i].part, a[i].part);
        expect(b[i].blob, a[i].blob);
        expect(b[i].createdAt, _now);
      }
      await _put(_d1, 300, 320);
      expect(await SpectralArchiver.archiveDay(_day1, nowSec: _now + 9), 1,
          reason: 'only hr has new samples: one new part');
      final c = await SpectralArchiver.rows(_day1);
      expect(c.where((r) => r.signal == 'hr').map((r) => r.part).toList(),
          [0, 1]);
      expect(c.firstWhere((r) => r.part == 1).nValid, 20,
          reason: 'the new part holds only the NEW slots');
    });

    test('each part is certified on its own: rms/max inside the spec', () async {
      await _freshDb('spectral2_cov4.db');
      await _put(_d1, 0, 500);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      final db = await LocalDb.instance;
      await db.delete('decoded_onehz', where: 'rec_ts < ?', whereArgs: [_d1 + 250]);
      await _put(_d1, 500, 900);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now + 1);
      for (final r in await SpectralArchiver.rows(_day1)) {
        expect(r.rmsErr, lessThanOrEqualTo(1.0));
        expect(r.maxErr, lessThanOrEqualTo(3.0));
      }
    });
  });

  group('P1 devices: never merged', () {
    test('two devices over the same seconds archive separately, each '
        'reconstructs its own readings', () async {
      await _freshDb('spectral2_dev1.db');
      await _put(_d1, 0, 300, hr: 60, ramp: false, ax: 0.1); // primary
      await _put(_d1, 0, 300, device: _second, hr: 150, ramp: false);
      // ax lossless so the primary's ax has samples to read back (the default
      // accel mode may be pyramid-only).
      await SpectralArchiver.archiveDay(_day1, nowSec: _now, modes: {
        ...SpectralArchiver.defaultModes,
        'ax': SpectralMode.losslessAtQuantum,
      });
      final prim = (await SpectralArchiver.reconstruct(_day1, 'hr'))!;
      final sec = (await SpectralArchiver.reconstruct(_day1, 'hr',
          deviceId: _second))!;
      _expectSlots(prim, 0, 300, (_) => 60);
      _expectSlots(sec, 0, 300, (_) => 150);
      // The secondary never reported ax: no archive for it, and the primary's
      // ax is untouched by the secondary's NULL.
      expect(await SpectralArchiver.reconstruct(_day1, 'ax', deviceId: _second),
          isNull);
      _expectSlots((await SpectralArchiver.reconstruct(_day1, 'ax'))!, 0, 300,
          (_) => 0.1, tol: 0.1);
      final rows = await SpectralArchiver.rows(_day1);
      expect(rows.map((r) => r.deviceId).toSet(), {'', _second});
    });

    test('summaries are per device too', () async {
      await _freshDb('spectral2_dev2.db');
      await _put(_d1, 0, 120, hr: 60, ramp: false);
      await _put(_d1, 0, 120, device: _second, hr: 150, ramp: false);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      final a = (await SpectralArchiver.summary(_day1, 'hr'))!;
      final b = (await SpectralArchiver.summary(_day1, 'hr', deviceId: _second))!;
      expect(a.last.cells.single.max, 60);
      expect(b.last.cells.single.min, 150);
    });
  });

  group('P1 delete: "delete this day" removes the archive', () {
    test('deleteDays drops every codec version and the status rows of that '
        'day, and only that day', () async {
      await _freshDb('spectral2_del.db');
      await _put(_d1, 0, 200);
      await _put(_d2, 0, 200);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      await SpectralArchiver.archiveDay(_day2, nowSec: _now);
      final db = await LocalDb.instance;
      await db.insert('spectral_archive', {
        'day_id': _day1,
        'device_id': '',
        'signal': 'hr',
        'codec_version': 99, // a future codec's sibling row
        'part': 0,
        'blob': Uint8List.fromList([1]),
        'n_valid': 1,
        'rms_err': 0.0,
        'max_err': 0.0,
        'created_at': 1,
      });
      await LocalDb.deleteDays({_day1});
      expect(await db.query('spectral_archive', where: 'day_id = ?', whereArgs: [_day1]),
          isEmpty);
      expect(await db.query('spectral_archive_status', where: 'day_id = ?', whereArgs: [_day1]),
          isEmpty);
      expect(await SpectralArchiver.reconstruct(_day1, 'hr'), isNull);
      expect(await SpectralArchiver.rows(_day2), isNotEmpty);
      expect(await SpectralArchiver.status(_day2), isNotEmpty);
    });
  });

  group('P2 backup / salvage / selected-day export carry the archive', () {
    test('both tables are in the restore and the salvage lists', () {
      for (final t in ['spectral_archive', 'spectral_archive_status']) {
        expect(LocalDb.restoreTablesForTest, contains(t));
        expect(LocalDb.salvageTablesForTest, contains(t));
      }
    });

    test('a restore from a backup file brings the archive rows back',
        () async {
      await _freshDb('spectral2_restore.db');
      final srcPath =
          p.join(await databaseFactory.getDatabasesPath(), 'spectral2_src.db');
      await databaseFactory.deleteDatabase(srcPath);
      final src = await databaseFactory.openDatabase(srcPath);
      await src.execute('CREATE TABLE spectral_archive ('
          "day_id TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT '', "
          'signal TEXT NOT NULL, codec_version INTEGER NOT NULL, '
          'part INTEGER NOT NULL DEFAULT 0, blob BLOB NOT NULL, '
          'n_valid INTEGER NOT NULL, rms_err REAL NOT NULL, '
          'max_err REAL NOT NULL, created_at INTEGER NOT NULL, '
          'PRIMARY KEY (day_id, device_id, signal, codec_version, part))');
      await src.execute('CREATE TABLE spectral_archive_status ('
          "day_id TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT '', "
          'outcome TEXT NOT NULL, reason TEXT, updated_at INTEGER NOT NULL, '
          'PRIMARY KEY (day_id, device_id))');
      final good = SpectralCodec.encode('hr', [70.0, 71.0, 72.0]).blob;
      await src.insert('spectral_archive', {
        'day_id': _day1, 'device_id': '', 'signal': 'hr', 'codec_version': 1,
        'part': 0, 'blob': good, 'n_valid': 3,
        'rms_err': 0.1, 'max_err': 0.2, 'created_at': 5,
      });
      await src.insert('spectral_archive_status', {
        'day_id': _day1, 'device_id': '', 'outcome': 'ok', 'reason': null,
        'updated_at': 5,
      });
      await src.close();
      await LocalDb.importFromDbFile(srcPath);
      final rows = await SpectralArchiver.rows(_day1);
      expect(rows.single.blob, good);
      expect((await SpectralArchiver.status(_day1)).single.outcome, 'ok');
      await databaseFactory.deleteDatabase(srcPath);
    });

    test('exportDaysDb carries the selected days archive and status, and '
        'only those days', () async {
      await _freshDb('spectral2_export.db');
      await _put(_d1, 0, 200);
      await _put(_d2, 0, 200);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      await SpectralArchiver.archiveDay(_day2, nowSec: _now);
      final out = await LocalDb.exportDaysDb({_day1});
      final o = await databaseFactory.openDatabase(out);
      try {
        final days = {
          for (final r in await o.query('spectral_archive')) r['day_id']
        };
        expect(days, {_day1});
        final st = {
          for (final r in await o.query('spectral_archive_status')) r['day_id']
        };
        expect(st, {_day1});
      } finally {
        await o.close();
        await databaseFactory.deleteDatabase(out);
      }
    });
  });

  group('P2 race: an offload landing mid-archive is not pruned unarchived',
      () {
    test('the guarded prune refuses when the input revision moved; the next '
        'pass archives the straggler and then prunes', () async {
      await _freshDb('spectral2_race.db');
      await _put(_d1, 0, 600);
      final cutoff = _d1 + 86400;
      final rev0 = await LocalDb.decodedRevSumBefore(cutoff);
      await SpectralArchiver.archiveBefore(cutoff, nowSec: _now);
      // An old record lands in a window the archive already read.
      final db = await LocalDb.instance;
      await db.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': (_d1 + 700) * 1000, 'rec_ts': _d1 + 700,
        'counter': 7, 'hr': 111,
      });
      expect(await LocalDb.pruneDecodedBeforeRecTs(cutoff, expectedRevSum: rev0),
          -1, reason: 'skipped, nothing deleted');
      expect(await db.query('decoded_onehz'), hasLength(601));

      // Next derive: fresh revision, archive picks the straggler up, prune ok.
      final rev1 = await LocalDb.decodedRevSumBefore(cutoff);
      expect(rev1, isNot(rev0));
      await SpectralArchiver.archiveBefore(cutoff, nowSec: _now + 1);
      expect(await LocalDb.pruneDecodedBeforeRecTs(cutoff, expectedRevSum: rev1),
          greaterThan(0));
      final r = (await SpectralArchiver.reconstruct(_day1, 'hr'))!;
      expect(r[700], isNotNull);
      expect((r[700]! - 111).abs(), lessThanOrEqualTo(3));
      _expectSlots(r, 0, 600, _truthHr);
    });

    test('a guarded prune with an unchanged revision deletes exactly as the '
        'plain prune does', () async {
      await _freshDb('spectral2_race2.db');
      await _put(_d1, 0, 100);
      final cutoff = _d1 + 86400;
      final rev = await LocalDb.decodedRevSumBefore(cutoff);
      expect(await LocalDb.pruneDecodedBeforeRecTs(cutoff, expectedRevSum: rev),
          greaterThan(0));
      expect(await (await LocalDb.instance).query('decoded_onehz'), isEmpty);
    });

    test('the plain prune (no expectation) is unchanged', () async {
      await _freshDb('spectral2_race3.db');
      await _put(_d1, 0, 100);
      expect(await LocalDb.pruneDecodedBeforeRecTs(_d1 + 86400), greaterThan(0));
    });
  });

  group('per-day outcome is persisted', () {
    test('ok for a normal day; empty when rows exist but no signal has a '
        'valid sample; nothing at all for a day with no rows', () async {
      await _freshDb('spectral2_status1.db');
      await _put(_d1, 0, 100);
      // day 2: rows, but every archived column NULL / hr 0 (off-skin).
      final db = await LocalDb.instance;
      for (var i = 0; i < 50; i++) {
        await db.insert('decoded_onehz', {
          'device_id': '', 'ts_ms': (_d2 + i) * 1000, 'rec_ts': _d2 + i,
          'counter': i, 'hr': 0,
        });
      }
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      await SpectralArchiver.archiveDay(_day2, nowSec: _now);
      await SpectralArchiver.archiveDay('2026-10-05', nowSec: _now);
      final s1 = (await SpectralArchiver.status(_day1)).single;
      expect(s1.outcome, 'ok');
      expect(s1.deviceId, '');
      expect(s1.updatedAt, _now);
      expect((await SpectralArchiver.status(_day2)).single.outcome, 'empty');
      expect(await SpectralArchiver.status('2026-10-05'), isEmpty,
          reason: 'absent input has no status row at all');
    });

    test('a failed archive is recorded with its reason, does not throw out of '
        'archiveBefore, and a later success flips it to ok', () async {
      await _freshDb('spectral2_status2.db');
      await _put(_d1, 0, 100);
      SpectralArchiver.debugBeforeEncode = (_) => throw StateError('boom');
      try {
        final n = await SpectralArchiver.archiveBefore(_d1 + 86400, nowSec: _now);
        expect(n, 0);
      } finally {
        SpectralArchiver.debugBeforeEncode = null;
      }
      final st = (await SpectralArchiver.status(_day1)).single;
      expect(st.outcome, 'failed');
      expect(st.reason, contains('boom'));
      expect(await SpectralArchiver.rows(_day1), isEmpty);
      await SpectralArchiver.archiveBefore(_d1 + 86400, nowSec: _now + 10);
      final ok = (await SpectralArchiver.status(_day1)).single;
      expect(ok.outcome, 'ok');
      expect(ok.reason, isNull);
      expect(ok.updatedAt, _now + 10);
    });

    test('a non-finite stored value is absent, not a crash', () async {
      await _freshDb('spectral2_inf.db');
      await _put(_d1, 0, 100);
      final db = await LocalDb.instance;
      await db.rawUpdate('UPDATE decoded_onehz SET hr = 9e999 WHERE rec_ts = ?',
          [_d1 + 10]);
      await SpectralArchiver.archiveDay(_day1, nowSec: _now);
      final r = (await SpectralArchiver.reconstruct(_day1, 'hr'))!;
      expect(r[10], isNull);
      expect(r[11], isNotNull);
      expect((await SpectralArchiver.status(_day1)).single.outcome, 'ok');
    });
  });
}
