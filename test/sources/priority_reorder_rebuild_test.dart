// Phase 4 red: reordering is current/future only; the explicit historical
// rebuild uses the new order and is idempotent (contracts 4 and 5).
//
// Fixture: the two-device night of multidevice_coverage_derive_test.dart,
// derived through the real DerivationEngine. Synthetic ids only.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/coverage_resolver.dart';
import 'package:openstrap_edge/data/db.dart';
import 'support/sources_support.dart';

const _day = '2025-09-02';

int _t(int d, int h, [int m = 0]) => sec(2025, 9, d, h, m);

/// Primary 22:00 (09-01) to 02:00; ring 01:30 to 07:00. Overlap 01:30-02:00.
Future<void> _seedNight() async {
  await insertOneHz(kPrimary, _t(1, 22), _t(2, 2), 60);
  await insertOneHz(kRing, _t(2, 1, 30), _t(2, 7), 100);
  for (final sig in [InputSignal.hr1Hz, InputSignal.rrIntervals]) {
    await insertCoverage(kPrimary, sig, _t(1, 22), _t(2, 2));
    await insertCoverage(kRing, sig, _t(2, 1, 30), _t(2, 7));
    await LocalDb.setSignalPriority(sig, [kRing, kPrimary]);
  }
  await LocalDb.putSleepOverride(
    dayId: _day,
    onsetTs: _t(1, 22),
    offsetTs: _t(2, 7),
    source: 'manual',
  );
}

/// A later night with coverage only: "future" relative to the injected clock.
Future<void> _seedFutureCoverage() async {
  for (final sig in [InputSignal.hr1Hz, InputSignal.rrIntervals]) {
    await insertCoverage(kPrimary, sig, _t(6, 22), _t(7, 2));
    await insertCoverage(kRing, sig, _t(7, 1, 30), _t(7, 7));
  }
}

Future<void> _derive() async {
  final done = await DerivationEngine().runDays(const Profile(), {_day}, force: true);
  expect(done, 1, reason: 'fixture: the night must derive');
}

Future<Map<String, Object?>> _rows() async {
  final db = await LocalDb.instance;
  Future<List<Map<String, Object?>>> q(String sql) async => [
    for (final r in await db.rawQuery(sql)) Map<String, Object?>.from(r),
  ];
  return {
    'day_result': await q('SELECT * FROM day_result ORDER BY day_id, algo_version'),
    'metric_series': await q('SELECT * FROM metric_series ORDER BY date, key'),
    'metric_series_version': await q(
      'SELECT * FROM metric_series_version ORDER BY date',
    ),
  };
}

/// Rows with the one column a re-derive legitimately restamps removed.
Object _stable(Map<String, Object?> rows) => jsonEncode({
  ...rows,
  'day_result': [
    for (final r in rows['day_result']! as List)
      {...(r as Map<String, Object?>)}..remove('computed_at'),
  ],
});

