// 8AG-perf P2-B / AGENTS.md invariant 3.9 -- regression guard (passes today).
//
// A day whose derive failed transiently must never look derived to the prune
// or to `changedOnly`. P2 changes how outcomes are reported to the scheduler,
// not this: the pure selectors keep a prune-pending day, or a day whose
// fingerprint was never recorded (a transient failure records none), in the
// todo set even when nothing about its input changed. No new symbol is used.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  group('selectors keep a failed day in', () {
    test('prune-pending day is selected although its fingerprint matches', () {
      final now = DateTime(2026, 10, 10, 12).millisecondsSinceEpoch ~/ 1000;
      final pending = DerivationEngine.prunePendingDays(
        rawDays: const ['2026-10-02', '2026-10-10'],
        derivedDayIds: const {'2026-10-10'},
        dataNowSec: now,
      );
      expect(pending, {'2026-10-02'});
      expect(
        selectChangedDays(
          todoDays: const ['2026-10-02', '2026-10-10'],
          current: const {'2026-10-02': 'a', '2026-10-10': 'b'},
          derived: const {'2026-10-02': 'a', '2026-10-10': 'b'},
          prunePending: pending,
        ),
        ['2026-10-02'],
      );
    });

    test('a day with no recorded fingerprint (a transient failure records '
        'none) is selected', () {
      expect(
        selectChangedDays(
          todoDays: const ['2026-10-02'],
          current: const {'2026-10-02': 'a'},
          derived: const {},
          prunePending: const {},
        ),
        ['2026-10-02'],
      );
    });
  });
}
