// The resolved plan of a rhythm (the commands it is sent as) is remembered, so
// a row that rebuilds does not compile its notes again. Counting is by the
// seam in haptics/haptic_player.dart: `debugCompileCount` goes up once per
// rhythm compiled, `debugResolveCacheSize` is bounded at 64.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show HapticScore, buildTheme;

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

// A rule with notes and no stored plan, so delivery has to compile them.
BuzzSequence _unplanned(String code) {
  final notes = PatternTranscript.parseCode(code).entries;
  return tapsFromNotes(notes).copyWith(
    notes: notes.join(' '),
    profileId: _mg.id,
    profileVersion: _mg.version,
  );
}

List<PatternEntry> _entries(BuzzSequence s) =>
    PatternTranscript.parseCode(s.notes!).entries;

void main() {
  setUp(debugClearResolveCache);

  test('asking again for the same rhythm compiles once', () {
    final s = _unplanned('N4* R4 N4* R4 N2*');
    final before = debugCompileCount;
    final first = bandCommandOfEntries(s, _entries(s), _mg);
    expect(debugCompileCount, before + 1);
    for (var i = 0; i < 5; i++) {
      expect(bandCommandOfEntries(s, _entries(s), _mg), first);
    }
    expect(bandSequenceCommands(s, _mg), isNonZero);
    expect(bandStepsFor(s, _mg), isNotNull);
    expect(debugCompileCount, before + 1,
        reason: 'the colouring, the count and the stored steps share it');
  });

  test('an equal sequence built again is the same entry (by value)', () {
    final before = debugCompileCount;
    bandSequenceCommands(_unplanned('N4* R4 N4*'), _mg);
    bandSequenceCommands(_unplanned('N4* R4 N4*'), _mg);
    expect(debugCompileCount, before + 1);
  });

  test('a different rhythm, profile cap or notes compiles on its own', () {
    final a = _unplanned('N4* R4 N4*');
    final b = _unplanned('N4* R4 N8*');
    final before = debugCompileCount;
    bandSequenceCommands(a, _mg);
    bandSequenceCommands(b, _mg);
    expect(debugCompileCount, before + 2);
    // The same rhythm under another cap is another answer.
    bandSequenceCommands(a, _mg, maxRuntime: null);
    expect(debugCompileCount, before + 3);
    bandSequenceCommands(a, _mg, maxRuntime: null);
    expect(debugCompileCount, before + 3);
  });

  test('the cached answer is the answer', () {
    final s = _unplanned('N4* R4 N4* R4 N2*');
    final fresh = bandCommandOfEntries(s, _entries(s), _mg);
    final steps = bandStepsFor(s, _mg)!.map((x) => x.toString()).toList();
    debugClearResolveCache();
    expect(bandCommandOfEntries(s, _entries(s), _mg), fresh);
    expect(bandStepsFor(s, _mg)!.map((x) => x.toString()), steps);
  });

  test('a stored plan costs no compile at all', () {
    final s = builtInDefault('preset.sos')!.sequence;
    final before = debugCompileCount;
    bandCommandOfEntries(s, _entries(s), _mg);
    bandSequenceCommands(s, _mg);
    expect(debugCompileCount, before);
  });

  test('a no-profile (4.0) rhythm compiles nothing', () {
    final s = _unplanned('N4* R4 N4*');
    final before = debugCompileCount;
    bandCommandOfEntries(s, _entries(s), null);
    expect(debugCompileCount, before);
  });

  test('the cache is bounded; the oldest goes, the recent stays', () {
    final seqs = <BuzzSequence>[
      for (final a in kPatternLengths)
        for (final b in kPatternLengths)
          for (final r in const [2, 3, 4]) _unplanned('N$a* R$r N$b*'),
    ];
    expect(seqs.length, greaterThan(100));
    for (final s in seqs.take(100)) {
      bandSequenceCommands(s, _mg);
    }
    expect(debugResolveCacheSize, lessThanOrEqualTo(64));
    var before = debugCompileCount;
    bandSequenceCommands(seqs[99], _mg);
    expect(debugCompileCount, before, reason: 'the newest is still held');
    before = debugCompileCount;
    bandSequenceCommands(seqs[0], _mg);
    expect(debugCompileCount, before + 1, reason: 'the oldest was dropped');
  });

  test('a read keeps an entry young', () {
    final seqs = [
      for (final a in kPatternLengths)
        for (final r in const [2, 3, 4, 6, 8])
          for (final b in const [1, 2, 4]) _unplanned('N$a* R$r N$b*'),
    ];
    expect(seqs.length, greaterThan(100));
    final keep = seqs.first;
    bandSequenceCommands(keep, _mg);
    for (final s in seqs.skip(1).take(60)) {
      bandSequenceCommands(s, _mg);
    }
    bandSequenceCommands(keep, _mg); // read again: young
    for (final s in seqs.skip(61)) {
      bandSequenceCommands(s, _mg);
    }
    final before = debugCompileCount;
    bandSequenceCommands(keep, _mg);
    expect(debugCompileCount, before);
  });

  group('the staff', () {
    Future<void> pump(WidgetTester t, BuzzSequence s, {Key? key}) =>
        t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
                width: 360, child: HapticScore(s, profile: _mg, key: key)),
          ),
        ));

    testWidgets('two builds of the same row compile once', (t) async {
      final s = _unplanned('N4* R4 N4* R4 N2*');
      final before = debugCompileCount;
      await pump(t, s);
      expect(debugCompileCount, before + 1);
      // A rebuild with an equal, newly made sequence (a parent setState).
      await pump(t, _unplanned('N4* R4 N4* R4 N2*'));
      await t.pump();
      await pump(t, s, key: UniqueKey()); // a fresh element, same rhythm
      expect(debugCompileCount, before + 1);
    });

    testWidgets('a changed pattern is compiled once more', (t) async {
      final before = debugCompileCount;
      await pump(t, _unplanned('N4* R4 N4*'));
      await pump(t, _unplanned('N4* R4 N8*'));
      expect(debugCompileCount, before + 2);
    });
  });
}