void main() {
  useSourcesDb('sources_priority_reorder_test.db');

  final histFrom = _t(1, 22), histTo = _t(2, 7);
  final futFrom = _t(6, 22), futTo = _t(7, 7);
  final sample = _t(2, 1, 50); // inside the 01:30-02:00 contested interval
  final futSample = _t(7, 1, 50);
  DateTime now() => DateTime(2025, 9, 5, 12);

  Future<Map<String, Object?>> snapshot(dynamic svc) async => {
    'historical': await resolveJson(svc, InputSignal.hr1Hz, histFrom, histTo),
    'future': await resolveJson(svc, InputSignal.hr1Hz, futFrom, futTo),
  };

  test('reordering changes current and future resolution only', () async {
    final svc = openService(sources: [kBand, kRingSource], now: now);
    await _seedNight();
    await _seedFutureCoverage();
    await _derive();

    final before = await snapshot(svc);
    final rowsBefore = await _rows();
    expect(at(before['historical']! as List<Map<String, Object?>>, sample)['winner'], kRing);
    expect(at(before['future']! as List<Map<String, Object?>>, futSample)['winner'], kRing);

    for (final sig in [InputSignal.hr1Hz, InputSignal.rrIntervals]) {
      await sourcesAsync<void>(
        'SourceService.savePriority(signal, order) writing current/future order',
        () async => await svc.savePriority(sig, [kPrimary, kRing]),
      );
    }
    expect(await LocalDb.signalPriority(InputSignal.hr1Hz), [kPrimary, kRing],
        reason: 'the new order is stored for current/future computation');

    final after = await snapshot(svc);
    final rowsAfter = await _rows();
    final histBefore = before['historical']! as List<Map<String, Object?>>;
    final histAfter = after['historical']! as List<Map<String, Object?>>;
    expect(histAfter, histBefore,
        reason: 'historical resolved intervals do not move on a reorder');
    expect(at(histAfter, sample)['winner'], kRing);
    expect(rowsAfter, rowsBefore,
        reason: 'persisted day_result / metric_series rows are untouched');
    expect(at(after['future']! as List<Map<String, Object?>>, futSample)['winner'], kPrimary,
        reason: 'future intervals follow the new order');

    // Deterministic, machine-readable proof: selected source ids and the
    // unchanged historical rows.
    writeArtifact('priority_reorder_resolved_intervals.json', {
      'fixture': 'two-device-night',
      'signal': 'hr1Hz',
      'clock': now().toIso8601String(),
      'orderBefore': [kRing, kPrimary],
      'orderAfter': [kPrimary, kRing],
      'selectedSourceIds': {
        'historicalBefore': at(histBefore, sample)['winner'],
        'historicalAfter': at(histAfter, sample)['winner'],
        'futureBefore': at(before['future']! as List<Map<String, Object?>>, futSample)['winner'],
        'futureAfter': at(after['future']! as List<Map<String, Object?>>, futSample)['winner'],
      },
      'resolvedIntervals': {'before': before, 'after': after},
      'historicalRowsUnchanged': rowsAfter.toString() == rowsBefore.toString(),
    });
  });

  group('Rebuild history with this priority', () {
    Future<Map<String, Object?>> rebuild() async {
      final dynamic engine = DerivationEngine();
      final result = await sourcesAsync<dynamic>(
        'DerivationEngine.rebuildHistoryWithPriority(Profile, days:) as the '
        'explicit Advanced action',
        () async => await engine.rebuildHistoryWithPriority(
          const Profile(),
          days: {_day},
        ),
      );
      final map = Map<String, Object?>.from(result as Map);
      requireKeys(map, ['days', 'priorityKey'], 'rebuild result');
      return map;
    }

    Future<List<OwnedSpan>> storedSpans() async {
      final row = await LocalDb.dayResult(_day);
      final bundle = jsonDecode(row!['payload_json'] as String) as Map;
      final coverage = ((bundle['series'] as Map)['coverage'] as Map);
      return coverageFromJson(coverage['hr1Hz']);
    }

    Future<String?> stampedPriority() async {
      final db = await LocalDb.instance;
      final r = await db.query('metric_series_version',
          columns: ['priority_hash'], where: 'date = ?', whereArgs: [_day]);
      return r.isEmpty ? null : r.first['priority_hash'] as String?;
    }

    Future<void> reorderAndDerive() async {
      await _seedNight();
      await _derive();
      for (final sig in [InputSignal.hr1Hz, InputSignal.rrIntervals]) {
        await LocalDb.setSignalPriority(sig, [kPrimary, kRing]);
      }
    }

    test('re-derives history under the new order and the view follows',
        () async {
      final svc = openService(sources: [kBand, kRingSource], now: now);
      await reorderAndDerive();
      final oldKey = await stampedPriority();
      expect(spanAt(await storedSpans(), sample)?.deviceId, kRing,
          reason: 'fixture: derived under the old order');
      expect(
        at(await resolveJson(svc, InputSignal.hr1Hz, histFrom, histTo), sample)['winner'],
        kRing,
        reason: 'the view keeps showing history under the order it derived with',
      );

      final result = await rebuild();
      expect(result['days'], contains(_day));
      expect(result['priorityKey'], isNot(oldKey));
      expect(result['priorityKey'] as String, contains('hr1Hz=|$kRing'),
          reason: 'the key encodes the new order: primary first, ring second');
      expect(await stampedPriority(), result['priorityKey'],
          reason: 'the rebuilt day is stamped with the order it used');
      expect(spanAt(await storedSpans(), sample)?.deviceId, kPrimary,
          reason: 'the contested interval now belongs to the new first choice');
      expect(
        at(await resolveJson(svc, InputSignal.hr1Hz, histFrom, histTo), sample)['winner'],
        kPrimary,
        reason: 'after a rebuild the resolved view reflects the new history',
      );
    });

    test('is idempotent: a second rebuild leaves identical rows', () async {
      await reorderAndDerive();
      final first = await rebuild();
      final afterOne = await _rows();
      final second = await rebuild();
      final afterTwo = await _rows();

      expect(second['days'], first['days']);
      expect(second['priorityKey'], first['priorityKey']);
      expect(_stable(afterTwo), _stable(afterOne),
          reason: 'same bundle, same series, same stamp the second time');
      final db = await LocalDb.instance;
      final n = (await db.rawQuery(
        'SELECT COUNT(*) AS n FROM day_result WHERE day_id = ? AND algo_version = ?',
        [_day, kAlgoVersion],
      )).first['n'];
      expect(n, 1, reason: 'one immutable row per (day, version), not two');
      expect(afterTwo['metric_series'], afterOne['metric_series'],
          reason: 'no duplicate-day append into the baseline series');
    });
  });
}
