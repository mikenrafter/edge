// similarityWarnings: two patterns in one confusable set that share a beat
// count, or whose total lengths are within 0.5 s, are flagged. Never blocks.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/pattern_similarity.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

// A tapped rhythm: no notes code, so it is measured to the millisecond.
// [offsets] are press starts, [holds] how long each is held.
BuzzSequence _taps(List<int> offsets, List<int> holds) =>
    BuzzSequence(offsets, durationsMs: holds);

// One press of [ms].
BuzzSequence _one(int ms) => _taps(const [0], [ms]);

// [n] presses of 100 ms, 200 ms apart: n beats, (n - 1) * 300 + 100 ms long.
BuzzSequence _beats(int n) => _taps(
      [for (var i = 0; i < n; i++) i * 300],
      [for (var i = 0; i < n; i++) 100],
    );

// A pattern written as notes: a run of adjacent notes is one beat.
BuzzSequence _notes(String code) =>
    BuzzSequence(const [0], durationsMs: const [125], notes: code);

const _gs = 'gesture.start';
const _inhale = 'breath.inhale';
const _exhale = 'breath.exhale';
const _hold = 'breath.hold';
const _done = 'breath.done';
const _snooze = 'alarm.snooze.confirm';
const _dismiss = 'alarm.dismiss.confirm';
const _cancelled = 'alarm.snooze.cancelled';
const _realarm = 'alarm.snooze.realarm';

({String a, String b, SimilarityReason r}) _w(SimilarityWarning w) =>
    (a: w.slotA, b: w.slotB, r: w.reason);

