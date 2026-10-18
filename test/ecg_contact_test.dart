// Contact from 50 ms blocks (lib/gestures/ecg_contact.dart).
//
// The sensor reads a constant value (zeros, or any DC level) when no finger is
// on it and a moving trace when one is. So contact is "the signal moves", not
// "the sample is non-zero": the packet is cut into blocks of 5 samples (50 ms
// at 100 Hz) and a block is contact when any sample in it differs from the
// sample before it. A run of contact blocks shorter than minRunBlocks (100 ms)
// is debounced away, except a run that touches the packet's first or last
// block, which may continue across the packet boundary.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_contact.dart';

/// [n] samples that start at [base] and HOLD their last value except inside the
/// [moving] ranges, where they alternate +100, -100 (so every sample there
/// differs from the one before it).
List<int> _samples(int n,
    {int base = 0, List<(int, int)> moving = const []}) {
  final out = <int>[];
  var held = base;
  for (var i = 0; i < n; i++) {
    final r = moving.where((m) => i >= m.$1 && i < m.$2);
    if (r.isNotEmpty) held = (i - r.first.$1).isEven ? 100 : -100;
    out.add(held);
  }
  return out;
}

/// The indices of the samples that are contact.
List<int> _on(List<bool> mask) => [
      for (var i = 0; i < mask.length; i++)
        if (mask[i]) i,
    ];

List<int> _range(int from, int to) => [for (var i = from; i < to; i++) i];

