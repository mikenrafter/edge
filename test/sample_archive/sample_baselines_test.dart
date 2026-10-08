// The experiment's two baselines are test support; they must be right before
// anyone trusts a comparison table built on them. These pass today (no codec).
import 'package:flutter_test/flutter_test.dart';

import '../support/sample_fixtures.dart';

void main() {
  test('fixture days are deterministic and gapped', () {
    final a = fixtureDay(), b = fixtureDay();
    for (final k in a.keys) {
      expect(a[k], b[k], reason: k);
      expect(a[k]!.length, kDay);
      expect(validCount(a[k]!), lessThan(kDay), reason: '$k has gaps');
      expect(validCount(a[k]!), greaterThan(kDay ~/ 2), reason: k);
    }
  });

  test('lossless bytes shrink for a smooth signal and the mask costs bytes',
      () {
    final flat = List<double?>.filled(10000, 70.0);
    final gapped = List<double?>.of(flat)..fillRange(100, 200, null);
    expect(losslessBytes(flat, 1.0), lessThan(100));
    expect(losslessBytes(gapped, 1.0), greaterThan(losslessBytes(flat, 1.0) - 1));
  });

  test('keep-every-Nth picks N=1 for noise and a large N for a ramp', () {
    final ramp = List<double?>.generate(4096, (t) => 60 + t / 100);
    expect(keepEveryNth(ramp, 1.0, 1.0, 3.0).n, greaterThan(16));
    final spiky = List<double?>.generate(4096, (t) => t.isEven ? 60.0 : 100.0);
    expect(keepEveryNth(spiky, 1.0, 1.0, 3.0).n, 1);
  });
}
