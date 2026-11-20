import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  // WHY: a merge must name shipped output changes and the actual sibling pin,
  // without claiming main's deferred analytics fixes already run on the fork.
  test('the merge version names shipped changes and the retained analytics pin', () {
    expect(kAlgoVersion, 126);
    // Stale pin: the pin moved on (c8d538334, 2026-11-18: analytics 6c45f3b); the 122-125 entry below still names d876c42.
    expect(kAnalyticsPin, '6c45f3b0894e23bf5047f7cc0e34e533d0802417');
    final src = File('lib/compute/derivation_engine.dart').readAsStringSync();
    final at = src.indexOf('// 122 → 125');
    expect(at, isNonNegative);
    final entry = src.substring(at, src.indexOf('const int kAlgoVersion', at));
    for (final change in ['0.12.2', 'HMM', 'd876c42', 'night_checkpoint',
      'DAY format is unchanged', 'IncrementalMinuteMetrics', 'input order',
      '#102-#110', 'deferred']) {
      expect(entry, contains(change));
    }
  });
}
