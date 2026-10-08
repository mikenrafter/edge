// SpectralArchiver (RED): reads decoded_onehz, writes spectral_archive before
// the raw prune, never overwrites a fuller archive, never fabricates.
//
// All dates are fixed (TZ=UTC in the test run; days are LOCAL day ids from
// data/day_label.dart). `nowSec` is injected - no test reads a clock.
//
// Every test fails today: the archiver is a throwing stub and the table does
// not exist (schema 65).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/spectral_archive.dart';
import 'package:openstrap_edge/data/spectral_codec.dart';

import '../support/dart_source.dart';
import '../support/spectral_fixtures.dart';

const _day1 = '2026-10-03';
const _day2 = '2026-10-04';
const _now = 1791000000; // fixed "created_at"

late int _d1, _d2;

Future<void> _freshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
}

/// Seconds [fromSlot, toSlot) of [dayStart], skipping slots where hr is null.
/// hr comes from the sleep-like fixture; ax and skin temp from theirs;
/// `skin_temp_c` is left NULL when [withTemp] is false (a strap that never
/// reported it).
Future<void> _seed(int dayStart, {int slots = 7200, bool withTemp = true,
    int step = 1, int from = 0}) async {
  final db = await LocalDb.instance;
  final day = fixtureDay();
  final hr = day['hr']!, ax = day['ax']!, ay = day['ay']!, az = day['az']!;
  final tc = day['skin_temp_c']!;
  final b = db.batch();
  for (var i = from; i < slots; i += step) {
    final ts = dayStart + i;
    b.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': hr[i]?.round(),
      'ax': ax[i],
      'ay': ay[i],
      'az': az[i],
      'skin_temp_c': withTemp ? tc[i] : null,
    });
  }
  await b.commit(noResult: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _d1 = localDayStartSec(_day1)!;
    _d2 = localDayStartSec(_day2)!;
  });
  tearDownAll(() async => LocalDb.close());

  test('archiveDay writes one row per signal that has data, stamped with the '
      'injected clock and the live codec version', () async {
    await _freshDb('spectral_a1.db');
    await _seed(_d1);
    final n = await SpectralArchiver.archiveDay(_day1, nowSec: _now);
    final rows = await SpectralArchiver.rows(_day1);
    expect(n, 5);
    expect(rows.map((r) => r.signal).toSet(), SpectralArchiver.signals.toSet());
    for (final r in rows) {
      expect(r.createdAt, _now);
      expect(r.codecVersion, SpectralCodec.codecVersion);
      expect(r.dayId, _day1);
      final spec = SpectralCodec.specs[r.signal]!;
      expect(r.rmsErr, lessThanOrEqualTo(spec.maxRms));
      expect(r.maxErr, lessThanOrEqualTo(spec.maxAbs));
    }
  });

  test('a signal with zero valid samples gets NO row (no flat fabricated '
      'line)', () async {
    await _freshDb('spectral_a2.db');
    await _seed(_d1, withTemp: false);
    await SpectralArchiver.archiveDay(_day1, nowSec: _now);
    final rows = await SpectralArchiver.rows(_day1);
    expect(rows.map((r) => r.signal), isNot(contains('skin_temp_c')));
    expect(rows.map((r) => r.signal), containsAll(['hr', 'ax']));
    expect(await SpectralArchiver.reconstruct(_day1, 'skin_temp_c'), isNull);
  });

  test('n_valid equals the non-null count; the reconstruction is null exactly '
      'where the table has NULL or no row, and within bounds elsewhere',
      () async {
    await _freshDb('spectral_a3.db');
    await _seed(_d1);
    await SpectralArchiver.archiveDay(_day1, nowSec: _now);
    final truth = fixtureDay()['hr']!.sublist(0, 7200);
    final row =
        (await SpectralArchiver.rows(_day1)).firstWhere((r) => r.signal == 'hr');
    expect(row.nValid, validCount(truth));
    final r = (await SpectralArchiver.reconstruct(_day1, 'hr'))!;
    expect(r.length, localDayLengthSec(_day1));
    for (var i = 0; i < truth.length; i++) {
      expect(r[i] == null, truth[i] == null, reason: 'slot $i');
    }
    for (var i = truth.length; i < r.length; i++) {
      expect(r[i], isNull, reason: 'slot $i was never recorded');
    }
    final e = errorOf([...truth, ...List<double?>.filled(r.length - truth.length, null)], r);
    expect(e.rms, lessThanOrEqualTo(1.0));
    expect(e.max, lessThanOrEqualTo(3.0));
  });

  test('hr == 0 (the off-skin sentinel) and hr NULL are both ABSENT in the '
      'archive, not 0 bpm', () async {
    await _freshDb('spectral_a4.db');
    final db = await LocalDb.instance;
    for (var i = 0; i < 600; i++) {
      final ts = _d1 + i;
      await db.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts, 'counter': ts,
        'hr': i < 100 ? 0 : (i < 200 ? null : 70),
      });
    }
    await SpectralArchiver.archiveDay(_day1, nowSec: _now);
    final r = (await SpectralArchiver.reconstruct(_day1, 'hr'))!;
    for (var i = 0; i < 200; i++) {
      expect(r[i], isNull, reason: 'slot $i');
    }
    expect(r[300], isNotNull);
  });

  test('archiveDay is idempotent: same rows, byte-identical blobs', () async {
    await _freshDb('spectral_a5.db');
    await _seed(_d1);
    await SpectralArchiver.archiveDay(_day1, nowSec: _now);
    final a = await SpectralArchiver.rows(_day1);
    await SpectralArchiver.archiveDay(_day1, nowSec: _now + 500);
    final b = await SpectralArchiver.rows(_day1);
    expect(b.length, a.length);
    for (var i = 0; i < a.length; i++) {
      expect(b[i].blob, a[i].blob);
    }
  });

  test('a later archive built from FEWER valid samples never replaces a '
      'fuller one', () async {
    await _freshDb('spectral_a6.db');
    await _seed(_d1);
    await SpectralArchiver.archiveDay(_day1, nowSec: _now);
    final full = (await SpectralArchiver.rows(_day1))
        .firstWhere((r) => r.signal == 'hr');
    final db = await LocalDb.instance;
    await db.delete('decoded_onehz',
        where: 'rec_ts < ?', whereArgs: [_d1 + 3600]); // the raw prune ate half
    await SpectralArchiver.archiveDay(_day1, nowSec: _now + 500);
    final after = (await SpectralArchiver.rows(_day1))
        .firstWhere((r) => r.signal == 'hr');
    expect(after.nValid, full.nValid);
    expect(after.blob, full.blob);
    expect(after.createdAt, _now);
  });

  test('archiveBefore archives every day with a row below the cutoff, the '
      'straddling day WHOLE, and leaves later days alone', () async {
    await _freshDb('spectral_a7.db');
    await _seed(_d1);
    await _seed(_d2);
    final cutoff = _d2 + 3600; // day 1 is wholly before, day 2 straddles
    final n = await SpectralArchiver.archiveBefore(cutoff, nowSec: _now);
    expect(n, 10);
    expect(await SpectralArchiver.rows(_day1), hasLength(5));
    final d2 = await SpectralArchiver.rows(_day2);
    expect(d2, hasLength(5));
    final truth = fixtureDay()['hr']!.sublist(0, 7200);
    expect(d2.firstWhere((r) => r.signal == 'hr').nValid, validCount(truth),
        reason: 'the straddling day is archived whole, rows past the cutoff '
            'included - they still exist');
    // A day entirely after the cutoff is not touched.
    await _seed(localDayStartSec('2026-10-05')!);
    await SpectralArchiver.archiveBefore(cutoff, nowSec: _now);
    expect(await SpectralArchiver.rows('2026-10-05'), isEmpty);
  });

  test('the raw prune leaves the archive intact and still readable', () async {
    await _freshDb('spectral_a8.db');
    await _seed(_d1);
    await SpectralArchiver.archiveBefore(_d1 + 86400, nowSec: _now);
    final before = await SpectralArchiver.reconstruct(_day1, 'hr');
    await LocalDb.pruneDecodedBeforeRecTs(_d1 + 86400);
    final db = await LocalDb.instance;
    expect(await db.query('decoded_onehz'), isEmpty);
    expect(await SpectralArchiver.rows(_day1), hasLength(5));
    expect(await SpectralArchiver.reconstruct(_day1, 'hr'), before);
  });

  test('summary(): the LOD pyramid straight from the archive matches the '
      'table true stats; no coefficient decode', () async {
    await _freshDb('spectral_a9.db');
    await _seed(_d1);
    await SpectralArchiver.archiveDay(_day1, nowSec: _now);
    final truth = fixtureDay()['hr']!.sublist(0, 7200);
    final lv = (await SpectralArchiver.summary(_day1, 'hr'))!;
    expect(lv.map((l) => l.cellSeconds).toList(),
        [60, 900, 3600, localDayLengthSec(_day1)]);
    final day = lv.last.cells.single;
    final valid = [for (final v in truth) if (v != null) v];
    expect(day.count, valid.length);
    expect(day.min, valid.reduce((a, b) => a < b ? a : b));
    expect(day.max, valid.reduce((a, b) => a > b ? a : b));
    // Hours after the recorded 2 h hold no samples: honest empty cells.
    expect(lv[2].cells[5].count, 0);
    expect(lv[2].cells[5].mean, isNull);
    expect(await SpectralArchiver.summary(_day2, 'hr'), isNull);
  });

  test('reconstruct(maxOrder:) gives a coarse view that is still null in '
      'gaps', () async {
    await _freshDb('spectral_a10.db');
    await _seed(_d1);
    await SpectralArchiver.archiveDay(_day1, nowSec: _now);
    final full = (await SpectralArchiver.reconstruct(_day1, 'hr'))!;
    final coarse = (await SpectralArchiver.reconstruct(_day1, 'hr', maxOrder: 0))!;
    expect(coarse.length, full.length);
    for (var i = 0; i < full.length; i++) {
      expect(coarse[i] == null, full[i] == null, reason: 'slot $i');
    }
  });

  test('the encode runs off the UI isolate (invariant 10)', () {
    final src = stripCommentsAndStrings(
        File('lib/data/spectral_archive.dart').readAsStringSync());
    expect(src, contains('Isolate.run('));
  });
}
