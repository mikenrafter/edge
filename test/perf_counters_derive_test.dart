// P2.0a, desktop part: perf counters on the derive side (design 02 step 2
// scope, sections 2 A1/B14 and 5 P2.0a). RED: none of these counters exists
// yet. They are booked on `DerivationEngine.perf` (read back with
// `perf.summary()['counts' | 'stages']`, like `rows_load_day` today), one set
// per substrate load, keyed by the load's label (`load_day`, `load_search`,
// `load_sleep`, `load_kcal`):
//
//   counts
//     pager_pages_<label>   pages the keyset pager read (non-empty pages)
//     pager_rows_<label>    their rows; equals the existing rows_<label>
//     pager_bytes_<label>   rowsByteEstimate over those rows (as the platform
//                           channel delivered them, before composeOneHzFrames)
//     worker_spawns_<label> prepare workers spawned for the load (one)
//     substrate_adopt_samples_<label>
//                           samples of the Substrate the UI isolate adopted
//   stages (milliseconds, from the engine's own clock like load_* today)
//     worker_spawn_<label>      Isolate.spawn plus the ready handshake
//     substrate_adopt_<label>   Substrate.fromJson of the worker's map (what
//                               P2.4 turns into fromTransfer)
//
// The seed is fixed: 3 h of 1 Hz decoded_onehz rows on a fixed local day, one
// device, hr 0 (so no night is staged and the day path is the only reader):
// 10,800 rows = 5 full pages of _rawDecodeBatchSize (2,000) and a page of 800.
// Elapsed times come from the engine's clock and cannot be fixed here; they are
// pinned only as present and plausible (0 .. 60 s), the exact values are the
// device trace's job (the other half of P2.0a, owner's phone).
//
// "Disabled": the engine takes `perf:`; a `DerivePerf(enabled: false)` records
// nothing and the pass returns what an enabled one returns.

@Timeout(Duration(minutes: 5))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_perf.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/last_result_db.dart';

const _db = 'perf_counters_derive_test.db';
const _dayId = '2025-09-02';
const _pageSize = 2000; // DerivationEngine._rawDecodeBatchSize
const _rows = 3 * 3600;

final _start = DateTime(2025, 9, 2, 8).millisecondsSinceEpoch ~/ 1000;

Future<void> _seed() async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var i = 0; i < _rows; i++) {
    final ts = _start + i;
    batch.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts,
      'hr': 0,
      'ax': 0.01 * (i % 7),
      'ay': 0.0,
      'az': 1.0,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

Map<String, int> _map(DerivePerf p, String which) =>
    (p.summary()[which] as Map).cast<String, int>();

/// Seeds a fresh database and derives the fixed day with [perf].
Future<int> _derive(DerivePerf perf) async {
  await g1FreshDb(_db);
  await LocalDb.instance;
  await _seed();
  return DerivationEngine(perf: perf)
      .runDays(const Profile(), {_dayId}, force: true);
}

DerivePerf _perf({bool enabled = true}) => DerivePerf(
    nowMs: () => DateTime.now().millisecondsSinceEpoch, enabled: enabled);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() => g1DropDb(_db));

  group('an enabled pass', () {
    late DerivePerf perf;
    late int days;
    late int expectBytes;

    setUpAll(() async {
      perf = _perf();
      days = await _derive(perf);
      final all = await LocalDb.decodedOneHzBatchByRecTsRange(
          limit: 100000, fromRecTs: _start - 1, toRecTs: _start + _rows + 1);
      expect(all, hasLength(_rows), reason: 'guard: the seed is all derivable');
      expectBytes = rowsByteEstimate(all);
    });

    test('guard (passes today): the pass derived the day and read the seeded '
        'rows through the pager', () {
      expect(days, 1);
      expect(_map(perf, 'counts')['rows_load_day'], _rows,
          reason: 'one load_day over the seeded day');
    });

    test('the pager books pages, rows and bytes per load', () {
      final c = _map(perf, 'counts');
      expect(c['pager_pages_load_day'], (_rows / _pageSize).ceil());
      expect(c['pager_rows_load_day'], _rows);
      expect(c['pager_bytes_load_day'], expectBytes);
      expect(expectBytes, greaterThan(_rows * 8),
          reason: 'plausible: at least one 8-byte cell per row');
    });

    test('every load that read rows has the same counter set, keyed by its '
        'label', () {
      final c = _map(perf, 'counts');
      final s = _map(perf, 'stages');
      final labels = [
        for (final k in c.keys)
          if (k.startsWith('rows_')) k.substring('rows_'.length),
      ];
      expect(labels, contains('load_day'));
      for (final l in labels) {
        expect(c['pager_rows_$l'], c['rows_$l'], reason: l);
        expect(c['worker_spawns_$l'], isNotNull, reason: l);
        expect(c['worker_spawns_$l'], greaterThanOrEqualTo(1), reason: l);
        expect(s['worker_spawn_$l'], inInclusiveRange(0, 60000), reason: l);
        expect(s['substrate_adopt_$l'], inInclusiveRange(0, 60000), reason: l);
      }
    });

    test('Substrate adoption books its samples and its time', () {
      final c = _map(perf, 'counts');
      expect(c['substrate_adopt_samples_load_day'], _rows,
          reason: 'one device at 1 Hz, no gaps: one sample per seeded second');
      expect(_map(perf, 'stages')['substrate_adopt_load_day'],
          inInclusiveRange(0, 60000));
    });

    test('worker spawn books one spawn for the one load_day', () {
      expect(_map(perf, 'counts')['worker_spawns_load_day'], 1);
      expect(_map(perf, 'stages')['worker_spawn_load_day'],
          inInclusiveRange(0, 60000));
    });

    test('the log line carries the new counters', () {
      final line = perf.logLine();
      expect(line, contains('pager_bytes_load_day:'));
      expect(line, contains('worker_spawn_load_day:'));
    });
  });

  group('a disabled pass', () {
    test('records nothing and derives the same number of days', () async {
      final enabledDays = await _derive(_perf());
      final off = _perf(enabled: false);
      final disabledDays = await _derive(off);

      expect(disabledDays, enabledDays);
      expect(off.summary()['counts'], isEmpty);
      expect(off.summary()['stages'], isEmpty);
    });
  });
}
