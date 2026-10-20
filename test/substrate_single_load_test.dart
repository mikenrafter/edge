// Single substrate load per pass (RED). A cold heavy pass reads overlapping
// decoded ranges for every day: `load_search` (the night search window, 12 h
// back from midnight to the day's end), `load_day` (midnight to midnight plus
// the 3 h nap buffer) and `load_sleep` (the staged night). The same night is
// paged through the prepare worker up to three times, and its beats read as
// often. Warm passes reuse a retained load (`substrate_reused_rows_*`); cold
// passes do not. Plan: per pass, load the union a day needs once and slice it
// in memory (`Substrate.slice` / `sliceIdx`), keeping one or two days of rows
// resident at a time.
//
// FIXTURE. Three consecutive local days, T-3 .. T-1, each fully populated at
// 1 Hz (daytime and a 22:00-07:00 night) with one RR beat per second, so every
// window overlaps its neighbours. All of it is inside the 3-day raw retention.
//
// HOW READS ARE COUNTED. No new counter: the engine's own `DerivePerf` counts
// (`rows_load_*` = decoded_onehz rows paged, `rr_rows_read` = day beats,
// `rr_rows_load_search` / `rr_rows_load_sleep` = the night loads' beats), read
// back from `perf.summary()['counts']` after one heavy pass. Only the three
// labels the plan merges are summed; `load_kcal` is a separate artifact load
// and is left out.
//
// SEAMS (both `@visibleForTesting` on `DerivationEngine`; defaults are today's
// behaviour, so these tests compile and fail on behaviour):
//   bool debugDisableSubstrateUnionLoad    false; true = per-window loads
//   int  debugSubstrateRowsHeldHighWater   most rows the loader held at once
//                                          for one day (loads alive together;
//                                          slices of a held load not counted).
//                                          The green phase must book the union
//                                          substrate it holds here.
//
// RED REASONS TODAY
//   1a onehz   rows read is about 3x the rows stored (expected <= stored + slack)
//   1b rr      beats read is about 2-3x the beats stored
//   1c control (passes today) the per-window path really re-reads: with the
//              seam true the pass reads > 1.5x the stored rows
//   2  law     passes today (the seam changes nothing yet); it guards the green
//              phase: the union load must not move a stored byte
//   3  memory  passes today (one day + buffer, plus the night, are held); it
//              must stay green when the union is loaded
//   4a gap law passes today; a gap and an archive-pruned head must load the
//              same through both paths
//   4b gap read red today for the same reason as 1a, on the gapped data
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_perf.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;

import 'support/frozen_day_result_fixtures.dart' show dropDb, freshDb;

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

const _days = 3;
const _pageSlack = 2000; // one pager page (_rawDecodeBatchSize): a seam second
const _secPerDay = 86400;

int _at(DateTime day, int hour, [int minute = 0]) =>
    DateTime(day.year, day.month, day.day, hour, minute)
        .millisecondsSinceEpoch ~/
    1000;

DateTime _midnight(int daysAgo) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - daysAgo);
}

/// 22:00-07:00 is the night, the rest of the day is awake and moving.
bool _isNight(int ts) {
  final h = DateTime.fromMillisecondsSinceEpoch(ts * 1000).hour;
  return h >= 22 || h < 7;
}

int _hr(int ts) => _isNight(ts) ? 52 + ts % 7 : 74 + ts % 19;

