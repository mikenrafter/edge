// 8Y: the pattern probe's transcriber. The wearer taps buttons of length 1-4;
// entries alternate buzz, gap, buzz, gap... (the first is a buzz). Pure Dart:
// [PatternTranscript] is one immutable list of lengths, [PatternEntrySession]
// holds which test is open, two renditions per test, the cursor in the list and
// how often each test was played.

import 'hardware_probes.dart';

/// One transcription: entry i is a buzz when i is even, a gap when it is odd.
class PatternTranscript {
  PatternTranscript(List<int> lengths)
      : _lengths = List.unmodifiable(lengths);

  final List<int> _lengths;

  /// Most entries one transcription holds.
  static const int maxEntries = 24;

  /// A read-only view; callers cannot change the transcript through it.
  List<int> get lengths => List.unmodifiable(_lengths);

  int get length => _lengths.length;

  bool isBuzz(int i) => i.isEven;

  static void _check(int len) {
    if (len < 1 || len > 4) {
      throw ArgumentError.value(len, 'len', 'a length is 1 to 4');
    }
  }

  PatternTranscript append(int len) {
    _check(len);
    if (_lengths.length >= maxEntries) return this;
    return PatternTranscript([..._lengths, len]);
  }

  PatternTranscript replaceAt(int i, int len) {
    _check(len);
    return PatternTranscript([..._lengths]..[i] = len);
  }

  PatternTranscript removeAt(int i) =>
      PatternTranscript([..._lengths]..removeAt(i));

  /// "B2 G1 B4"; empty when nothing is entered.
  String get code => [
        for (var i = 0; i < _lengths.length; i++)
          '${isBuzz(i) ? 'B' : 'G'}${_lengths[i]}',
      ].join(' ');

  /// "buzz 2, gap 1, buzz 4".
  String get prose => [
        for (var i = 0; i < _lengths.length; i++)
          '${isBuzz(i) ? 'buzz' : 'gap'} ${_lengths[i]}',
      ].join(', ');
}

/// The state of one transcribing session. Mutable; the owner notifies its
/// listeners after calling an operation.
class PatternEntrySession {
  PatternEntrySession(List<PatternTest> tests)
      : tests = List.unmodifiable(tests),
        _renditions = [
          for (var _ in tests)
            [PatternTranscript(const []), PatternTranscript(const [])],
        ],
        _plays = List.filled(tests.length, 0);

  final List<PatternTest> tests;
  final List<List<PatternTranscript>> _renditions;
  final List<int> _plays;

  int testIndex = 0;
  int activeRendition = 0;

  /// 0 to the active transcript's length; the length itself is the empty
  /// "next entry" slot.
  int cursor = 0;

  PatternTranscript rendition(int test, int r) => _renditions[test][r];

  int plays(int test) => _plays[test];

  PatternTranscript get active => _renditions[testIndex][activeRendition];

  void nextTest() => goToTest(testIndex + 1);

  void previousTest() => goToTest(testIndex - 1);

  void goToTest(int i) {
    testIndex = i.clamp(0, tests.length - 1);
    activeRendition = 0;
    cursor = active.length;
  }

  void selectRendition(int r) {
    activeRendition = r;
    cursor = active.length;
  }

  void moveCursor(int delta) {
    cursor = (cursor + delta).clamp(0, active.length);
  }

  void tap(int len) {
    final t = active;
    if (cursor >= t.length) {
      final next = t.append(len);
      if (next.length == t.length) return;
      _renditions[testIndex][activeRendition] = next;
    } else {
      _renditions[testIndex][activeRendition] = t.replaceAt(cursor, len);
    }
    cursor = cursor + 1;
  }

  void delete() {
    final t = active;
    if (t.length == 0) return;
    final at = cursor >= t.length ? t.length - 1 : cursor;
    final next = t.removeAt(at);
    _renditions[testIndex][activeRendition] = next;
    cursor = cursor >= t.length ? next.length : cursor.clamp(0, next.length);
  }

  /// A play counted for [test] (default: the open test; a play can finish
  /// after the wearer moved on).
  void notePlayed([int? test]) => _plays[test ?? testIndex]++;

  /// One line per test with a transcript or a play, in test order.
  List<String> logLines() {
    String one(PatternTranscript t) =>
        t.length == 0 ? '—' : '${t.prose} (${t.code})';
    return [
      for (var i = 0; i < tests.length; i++)
        if (_plays[i] > 0 ||
            _renditions[i].any((t) => t.length > 0))
          'Pattern probe heard ${i + 1}/${tests.length}, '
              '${tests[i].description}: A = ${one(_renditions[i][0])}; '
              'B = ${one(_renditions[i][1])}; played ${_plays[i]}×.',
    ];
  }
}
