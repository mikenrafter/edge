import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';

void main() {
  test(
    'daytime assertion attributed to next day retains input before automatic noon',
    () {
      final start = DateTime(2026, 9, 29, 8).millisecondsSinceEpoch ~/ 1000;
      final ts = List<int>.generate(5 * 3600 + 1, (i) => start + i);
      final sub = Substrate(
        tsSec: ts,
        hr: List.filled(ts.length, 50),
        rrTsMs: const [],
        rrMs: const [],
        ax: List.filled(ts.length, .02),
        ay: List.filled(ts.length, .02),
        az: List.filled(ts.length, 1.0),
        spo2Red: List.filled(ts.length, 0),
        spo2Ir: List.filled(ts.length, 0),
        skinTemp: List.filled(ts.length, 0),
        skinContact: List.filled(ts.length, 0),
      );
      final candidate = prepareSleepSessionCandidate(
        sub,
        targetDay: '2026-09-30',
        override: SleepWindowOverride(
          dayId: '2026-09-30',
          onsetSec: start + 1800,
          offsetSec: start + 4 * 3600 + 1800,
          source: 'confirmed',
        ),
      );
      expect(candidate.dayId, '2026-09-30');
      expect(candidate.sleepSource, 'confirmed');
      expect(candidate.present, isTrue);
      expect(candidate.sleepOnsetSec, lessThan(start + 3600));
      expect(candidate.sleepOffsetSec, greaterThan(start + 4 * 3600));
    },
  );
}
