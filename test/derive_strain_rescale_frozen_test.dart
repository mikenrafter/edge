// P4a: the strain rescale backfill writes a kAlgoVersion row from an OLDER
// served row only when no finalized kAlgoVersion row exists for the day, and
// never touches one that does. Assumed API: see support.dart (nothing new is
// referenced). This pins behaviour that is already true today by a different
// route (the served row IS the kAlgoVersion row), so it must stay green once the
// putDayResult guard lands rather than turn red.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/compute/strain_backfill.dart';

import 'support/frozen_day_result_fixtures.dart';

const _newest = '2026-07-20';
const _older = '2026-07-09';
const _current = '2026-07-10';

String _payload(String day, double strain) => jsonEncode({
  'date': day,
  'scalars': {'trimp': 177.8, 'strain': strain, 'worn_min': 900.0},
  'series': {
    'strain_curve': [
      for (var i = 0; i < 611; i++) {'t': i * 60, 'v': strain},
    ],
  },
});

Future<void> _seed(
  Database db,
  String day, {
  required int version,
  required double strain,
  required bool finalized,
}) async {
  await seedRow(
    db,
    day,
    version: version,
    finalized: finalized,
    payload: _payload(day, strain),
    series: {'trimp': 177.8, 'strain': strain},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUp(() async {
    db = await freshDb('openstrap_p4a_strain_rescale_test.db');
    // The newest day only sets the retention cutoff; it is never rescaled.
    await _seed(db, _newest, version: kAlgoVersion, strain: 5.0, finalized: false);
  });
  tearDownAll(dropDb);

  test('writes a kAlgoVersion row from an older served row when none exists',
      () async {
    await _seed(db, _older,
        version: kAlgoVersion - 1, strain: 12.79, finalized: true);

    final r = await backfillStrainScale(female: false, force: true);

    expect(r.bundleDays, 1);
    final next = (await rowOf(db, _older))!;
    expect(next['computed_at'], isNot(kSeedComputedAt));
    final strain =
        ((jsonDecode(next['payload_json'] as String)['scalars'] as Map)['strain']
                as num)
            .toDouble();
    expect(strain, closeTo(9.03, 0.05));
    expect(await seriesOf(db, _older, 'strain'), closeTo(9.03, 0.05));
    expect((await rowOf(db, _older, version: kAlgoVersion - 1))!['computed_at'],
        kSeedComputedAt,
        reason: 'the older generation is left exactly as it was');
  });

  test('never rewrites a finalized kAlgoVersion row', () async {
    await _seed(db, _current,
        version: kAlgoVersion, strain: 12.79, finalized: true);
    final before = (await rowOf(db, _current))!;

    final r = await backfillStrainScale(female: false, force: true);

    expect(r.bundleDays, 0);
    expect(await rowOf(db, _current), before,
        reason: 'payload, computed_at and finalized all unchanged');
    expect(await seriesOf(db, _current, 'strain'), 12.79);
  });

  test('a finalized kAlgoVersion row beside an older one stays frozen', () async {
    await _seed(db, _current,
        version: kAlgoVersion - 1, strain: 12.79, finalized: true);
    await _seed(db, _current,
        version: kAlgoVersion, strain: 7.5, finalized: true);
    final before = (await rowOf(db, _current))!;

    await backfillStrainScale(female: false, force: true);

    expect(await rowOf(db, _current), before);
    expect(await seriesOf(db, _current, 'strain'), 7.5,
        reason: 'metric_series untouched too (the value the V row was seeded with)');
  });
}