Future<void> _seedRange(int from, int to) async {
  final db = await LocalDb.instance;
  for (var chunk = from; chunk < to; chunk += 6 * 3600) {
    final b = db.batch();
    for (var ts = chunk; ts < to && ts < chunk + 6 * 3600; ts++) {
      final hr = _hr(ts);
      b.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': ts,
        'hr': hr,
        'ax': _isNight(ts) ? 0.0 : 0.05 * ((ts % 13) - 6),
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      b.insert('decoded_rr', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'beat_index': 0,
        'rr_ts_ms': ts * 1000,
        'rr_ms': 60000 ~/ hr + (ts % 5) * 4,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
  }
}

/// Everything a pass persists, minus the wall-clock stamp.
Future<String> _snapshot() async {
  final db = await LocalDb.instance;
  final results = await db.query('day_result', orderBy: 'day_id, algo_version');
  final series = await db.query('metric_series', orderBy: 'date, key');
  return jsonEncode({
    'day_result': [
      for (final r in results)
        {
          for (final e in r.entries)
            if (e.key == 'payload_json')
              e.key: jsonEncode(
                  (jsonDecode(e.value as String) as Map)..remove('computed_at'))
            else if (e.key != 'computed_at')
              e.key: e.value,
        }
    ],
    'metric_series': [for (final r in series) Map<String, Object?>.of(r)],
  });
}

class _Run {
  _Run(this.counts, this.snapshot, this.held, this.derived, this.onehzRows,
      this.rrRows);
  final Map<String, int> counts;
  final String snapshot;
  final int held;
  final int derived;

  /// Rows in the tables when the pass started.
  final int onehzRows;
  final int rrRows;

  int _sum(Iterable<String> keys) => keys.fold(0, (a, k) => a + (counts[k] ?? 0));

  /// decoded_onehz rows paged by the three loads the plan merges.
  int get onehzRead => _sum(['rows_load_search', 'rows_load_day', 'rows_load_sleep']);

  /// decoded_rr beats read by the same three loads.
  int get rrRead =>
      _sum(['rr_rows_load_search', 'rr_rows_read', 'rr_rows_load_sleep']);

  String describe() =>
      'rows_load_search=${counts['rows_load_search']} '
      'rows_load_day=${counts['rows_load_day']} '
      'rows_load_sleep=${counts['rows_load_sleep']} '
      'rr_rows_load_search=${counts['rr_rows_load_search']} '
      'rr_rows_read=${counts['rr_rows_read']} '
      'rr_rows_load_sleep=${counts['rr_rows_load_sleep']} '
      '(stored onehz=$onehzRows rr=$rrRows)';
}

/// A cold heavy pass over the three days on a fresh database. [mutate] runs
/// after seeding, before the pass.
Future<_Run> _pass(
  String dbName, {
  required bool unionDisabled,
  Future<void> Function()? mutate,
}) async {
  await freshDb(dbName);
  for (var k = _days; k >= 1; k--) {
    await _seedRange(_at(_midnight(k), 0), _at(_midnight(k - 1), 0));
  }
  if (mutate != null) await mutate();
  final db = await LocalDb.instance;
  final onehz = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM decoded_onehz'))!;
  final rr = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM decoded_rr'))!;
  final perf = DerivePerf(nowMs: () => DateTime.now().millisecondsSinceEpoch);
  final engine = DerivationEngine(perf: perf)
    ..debugDisableSubstrateUnionLoad = unionDisabled;
  final n = await engine.run(_profile, heavy: true);
  final counts = (perf.summary()['counts'] as Map).cast<String, int>();
  final snap = await _snapshot();
  final run = _Run(counts, snap, engine.debugSubstrateRowsHeldHighWater, n,
      onehz, rr);
  await dropDb();
  return run;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(dropDb);

  group('three consecutive full days, cold heavy pass', () {
    late _Run union; // default engine
    late _Run perWindow; // debugDisableSubstrateUnionLoad = true

    setUpAll(() async {
      union = await _pass('substrate_single_load_a.db', unionDisabled: false);
      perWindow =
          await _pass('substrate_single_load_b.db', unionDisabled: true);
    });

    test('guard (passes today): the pass derived every day from the seed', () {
      expect(union.derived, _days);
      expect(perWindow.derived, _days);
      expect(union.onehzRows, greaterThan(_days * _secPerDay - 3600 * 2),
          reason: 'fixture: the three days are stored whole');
      expect(union.rrRows, union.onehzRows, reason: 'one beat per second');
    });

    test('1a onehz: every stored decoded_onehz row is read at most once',
        () {
      expect(union.onehzRead, lessThanOrEqualTo(union.onehzRows + _pageSlack),
          reason: 'search + day + sleep loads page the same night again; '
              'a per-pass union load reads each row once. ${union.describe()}');
    });

    test('1b rr: every stored decoded_rr beat is read at most once', () {
      expect(union.rrRead, lessThanOrEqualTo(union.rrRows + _pageSlack),
          reason: 'the night loads re-read the beats of seconds already '
              'loaded. ${union.describe()}');
    });

    test('1c control (passes today): the per-window path does re-read, so the '
        'counters above can see the difference', () {
      expect(perWindow.onehzRead, greaterThan(union.onehzRows * 3 ~/ 2),
          reason: perWindow.describe());
    });

    test('2 law: the union load changes no persisted byte', () {
      expect(union.snapshot, isNotEmpty);
      final u = jsonDecode(union.snapshot) as Map;
      final w = jsonDecode(perWindow.snapshot) as Map;
      expect(u['day_result'] as List, hasLength(greaterThanOrEqualTo(_days)));
      expect(u['metric_series'] as List, isNotEmpty);
      expect(jsonEncode(u['day_result']), jsonEncode(w['day_result']),
          reason: 'day_result payloads (minus computed_at)');
      expect(jsonEncode(u['metric_series']), jsonEncode(w['metric_series']),
          reason: 'metric_series rows');
    });

    test('3 memory: the loader never holds more than two days of rows plus '
        'its window slack at once', () {
      // Slack: the 12 h night lookback and the 3 h nap buffer a window adds
      // around its day.
      const bound = 2 * _secPerDay + (12 + 3) * 3600;
      expect(union.held, greaterThan(0),
          reason: 'the seam must be fed by the loader');
      expect(union.held, lessThanOrEqualTo(bound),
          reason: 'loading the whole pass at once would hold ~3 days '
              '(${_days * _secPerDay} rows)');
      expect(perWindow.held, lessThanOrEqualTo(bound));
    });
  });

  group('a gap inside a night and an archive-pruned head', () {
    late _Run union;
    late _Run perWindow;

    // A 2 h hole in the middle day's night (rows lost, not pruned), and the
    // first day's first five hours pruned through the archive path.
    Future<void> mutate() async {
      final db = await LocalDb.instance;
      final holeFrom = _at(_midnight(2), 3);
      final holeTo = _at(_midnight(2), 5);
      for (final t in ['decoded_onehz', 'decoded_rr']) {
        await db.delete(t,
            where: 'rec_ts >= ? AND rec_ts < ?', whereArgs: [holeFrom, holeTo]);
      }
      await LocalDb.pruneDecodedBeforeRecTs(_at(_midnight(3), 5));
    }

    setUpAll(() async {
      union = await _pass('substrate_single_load_c.db',
          unionDisabled: false, mutate: mutate);
      perWindow = await _pass('substrate_single_load_d.db',
          unionDisabled: true, mutate: mutate);
    });

    test('guard (passes today): rows are missing and the days still derive',
        () {
      expect(union.onehzRows, lessThan(_days * _secPerDay - 2 * 3600),
          reason: 'fixture: the hole and the pruned head are gone');
      expect(union.derived, greaterThanOrEqualTo(2));
      expect(union.derived, perWindow.derived);
    });

    test('4a law: gap and pruned range load the same through both paths', () {
      final u = jsonDecode(union.snapshot) as Map;
      final w = jsonDecode(perWindow.snapshot) as Map;
      expect(u['day_result'] as List, isNotEmpty);
      expect(jsonEncode(u['day_result']), jsonEncode(w['day_result']));
      expect(jsonEncode(u['metric_series']), jsonEncode(w['metric_series']));
    });

    test('4b read: with a gap in the range, each stored row is still read at '
        'most once', () {
      expect(union.onehzRead, lessThanOrEqualTo(union.onehzRows + _pageSlack),
          reason: union.describe());
      expect(union.rrRead, lessThanOrEqualTo(union.rrRows + _pageSlack),
          reason: union.describe());
    });
  });
}
