// P4a at the engine, rescanRecent: a baseline-dirty rescan skips every day
// finalized at kAlgoVersion (it used to rewrite them to refresh readiness /
// stress against the moving baseline; that is exactly what the freeze ends),
// and still re-derives provisional days (the older-version case is in
// engine_rescan_older_version_test.dart).
// Assumed API: see support.dart (nothing new is referenced; compiles today and
// fails on behaviour).
//
// Real LocalDb + real DerivationEngine, fixed local-time fixtures (never
// DateTime.now()). Raw fixture as in sleep_override_blanks_night_test: two quiet
// nights at 1 Hz and one lone reading on 2025-09-06 as the data edge. Every
// finalized row below is one the test seeded on purpose.
//
// One derive pass per test file: this environment's flutter_tester intermittently
// segfaults after several in-process derive passes (the existing
// sleep_override_blanks_night_test does the same).
//
// LATE-DATA NOTE: strict rule used. `derived_fp:<day>` is never consulted for a
// finalized day (run() filters finalized days out before it fingerprints), so
// there is no "fingerprint changed => rewrite" clause to pin. See the report.

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

const _d0 = '2025-09-03';
const _d1 = '2025-09-04';
const _d2 = '2025-09-05';
const _edge = '2025-09-06';

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
    _db = await freshDb('openstrap_p4a_engine_rescan_test.db');
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

    test('skips every day finalized at kAlgoVersion, and derives the rest',
        () async {
      // d1 and d2 are finalized at V; d0 and the data-edge day are provisional.
      await _sentinel(_d1);
      await _sentinel(_d2);
      await _sentinel(_d0, finalized: false);
      final frozen = [for (final d in [_d1, _d2]) (await rowOf(_db, d))!];

      final scope = await rescan();

      expect(scope.toSet().intersection({_d1, _d2}), isEmpty,
          reason: 'finalized days are not even in the rescan scope');
      expect(scope, contains(_d0));
      expect([for (final d in [_d1, _d2]) (await rowOf(_db, d))!], frozen,
          reason: 'payload, computed_at, finalized, scalars all unchanged');
      for (final d in [_d1, _d2]) {
        expect(await seriesOf(_db, d, 'rhr'), 50.0);
        expect(await seriesOf(_db, d, 'readiness'), 70.0);
      }
      // The data-edge day, not d0: it has no row yet, and the engine keeps a
      // day whose night raw is already pruned (edge#305), so d0 is reached
      // but legitimately not rewritten.
      expect(await rowOf(_db, _edge), isNotNull,
          reason: 'a day that is not finalized is still derived by the rescan');
    });
  });
}
