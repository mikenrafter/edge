import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  // WHY: a merge must name shipped output changes and the actual sibling pin,
  // without claiming main's deferred analytics fixes already run on the fork.
  test('the merge version names shipped changes and the retained analytics pin', () {
    expect(kAlgoVersion, 126);
    expect(kAnalyticsPin, 'd876c427ce59eed95b5e54411e3b69253f294ae6');
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
