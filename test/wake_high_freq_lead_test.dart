// Collection must start early enough to cover warm-up plus the Natural window.
// The 90-minute lease is not enough for 120 + 20.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/high_freq_wake_window.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

void main() {
  final t = DateTime(2026, 10, 5, 7, 0);

  test('without a Natural window the lease is the historic 90 minutes', () {
    expect(HighFreqWakeWindow.leaseFor(0), HighFreqWakeWindow.lease);
    expect(HighFreqWakeWindow.lease, const Duration(minutes: 90));
  });

  test('90 minutes cannot cover the longest window: 120 + warm-up is longer',
      () {
    expect(naturalCollectionLead(120), greaterThan(HighFreqWakeWindow.lease));
  });

  for (var n = 15; n <= 120; n += 15) {
    test('window $n: the lease covers warm-up plus the window, never less '
        'than 90 minutes', () {
      final lease = HighFreqWakeWindow.leaseFor(n);
      expect(lease, greaterThanOrEqualTo(naturalCollectionLead(n)));
      expect(lease, greaterThanOrEqualTo(HighFreqWakeWindow.lease));

      HighFreqWakePlan at(Duration before) => HighFreqWakeWindow.planFromRows(
            const [],
            t.subtract(before),
            scheduledWindowEnd: t,
            scheduledWindowMinutes: n,
          );
      final justInside = at(naturalCollectionLead(n));
      expect(justInside.shouldEnable, isTrue,
          reason: 'collection is already running when warm-up must begin');
      expect(justInside.lease, lease);
      expect(at(lease + const Duration(minutes: 1)).shouldEnable, isFalse);
    });
  }

  test('the habitual window widens the same way', () {
    Map<String, dynamic> row(DateTime w) =>
        {'window_json': '{"value":{"offset_ms":${w.millisecondsSinceEpoch}}}'};
    final rows = [
      row(DateTime(2026, 10, 4, 7, 0)),
      row(DateTime(2026, 10, 3, 7, 0)),
      row(DateTime(2026, 10, 2, 7, 0)),
    ];
    final now = t.subtract(const Duration(minutes: 140));
    expect(HighFreqWakeWindow.planFromRows(rows, now).shouldEnable, isFalse);
    final wide = HighFreqWakeWindow.planFromRows(rows, now,
        scheduledWindowEnd: t, scheduledWindowMinutes: 120);
    expect(wide.shouldEnable, isTrue);
    expect(wide.targetWake, t);
  });

  test('the lease never exceeds what the band accepts (gen5: < 28800 s)', () {
    expect(HighFreqWakeWindow.leaseFor(120).inSeconds, lessThan(28800));
  });
}