void main() {
  group('beats and duration', () {
    test('a tapped rhythm: its presses, and playTime to the millisecond', () {
      final s = _taps(const [0, 600], const [100, 100]);
      expect(patternBeats(s), 2);
      expect(patternDuration(s), const Duration(milliseconds: 700));
    });

    test('notes: a run of adjacent notes is one beat', () {
      expect(patternBeats(_notes('N2mf R2 N2mf')), 2);
      expect(patternBeats(_notes('N2mf N2mf R2 N2mf')), 2);
      expect(patternBeats(_notes('N4mf')), 1);
    });

    test('notes: 125 ms per sixteenth, first note start to last note end', () {
      expect(patternDuration(_notes('N4mf R2 N4mf')),
          const Duration(milliseconds: 1250));
      // Leading and trailing rests are silence around the pattern, not in it.
      expect(patternDuration(_notes('R4 N4mf R2 N4mf R8')),
          const Duration(milliseconds: 1250));
    });

    test('notes: more beats than a tapped rhythm can hold are all counted', () {
      final nine = _notes('N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 '
          'N1* R1 N1*');
      expect(patternBeats(nine), 9);
    });
  });

  group('same beat count', () {
    test('two slots in a set with the same beats are flagged sameBeats', () {
      final w = similarityWarnings({
        _inhale: _beats(2),
        _exhale: _taps(const [0, 1500], const [100, 100]), // 2 beats, 1.6 s
      });
      expect(w, hasLength(1));
      expect(_w(w.single), (a: _inhale, b: _exhale, r: SimilarityReason.sameBeats));
      expect(w.single.beats, 2);
    });

    test('different beats and far apart in length: no warning', () {
      expect(similarityWarnings({_inhale: _beats(1), _exhale: _beats(3)}),
          isEmpty);
    });

    test('three slots with the same count give every pair, in set order', () {
      final w = similarityWarnings({
        _done: _beats(2),
        _inhale: _beats(2),
        _hold: _taps(const [0, 2000], const [100, 100]),
      });
      expect([for (final x in w) _w(x)], [
        (a: _inhale, b: _hold, r: SimilarityReason.sameBeats),
        (a: _inhale, b: _done, r: SimilarityReason.sameBeats),
        (a: _hold, b: _done, r: SimilarityReason.sameBeats),
      ]);
    });

    test('beats come from notes when a pattern has them', () {
      final w = similarityWarnings({
        _inhale: _notes('N8mf R8 N8mf'), // 2 beats
        _exhale: _notes('N2mf N2mf R2 N1mf'), // 2 beats, far shorter
      });
      expect(w, hasLength(1));
      expect(w.single.reason, SimilarityReason.sameBeats);
    });
  });

  group('close total duration', () {
    test('exactly 0.5 s apart warns', () {
      final w = similarityWarnings({
        _inhale: _one(1000), // 1 beat, 1.0 s
        // 2 beats, 1.5 s: 1200 + 300
        _exhale: _taps(const [0, 1200], const [100, 300]),
      });
      expect(w, hasLength(1));
      expect(_w(w.single), (a: _inhale, b: _exhale, r: SimilarityReason.closeDuration));
      expect(w.single.beats, isNull);
    });

    test('0.51 s apart does not', () {
      expect(
        similarityWarnings({
          _inhale: _one(1000),
          _exhale: _taps(const [0, 1200], const [100, 310]), // 1.51 s
        }),
        isEmpty,
      );
    });

    test('the same holds either way round', () {
      expect(
        similarityWarnings({
          _inhale: _taps(const [0, 1200], const [100, 300]), // 1.5 s
          _exhale: _one(1000), // 1.0 s
        }),
        hasLength(1),
      );
      expect(
        similarityWarnings({
          _inhale: _taps(const [0, 1200], const [100, 310]), // 1.51 s
          _exhale: _one(1000),
        }),
        isEmpty,
      );
    });

    test('on notes: 0.5 s apart warns, 0.625 s apart does not', () {
      expect(
        similarityWarnings({
          _inhale: _notes('N8mf'), // 1 beat, 1.0 s
          _exhale: _notes('N8mf R2 N2mf'), // 2 beats, 12 x 125 = 1.5 s
        }),
        hasLength(1),
      );
      expect(
        similarityWarnings({
          _inhale: _notes('N8mf'), // 1.0 s
          _exhale: _notes('N8mf R3 N2mf'), // 2 beats, 13 x 125 = 1.625 s
        }),
        isEmpty,
      );
    });
  });

  test('one warning per pair; same beats wins over close duration', () {
    final w = similarityWarnings({
      _inhale: _beats(2), // 0.4 s
      _exhale: _beats(2), // identical: both rules apply
    });
    expect(w, hasLength(1));
    expect(w.single.reason, SimilarityReason.sameBeats);
  });

  group('sets', () {
    test('the gesture start and the breathing cues never warn each other', () {
      expect(
        similarityWarnings({
          _gs: _beats(2),
          _inhale: _beats(2),
          _exhale: _beats(2),
          _hold: _beats(2),
          _done: _beats(2),
        }).where((w) => w.slotA == _gs || w.slotB == _gs),
        isEmpty,
      );
    });

    test('the alarm snooze and wake confirmations are with the gesture start',
        () {
      final w = similarityWarnings({
        _gs: _beats(3),
        _snooze: _beats(3),
        _dismiss: _beats(3),
        _cancelled: _beats(3),
        _realarm: _beats(3),
      });
      // 5 slots, every pair: 10 warnings, all inside the one set.
      expect(w, hasLength(10));
      expect(w.every((x) => x.reason == SimilarityReason.sameBeats), isTrue);
      expect(w.first.slotA, _gs);
    });

    test('an alarm slot and a breathing cue do not warn each other', () {
      expect(similarityWarnings({_realarm: _beats(2), _exhale: _beats(2)}),
          isEmpty);
    });

    test('a slot in no set is never flagged, however alike', () {
      expect(
        similarityWarnings({
          'alert.water': _beats(2),
          'alert.health': _beats(2),
          'gesture.confirm': _beats(2),
          'gesture.failed': _beats(2),
        }),
        isEmpty,
      );
    });

    test('a set member that is missing from the map is skipped', () {
      expect(similarityWarnings({_inhale: _beats(2)}), isEmpty);
      expect(similarityWarnings(const {}), isEmpty);
    });

    test('both sets at once warn only inside themselves', () {
      final w = similarityWarnings({
        _gs: _beats(1),
        _snooze: _beats(1),
        _inhale: _beats(4),
        _done: _beats(4),
      });
      expect([for (final x in w) _w(x)], [
        (a: _gs, b: _snooze, r: SimilarityReason.sameBeats),
        (a: _inhale, b: _done, r: SimilarityReason.sameBeats),
      ]);
    });

    test('the set definition lists the keys of the real slots', () {
      final all = [for (final s in kConfusableSets) ...s];
      expect(
        all,
        containsAll([
          'gesture.start',
          'breath.inhale',
          'breath.exhale',
          'breath.hold',
          'breath.done',
          'alarm.snooze.confirm',
          'alarm.snooze.realarm',
        ]),
      );
      expect(all.toSet(), hasLength(all.length),
          reason: 'a slot is in one set only');
    });
  });

  group('the line a slot shows', () {
    SimilarityWarning sameBeats(int n) => SimilarityWarning(
        slotA: _gs, slotB: _snooze, reason: SimilarityReason.sameBeats, beats: n);

    test('same beats, plural', () {
      expect(similarityLine(sameBeats(2), other: 'Gesture start'),
          'Feels like Gesture start (same 2 beats)');
    });

    test('same beats, singular', () {
      expect(similarityLine(sameBeats(1), other: 'Gesture start'),
          'Feels like Gesture start (same 1 beat)');
    });

    test('close duration', () {
      expect(
        similarityLine(
          const SimilarityWarning(
              slotA: _inhale,
              slotB: _exhale,
              reason: SimilarityReason.closeDuration),
          other: 'Exhale',
        ),
        'Feels like Exhale (within 0.5 s)',
      );
    });
  });
}
