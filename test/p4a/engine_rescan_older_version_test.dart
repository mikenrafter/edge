// P4a at the engine, rescanRecent and versions: a day that is finalized only at
// an OLDER version has no frozen (day, V) row, so the rescan still reaches it and
// the older sibling is never touched. Assumed API: see support.dart (nothing new
// is referenced). Passes today; pinned so the GREEN skip filter keys on
// kAlgoVersion (`finalizedDayIds(kAlgoVersion)`) and not on "any finalized row".
// Own file: one derive pass per process (this environment's flutter_tester
// intermittently segfaults after several; see engine_rescan_test.dart).

// Each test runs whole derive passes; under full-suite load they need
// more than the default 30 s.
@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support.dart';

const _d1 = '2025-09-04';

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

/// A finalized sentinel row at [version]: a real-looking day (non-null scalars,
/// so the engine treats it as worth protecting) with a recognisable payload.
Future<void> _sentinel(
  String day, {
  int version = kAlgoVersion,
  bool finalized = true,
}) => seedRow(
  _db,
  day,
  version: version,
  finalized: finalized,
  tag: 'sentinel',
  series: {'rhr': 50.0, 'readiness': 70.0},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _db = await freshDb('openstrap_p4a_engine_rescan_older_version_test.db');
    await _seedRaw();
  });
  tearDownAll(dropDb);

  group('rescanRecent', () {
    Future<List<String>> rescan() async {
      // A stale cursor: the baseline signature differs, so the gate opens.
      await LocalDb.setCursor('baseline_sig', 'stale-signature');
      final scope = <String>[];
      await DerivationEngine().rescanRecent(
        const Profile(),
        onScopeDays: scope.addAll,
      );
      return scope;
    }

    test('reaches a day finalized only at an OLDER version', () async {
      await _sentinel(_d1, version: kAlgoVersion - 1);

      final scope = await rescan();

      expect(scope, contains(_d1),
          reason: 'no frozen (day, V) row exists to protect');
      expect((await rowOf(_db, _d1, version: kAlgoVersion - 1))!['computed_at'],
          kSeedComputedAt,
          reason: 'the older sibling is never touched');
    });
  });
}
