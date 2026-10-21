// The bytes the Device lab's alarm-slot probe writes, per band family.
// Slot 0 is probe alarm A and slot 1 is probe alarm B: gen5 ids 1 and 2 (id 0
// is rejected, id 1 is the slot the app really arms), gen4 rich-form indices 0
// and 1. The pattern is short and gentle, never the stock 30 s wake buzz.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

// 1790000000 s + 123 ms: epoch LE 80 3B B1 6A, subsec 123 * 32768 / 1000 =
// 4030 = 0x0FBE, LE BE 0F.
final DateTime _when = DateTime.fromMillisecondsSinceEpoch(1790000000123);

void main() {
  group('the probe pattern', () {
    test('is 12 bytes, one short loop, a few seconds at most', () {
      expect(AlarmPayloads.probeHaptics, hasLength(12));
      expect(AlarmPayloads.probeHaptics[10], 1, reason: 'one overall loop');
      expect(AlarmPayloads.probeHaptics[11], lessThanOrEqualTo(5),
          reason: 'max alarm duration seconds');
      expect(AlarmPayloads.probeHaptics, isNot(AlarmPayloads.defaultHaptics),
          reason: 'never the stock loop-7, 30 s wake buzz');
    });
  });

  group('arm bodies', () {
    test('gen5 never writes id 0, and only slots A and B exist', () {
      for (final slot in [0, 1]) {
        expect(
            AlarmPayloads.probeBody(_when, isGen5: true, slot: slot)[1],
            isNot(0));
      }
      expect(() => AlarmPayloads.probeBody(_when, isGen5: true, slot: 2),
          throwsArgumentError);
      expect(() => AlarmPayloads.probeBody(_when, isGen5: false, slot: -1),
          throwsArgumentError);
    });
  });

  group('readback and clear bodies', () {
    test('gen5 reads and clears by id, never the all-slots 0xFF', () {
      final readA = AlarmPayloads.probeReadBody(isGen5: true, slot: 0);
      final readB = AlarmPayloads.probeReadBody(isGen5: true, slot: 1);
      final clearA = AlarmPayloads.probeClearBody(isGen5: true, slot: 0);
      final clearB = AlarmPayloads.probeClearBody(isGen5: true, slot: 1);
      expect(readA, isNot(readB));
      expect(clearA, isNot(clearB));
      expect(clearA, isNot(contains(0xFF)));
      expect(clearB, isNot(contains(0xFF)));
    });

    test('gen4 has no index operand on read or disable', () {
      for (final slot in [0, 1]) {
        expect(AlarmPayloads.probeReadBody(isGen5: false, slot: slot),
            AlarmPayloads.probeReadBody(isGen5: false, slot: 0));
        expect(AlarmPayloads.probeClearBody(isGen5: false, slot: slot),
            AlarmPayloads.probeClearBody(isGen5: false, slot: 0));
      }
    });
  });
}
