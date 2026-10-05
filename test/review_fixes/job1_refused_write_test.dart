// A derive whose write a frozen row refuses (an import landed the finalized day
// while the pass was running) did nothing: it must not be counted, reported
// done, or recorded as the day's derived input. And every pass that does write
// a day records the same fingerprint the "recordings through" line reads.

@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

import '../p4a/support.dart';

const _d1 = '2025-09-04';
const _d2 = '2025-09-05';

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

late Database _db;

Future<void> _seedRaw() async {
  final b = _db.batch();
  var c = 0;
  void run(int from, int to, int Function(int) hr) {
    for (var ts = from; ts < to; ts++) {
      b.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': c++,
        'hr': hr(ts),
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  int night(int ts) => 52 + (ts % 7);
  run(_sec(2025, 9, 3, 22, 0), _sec(2025, 9, 4, 8, 0), night);
  run(_sec(2025, 9, 4, 22, 0), _sec(2025, 9, 5, 8, 0), night);
  run(_sec(2025, 9, 6, 12, 0), _sec(2025, 9, 6, 12, 1), (_) => 70);
  await b.commit(noResult: true);
}

/// What a cloud / WHOOP import leaves for a day: finalized, `imported: true`.
Future<void> _importLands(String day) => seedRow(
  _db,
  day,
  finalized: true,
  tag: 'import',
  payload: jsonEncode({
    'imported': true,
    'scalars': {'rhr': 50.0},
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _db = await freshDb('openstrap_review_job1_refused_write_test.db');
    await _seedRaw();
  });
  tearDownAll(dropDb);

  group('a refused frozen write', () {
    test('is not reported done, counted or recorded as derived', () async {
      final done = <String>[];
      final engine = DerivationEngine()
        ..debugDayHook = (day) async {
          if (day == _d2) await _importLands(day);
        };
      await engine.run(const Profile(),
          heavy: true, onDayDone: (day, _, _) => done.add(day));

      final stored = (await rowOf(_db, _d2))!;
      expect(jsonDecode(stored['payload_json'] as String)['imported'], isTrue,
          reason: 'the import is what stands');
      expect(done, contains(_d1), reason: 'the other day was derived');
      expect(done, isNot(contains(_d2)));
      final fps = await LocalDb.derivedFingerprints(kAlgoVersion);
      expect(fps.keys, contains(_d1));
      expect(fps.keys, isNot(contains(_d2)));
    });

    test('control: without the import the same day is done and recorded',
        () async {
      final done = <String>[];
      await DerivationEngine().run(const Profile(),
          heavy: true, onDayDone: (day, _, _) => done.add(day));

      expect(done, containsAll([_d1, _d2]));
      expect((await LocalDb.derivedFingerprints(kAlgoVersion)).keys,
          containsAll([_d1, _d2]));
    });
  });

  group('derived fingerprints', () {
    Future<void> expectRecorded(String day) async {
      final own = (await LocalDb.decodedDayFingerprints([day]))[day]!;
      expect(await LocalDb.derivedFingerprintMaxRecTs(day, kAlgoVersion),
          int.parse(own.split(':').first),
          reason: 'the reader finds the day\'s own MAX(rec_ts)');
    }

    test('run() records one the recordings-through reader can read', () async {
      await DerivationEngine().run(const Profile(), heavy: true);
      await expectRecorded(_d1);
    });

    test('runDays() records one too', () async {
      await DerivationEngine().runDays(const Profile(), {_d1});
      await expectRecorded(_d1);
    });

    test('so does rescanRecent()', () async {
      final engine = DerivationEngine();
      await engine.runDays(const Profile(), {_d1});
      await _db.delete('compute_freshness',
          where: 'key LIKE ?', whereArgs: ['derived_fp:%']);
      expect(await LocalDb.derivedFingerprintMaxRecTs(_d1, kAlgoVersion),
          isNull);

      expect(await engine.rescanRecent(const Profile()), greaterThan(0));
      await expectRecorded(_d1);
    });
  });
}
