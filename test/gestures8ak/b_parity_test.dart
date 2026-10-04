// 8AK B (red): PARITY across the two gesture categories.
//
// USER: equal activation counts produce identical cue sequences, whichever way
// they were made:
//
//   1 double tap        == ECG count 2   -> [start, confirm]
//   2 double taps       == ECG count 3   -> [start, follow, confirm]
//   3 double taps       == ECG count 4   -> [start, follow, follow, confirm]
//   4 double taps       == ECG count 5   -> [start, follow, follow, follow,
//                                            confirm]
//
// The count is the same number in both categories (the opening double tap is
// count 2; every further double tap, or every ECG touch, is one more). Each
// side is driven through its own real session with its cues recorded:
// EcgTapSession (ECG) and DoubleTapRepeatSession (plain double taps, "More
// double taps"), both with the same max (5). Timing is a separate matter
// (b_double_tap_timing_test.dart, a_ecg_window_after_followup_test.dart).
//
// ASSUMED API: as b_double_tap_cues_test.dart (start/confirm cue parameters of
// DoubleTapRepeatSession). Failure mode today: the plain route has no start
// and no confirm, so its sequence is [] for one double tap and
// [follow, ...] without start/confirm for the rest.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ak_ecg_rig.dart';
import 'support/ak_repeat_rig.dart';

const Map<int, List<String>> _expected = {
  2: ['start', 'confirm'],
  3: ['start', 'follow', 'confirm'],
  4: ['start', 'follow', 'follow', 'confirm'],
  5: ['start', 'follow', 'follow', 'follow', 'confirm'],
};

/// The cues of an ECG gesture that ends at [count] (max 5).
Future<List<String>> _ecg(int count) async {
  final r = AkEcgRig(max: 5);
  await r.tap();
  await r.steady();
  if (count >= 3) await r.touchThree();
  if (count >= 4) await r.touchFour();
  if (count >= 5) await r.touchFive();
  if (count < 5) {
    // The window runs out on quiet packets.
    await r.frame(1002 + (count - 2));
    await r.frame(1003 + (count - 2));
    await r.frame(1004 + (count - 2));
  }
  expect(r.results, [(count, null)], reason: 'ECG count $count');
  return r.names;
}

/// The cues of a plain double-tap gesture of [count - 1] double taps (max 5).
List<String> _repeat(int count) {
  late List<String> names;
  fakeAsync((async) {
    final r = AkRepeatRig(max: 5)..begin(repTap());
    for (var k = 1; k <= count - 2; k++) {
      async.elapse(const Duration(milliseconds: 700));
      r.session.add(repTap(sec: k));
    }
    async.elapse(const Duration(seconds: 4));
    expect(r.result, count, reason: '${count - 1} double taps');
    names = r.names;
  });
  return names;
}

void main() {
  for (final count in _expected.keys) {
    test('${count - 1} double ${count == 2 ? 'tap' : 'taps'} == ECG count '
        '$count: ${_expected[count]!.join(', ')}', () async {
      final ecg = await _ecg(count);
      final plain = _repeat(count);
      expect(ecg, _expected[count], reason: 'the ECG route (the reference)');
      expect(plain, _expected[count], reason: 'the plain double-tap route');
      expect(plain, ecg, reason: 'identical across the two categories');
    });
  }

  test('regression guard (passes today): the ECG side alone matches the '
      'table', () async {
    for (final count in _expected.keys) {
      expect(await _ecg(count), _expected[count], reason: 'count $count');
    }
  });
}
