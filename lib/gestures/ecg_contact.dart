// Contact from 50 ms blocks. Pure; no Flutter.
//
// The sensor reads exactly zero with no finger, but a finger can also read a
// flat non-zero value, and a lone zero crossing inside a touch is not a lift.
// So contact is judged on short blocks of the 100 Hz stream: a block has
// contact when the signal moves inside it, and a contact run shorter than two
// blocks (under 100 ms) is a glitch, not a touch.

/// One flag per sample of [samples]: true when the sample's block has contact.
///
/// The packet is split into blocks of [blockSamples] (the last may be shorter).
/// A block has contact when any of its samples differs from the one before it;
/// the sample before a block's first sample is the previous block's last, and
/// the packet's very first sample has no predecessor, so it only counts through
/// the next sample. A flat block (zeros or any constant) has no contact. A run
/// of contact blocks shorter than [minRunBlocks] is dropped, unless it touches
/// the packet's first or last block, where it may continue across the packet
/// boundary.
List<bool> ecgContactMask(List<int> samples,
    {int blockSamples = 5, int minRunBlocks = 2}) {
  final n = samples.length;
  if (n == 0) return const [];
  final blocks = (n + blockSamples - 1) ~/ blockSamples;
  final moving = List<bool>.filled(blocks, false);
  for (var i = 1; i < n; i++) {
    if (samples[i] != samples[i - 1]) moving[i ~/ blockSamples] = true;
  }
  var b = 0;
  while (b < blocks) {
    if (!moving[b]) {
      b++;
      continue;
    }
    var e = b;
    while (e < blocks && moving[e]) {
      e++;
    }
    final touchesEdge = b == 0 || e == blocks;
    if (e - b < minRunBlocks && !touchesEdge) {
      for (var k = b; k < e; k++) {
        moving[k] = false;
      }
    }
    b = e;
  }
  return [for (var i = 0; i < n; i++) moving[i ~/ blockSamples]];
}
