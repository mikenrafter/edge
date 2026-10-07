// The bytes the Device lab's alarm-slot probe writes, per band family.
// Slot 0 is probe alarm A and slot 1 is probe alarm B: gen5 ids 1 and 2 (id 0
// is rejected, id 1 is the slot the app really arms), gen4 rich-form indices 0
// and 1. The pattern is short and gentle, never the stock 30 s wake buzz.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

// 1790000000 s + 123 ms: epoch LE 80 3B B1 6A, subsec 123 * 32768 / 1000 =
// 4030 = 0x0FBE, LE BE 0F.
final DateTime _when = DateTime.fromMillisecondsSinceEpoch(1790000000123);
const List<int> _epochAndSubsec = [0x80, 0x3B, 0xB1, 0x6A, 0xBE, 0x0F];

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

    test('keeps the stock waveform effects the band is known to accept', () {
      expect(AlarmPayloads.probeHaptics.sublist(0, 2), [47, 152]);
    });
  });

  group('arm bodies', () {
    test('gen4 slot A is the rich form at index 0', () {
      expect(
        AlarmPayloads.probeBody(_when, isGen5: false, slot: 0),
        [0x04, 0, ..._epochAndSubsec, ...AlarmPayloads.probeHaptics],
      );
    });

    test('gen4 slot B is the rich form at index 1', () {
      final b = AlarmPayloads.probeBody(_when, isGen5: false, slot: 1);
      expect(b, [0x04, 1, ..._epochAndSubsec, ...AlarmPayloads.probeHaptics]);
      expect(b, hasLength(20));
    });

    test('gen5 slot A is the 21-byte rich body at id 1, crescendo 0', () {
      final a = AlarmPayloads.probeBody(_when, isGen5: true, slot: 0);
      expect(a, [
        0x04,
        AlarmPayloads.gen5Slot,
        ..._epochAndSubsec,
        ...AlarmPayloads.probeHaptics,
        0,
      ]);
      expect(a, hasLength(21));
    });

    test('gen5 slot B is the same body at id 2', () {
      final b = AlarmPayloads.probeBody(_when, isGen5: true, slot: 1);
      expect(b, [0x04, 2, ..._epochAndSubsec, ...AlarmPayloads.probeHaptics, 0]);
    });

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
      expect(AlarmPayloads.probeReadBody(isGen5: true, slot: 0), [0x04, 1]);
      expect(AlarmPayloads.probeReadBody(isGen5: true, slot: 1), [0x04, 2]);
      expect(AlarmPayloads.probeClearBody(isGen5: true, slot: 0), [0x02, 1]);
      expect(AlarmPayloads.probeClearBody(isGen5: true, slot: 1), [0x02, 2]);
    });

    test('gen4 has no index operand on read or disable', () {
      for (final slot in [0, 1]) {
        expect(AlarmPayloads.probeReadBody(isGen5: false, slot: slot), [0x01]);
        expect(AlarmPayloads.probeClearBody(isGen5: false, slot: slot), [0x01]);
      }
    });
  });
}
