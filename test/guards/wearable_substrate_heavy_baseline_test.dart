// The wearable day substrate builders (canonical.dart `withStrapSessions`,
// the per-vendor readers in colmi/garmin/oura/ultrahuman_inputs.dart) decode
// rows and rebuild channels over a whole day. They run in a registered @heavy
// worker, so the heavy guard no longer finds them on the UI isolate: their
// baseline keys are gone AND a fresh analysis of lib/ reports none of them.

@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/heavy_guard.dart';

/// (file under lib/, symbol) pairs the move retires.
const Set<(String, String)> _retired = {
  ('compute/inputs/canonical.dart', 'withStrapSessions'),
  ('compute/inputs/canonical.dart', '_withStrapBeats'),
  ('compute/inputs/canonical.dart', 'wearableSubstrate'),
  ('compute/inputs/colmi_inputs.dart', 'colmiSubstrate'),
  ('compute/inputs/colmi_inputs.dart', 'colmiSkinTemps'),
  ('compute/inputs/garmin_inputs.dart', 'sparseHrSubstrate'),
  ('compute/inputs/oura_inputs.dart', 'ouraSubstrate'),
  ('compute/inputs/ultrahuman_inputs.dart', 'ultrahumanSubstrate'),
  ('compute/inputs/ultrahuman_inputs.dart', 'ultrahumanRecords'),
};

void main() {
  final repoRoot = Directory.current.path;
  tearDownAll(disposeHeavyGuardCaches);

  test('heavy_calc_baseline.json holds none of the wearable substrate builders',
      () {
    final b = (jsonDecode(
            File('$repoRoot/test/guards/heavy_calc_baseline.json')
                .readAsStringSync()) as Map)
        .cast<String, Object?>();
    final left = [
      for (final o in (b['occurrences'] as List).cast<Map>())
        if (_retired.contains((o['file'], o['symbol'])))
          '${o['rule']} ${o['file']} :: ${o['symbol']} -> ${o['element']}',
    ];
    expect(left, isEmpty,
        reason: 'still baselined (move into a @heavy worker and regenerate '
            'the baseline):\n${left.join('\n')}');
  });

  test('a fresh analysis of lib/ finds none of them on the UI isolate',
      () async {
    final r = await analyzeHeavyGuard(HeavyGuardConfig.edge(repoRoot));
    final found = [
      for (final v in r.violations)
        if (_retired.contains((v.file, v.symbol)))
          '${v.rule.name} ${v.file} :: ${v.symbol} -> ${v.element}',
    ];
    expect(found, isEmpty, reason: found.join('\n'));
    // Never made green by shrinking the guard: the structure rules still hold.
    expect([for (final v in r.violations) if (!v.rule.baselineable) v], isEmpty);
  });
}
