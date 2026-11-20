// The baseline rescan re-derives a day only when the history that day reads
// moved (or its own inputs did). CLAIM(rescan-scope) [pilot-7 churn, owner m385].
// A day reads only entries strictly BEFORE it, so a sync that moved today's
// values leaves every older day (and today) alone.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

typedef _S = Map<String, List<({String date, double value})>>;

_S _series(double d1, double d2, double d3) => {
      'rhr': [
        (date: '2026-11-18', value: d1),
        (date: '2026-11-19', value: d2),
        (date: '2026-11-20', value: d3),
      ],
      'rmssd': [
        (date: '2026-11-18', value: 40),
        (date: '2026-11-19', value: 41),
        (date: '2026-11-20', value: 42),
      ],
    };

const _days = ['2026-11-18', '2026-11-19', '2026-11-20'];

/// Scope after a derive at [then] and a rescan trigger at [now]; every day's own
/// inputs unchanged.
List<String> _scope(_S then, _S now,
    {Map<String, String?>? ownStored, Set<String> unrecorded = const {}}) {
  final stored = {
    for (final d in _days)
      if (!unrecorded.contains(d)) d: DerivationEngine.debugInputsBefore(then, d),
  };
  return DerivationEngine.rescanScope(
    days: _days,
    inputsNow: (d) => DerivationEngine.debugInputsBefore(now, d),
    inputsStored: (d) => stored[d],
    ownNow: (d) => 'own-$d',
    ownStored: (d) => (ownStored ?? const {})[d] ?? 'own-$d',
  );
}

void main() {
  test('a change to today only leaves every day alone', () {
    expect(_scope(_series(60, 61, 62), _series(60, 61, 99)), isEmpty);
  });

  test('a change to yesterday only re-derives today, nothing older', () {
    expect(_scope(_series(60, 61, 62), _series(60, 99, 62)), ['2026-11-20']);
  });

  test('a change to the oldest day re-derives the days after it', () {
    expect(_scope(_series(60, 61, 62), _series(99, 61, 62)),
        ['2026-11-19', '2026-11-20']);
  });

  test('a day with no recorded history is derived (first run after upgrade)',
      () {
    expect(
        _scope(_series(60, 61, 62), _series(60, 61, 62),
            unrecorded: {'2026-11-19'}),
        ['2026-11-19']);
  });

  test('a day whose own inputs changed is derived even if history is the same',
      () {
    expect(
        _scope(_series(60, 61, 62), _series(60, 61, 62),
            ownStored: {'2026-11-18': 'older'}),
        ['2026-11-18']);
  });
}
