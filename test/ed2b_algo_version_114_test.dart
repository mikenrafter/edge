import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  test('ED-2b takes one version bump and names the output changes', () {
    expect(kAlgoVersion, 114);
    expect(kAnalyticsPin, 'c32007f83094c1fb39553301e5967052f8ba9dd5');
    final src = File('lib/compute/derivation_engine.dart').readAsStringSync();
    final at = src.indexOf('// 113 → 114');
    expect(at, isNonNegative);
    final entry = src.substring(at, src.indexOf('const int kAlgoVersion', at));
    for (final change in ['c32007f', '32', 'hrvTime', 'banisterTrimp',
      'ctlAtlTsb', 'cosinor', 'timeInZone', 'circadianNonparametric',
      'Lomb–Scargle', 'non-finite', 'irregular-screen gaps', 'D35', 'D36',
      'forward-only', 'staging labels unchanged']) {
      expect(entry, contains(change));
    }
  });
}