void main() {
  group('a flat signal is no contact, whatever its level', () {
    test('all zeros', () {
      final m = ecgContactMask(List.filled(100, 0));
      expect(m, hasLength(100));
      expect(m, everyElement(isFalse));
    });

    test('a constant non-zero level (a DC offset)', () {
      final m = ecgContactMask(List.filled(100, 300));
      expect(m, hasLength(100));
      expect(m, everyElement(isFalse));
    });

    test('a constant negative level', () {
      expect(ecgContactMask(List.filled(100, -250)), everyElement(isFalse));
    });

    test('an empty packet gives an empty mask', () {
      expect(ecgContactMask(const <int>[]), isEmpty);
    });

    test('the very first sample has no predecessor: it counts only through '
        'the next sample', () {
      expect(ecgContactMask([5, 5, 5, 5, 5, 5, 5, 5, 5, 5]),
          everyElement(isFalse));
      // The second sample differs from the first: block 0 moves.
      final m = ecgContactMask([5, 6, 6, 6, 6, 6, 6, 6, 6, 6]);
      expect(_on(m), _range(0, 5), reason: 'a first-block run is kept');
    });
  });

  group('a moving trace is contact', () {
    test('every sample differs from the one before', () {
      final m = ecgContactMask(_samples(100, moving: [(0, 100)]));
      expect(m, hasLength(100));
      expect(m, everyElement(isTrue));
    });

    test('a noisy trace that crosses zero is still contact (a zero sample is '
        'not a gap)', () {
      final s = _samples(100, moving: [(0, 100)]);
      s[40] = 0;
      s[69] = 0;
      expect(ecgContactMask(s), everyElement(isTrue));
    });

    test('an Int16List works like a List<int>', () {
      final s = Int16List.fromList(_samples(100, moving: [(0, 100)]));
      expect(ecgContactMask(s), everyElement(isTrue));
    });

    test('contact in the middle only: the sensor goes flat before and after',
        () {
      // 25..34 moves (two blocks), the rest holds its value.
      final m = ecgContactMask(_samples(100, moving: [(25, 35)]));
      expect(_on(m), _range(25, 35));
    });

    test('the step into a flat block belongs to the block it lands in', () {
      // Zeros, then a jump to 7 at sample 30 and flat after: block 6 (30..34)
      // moves (the jump), nothing else does. One block in the middle: dropped.
      final s = [for (var i = 0; i < 100; i++) i < 30 ? 0 : 7];
      expect(ecgContactMask(s), everyElement(isFalse));
    });
  });

  group('debounce: a run shorter than 100 ms is dropped', () {
    test('a single isolated moving block is dropped', () {
      final m = ecgContactMask(_samples(100, moving: [(25, 30)]));
      expect(m, hasLength(100));
      expect(m, everyElement(isFalse));
    });

    test('two isolated single blocks are both dropped', () {
      final m = ecgContactMask(_samples(100, moving: [(25, 30), (60, 65)]));
      expect(m, everyElement(isFalse));
    });

    test('a 2-block run (exactly 100 ms) is kept', () {
      final m = ecgContactMask(_samples(100, moving: [(25, 35)]));
      expect(_on(m), _range(25, 35));
    });

    test('a 3-block run is kept', () {
      final m = ecgContactMask(_samples(100, moving: [(20, 35)]));
      expect(_on(m), _range(20, 35));
    });

    test('a 2-block run is kept while a lone block next to it is dropped', () {
      final m = ecgContactMask(_samples(100, moving: [(15, 20), (40, 50)]));
      expect(_on(m), _range(40, 50));
    });

    test('a 1-block run at the packet\'s FIRST block is kept (it may continue '
        'from the packet before)', () {
      final m = ecgContactMask(_samples(100, moving: [(0, 5)]));
      expect(_on(m), _range(0, 5));
    });

    test('a 1-block run at the packet\'s LAST block is kept (it may continue '
        'into the next packet)', () {
      final m = ecgContactMask(_samples(100, moving: [(95, 100)]));
      expect(_on(m), _range(95, 100));
    });

    test('a 1-block run one block in from the edge is dropped', () {
      expect(ecgContactMask(_samples(100, moving: [(5, 10)])),
          everyElement(isFalse));
      expect(ecgContactMask(_samples(100, moving: [(90, 95)])),
          everyElement(isFalse));
    });

    test('a run touching an edge is kept whole, however short the rest', () {
      // First block and the one after: two blocks, kept; the far lone block is
      // dropped.
      final m = ecgContactMask(_samples(100, moving: [(0, 10), (60, 65)]));
      expect(_on(m), _range(0, 10));
    });

    test('minRunBlocks 1 keeps every moving block, 3 drops a 2-block run',
        () {
      final lone = _samples(100, moving: [(25, 30)]);
      expect(_on(ecgContactMask(lone, minRunBlocks: 1)), _range(25, 30));
      final two = _samples(100, moving: [(25, 35)]);
      expect(ecgContactMask(two, minRunBlocks: 3), everyElement(isFalse));
    });

    test('every sample gets its block\'s state, so a block is all or nothing',
        () {
      final m = ecgContactMask(_samples(100, moving: [(25, 35)]));
      for (var b = 0; b < 20; b++) {
        final block = m.sublist(b * 5, b * 5 + 5);
        expect(block.toSet(), hasLength(1), reason: 'block $b is uniform');
      }
    });
  });

  group('the 49-sample first packet (blocks of 5, the last one has 4)', () {
    test('the mask is as long as the packet', () {
      expect(ecgContactMask(List.filled(49, 0)), hasLength(49));
      expect(ecgContactMask(_samples(49, moving: [(0, 49)])), hasLength(49));
    });

    test('a short last block that moves is a 1-block run at the edge: kept',
        () {
      // Samples 45..48 are the short block 9.
      final m = ecgContactMask(_samples(49, moving: [(45, 49)]));
      expect(_on(m), _range(45, 49));
    });

    test('the measured blip (samples 36..48) is blocks 7, 8 and the short 9: '
        'kept', () {
      final m = ecgContactMask(_samples(49, moving: [(36, 49)]));
      expect(_on(m), _range(35, 49));
    });

    test('sample 44 belongs to block 8, sample 45 starts the short block 9',
        () {
      // Moving only inside block 8 (40..44): a lone block, not at an edge.
      expect(ecgContactMask(_samples(49, moving: [(40, 45)])),
          everyElement(isFalse));
      // Moving only inside the short block 9 (45..48): the last block, kept.
      expect(_on(ecgContactMask(_samples(49, moving: [(45, 49)]))),
          _range(45, 49));
    });

    test('a lone moving block in the middle of the short packet is dropped',
        () {
      expect(ecgContactMask(_samples(49, moving: [(15, 20)])),
          everyElement(isFalse));
    });

    test('a short packet that is all zeros is no contact', () {
      expect(ecgContactMask(List.filled(49, 0)), everyElement(isFalse));
    });
  });

  group('block size is a parameter', () {
    test('blockSamples 10: blocks of 100 ms, and one is enough at minRunBlocks '
        '1', () {
      final s = _samples(100, moving: [(30, 40)]);
      expect(_on(ecgContactMask(s, blockSamples: 10, minRunBlocks: 1)),
          _range(30, 40));
    });
  });
}
