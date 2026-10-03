// 8Y/8Z/8AA/8AB/8AC: the pattern probe's transcriber. The wearer taps buttons of
// length 1, 2, 4 or 8 sixteenths, and a one-shot Dot makes the next tap 3/2 as
// long (3, 6 or 12); every note also carries a dynamic (ff, f, mf,
// mp, p, pp) from a sticky selector; every entry is typed explicitly as a note or a rest (two notes or two
// rests may sit next to each other). A Note/Rest toggle flips after every tap
// and can be overridden. Pure Dart: [PatternTranscript] is one immutable list of
// [PatternEntry]s, [PatternEntrySession] holds which test is open, two
// renditions per test, the cursor in the list, the toggle, how often each test
// was played, the tempo and Bluetooth lead fitted from measured plays.

import 'hardware_probes.dart';

/// The lengths an entry can have, in sixteenths: 16th, eighth, dotted eighth,
/// quarter, dotted quarter, half, dotted half.
const List<int> kPatternLengths = [1, 2, 3, 4, 6, 8, 12];

/// How hard a note is felt, loudest to softest, then [any]. The order of the
/// first six matters: the index distance between two of them is how far apart
/// they are felt. [any] (code "*", advanced editor only) says the wearer does
/// not mind how loud; it is not a position on that scale and has no distance
/// to anything, so use [scale] where the six are meant.
enum PatternDynamic {
  ff,
  f,
  mf,
  mp,
  p,
  pp,
  any;

  /// The six that run from loudest to softest; what the probe offers and what
  /// a band can be heard to play.
  static const List<PatternDynamic> scale = [ff, f, mf, mp, p, pp];

  /// "ff", "mf" ... and "*" for [any]: how a code writes it.
  String get code => this == any ? '*' : name;

  /// How far apart two dynamics on the scale are, in steps; 0 when either is
  /// [any], which has no position.
  int distanceTo(PatternDynamic other) =>
      this == any || other == any ? 0 : (index - other.index).abs();
}

const Map<int, String> _lengthNames = {
  1: '16th',
  2: 'eighth',
  3: 'dotted eighth',
  4: 'quarter',
  6: 'dotted quarter',
  8: 'half',
  12: 'dotted half',
};

/// One transcribed entry: a note (with a dynamic) or a rest (without one).
class PatternEntry {
  const PatternEntry({required this.note, required this.length, this.dynamic});

  /// True for a note (the band buzzed), false for a rest.
  final bool note;

  /// In sixteenths; one of [kPatternLengths].
  final int length;

  /// Required for a note, null for a rest.
  final PatternDynamic? dynamic;

  @override
  bool operator ==(Object other) =>
      other is PatternEntry &&
      other.note == note &&
      other.length == length &&
      other.dynamic == dynamic;

  @override
  int get hashCode => Object.hash(note, length, dynamic);

  /// "N4mf", "N2*" or "R2".
  @override
  String toString() => '${note ? 'N' : 'R'}$length${dynamic?.code ?? ''}';

  static final RegExp _code =
      RegExp(r'^(?:N(\d+)(ff|f|mf|mp|pp|p|\*)|R(\d+))$');

  /// The inverse of [toString]: "N4ff", "N1p", "R3". Anything else, or a
  /// length outside [kPatternLengths], is a [FormatException] or an
  /// [ArgumentError].
  factory PatternEntry.parse(String code) {
    final m = _code.firstMatch(code);
    if (m == null) {
      throw FormatException('not a pattern entry', code);
    }
    final note = m[1] != null;
    final length = int.parse((note ? m[1] : m[3])!);
    if (!kPatternLengths.contains(length)) {
      throw ArgumentError.value(
        length,
        'length',
        'a length is one of $kPatternLengths',
      );
    }
    return PatternEntry(
      note: note,
      length: length,
      dynamic: !note
          ? null
          : m[2] == '*'
              ? PatternDynamic.any
              : PatternDynamic.values.byName(m[2]!),
    );
  }

  /// "quarter note mf", "eighth note, any loudness" or "eighth rest".
  String get prose => '${_lengthNames[length]} ${note ? 'note' : 'rest'}'
      '${_dynamicProse(dynamic)}';

  static String _dynamicProse(PatternDynamic? d) => d == null
      ? ''
      : d == PatternDynamic.any
          ? ', any loudness'
          : ' ${d.name}';
}

/// One transcription: an immutable list of typed entries.
class PatternTranscript {
  PatternTranscript(List<PatternEntry> entries)
      : _entries = List.unmodifiable(entries);

  final List<PatternEntry> _entries;

  /// Most entries one transcription holds.
  static const int maxEntries = 32;

  /// A read-only view; callers cannot change the transcript through it.
  List<PatternEntry> get entries => _entries;

  int get length => _entries.length;

  static void _check(PatternEntry e) {
    if (!kPatternLengths.contains(e.length)) {
      throw ArgumentError.value(
        e.length,
        'length',
        'a length is one of $kPatternLengths',
      );
    }
    if (e.note != (e.dynamic != null)) {
      throw ArgumentError.value(
        e.dynamic,
        'dynamic',
        'a note has a dynamic and a rest has none',
      );
    }
  }

  PatternTranscript append(PatternEntry e) {
    _check(e);
    if (_entries.length >= maxEntries) return this;
    return PatternTranscript([..._entries, e]);
  }

  PatternTranscript replaceAt(int i, PatternEntry e) {
    _check(e);
    return PatternTranscript([..._entries]..[i] = e);
  }

  PatternTranscript removeAt(int i) =>
      PatternTranscript([..._entries]..removeAt(i));

  /// "N2mf R1 N4pp"; empty when nothing is entered.
  String get code => _entries.join(' ');

  /// The inverse of [code]: whitespace separated entries, empty for blank
  /// text. Junk throws as [PatternEntry.parse] does.
  factory PatternTranscript.parseCode(String code) => PatternTranscript([
        for (final part in code.trim().split(RegExp(r'\s+')))
          if (part.isNotEmpty) PatternEntry.parse(part),
      ]);

  /// "quarter note mf, eighth rest, 16th note ff".
  String get prose => [for (final e in _entries) e.prose].join(', ');
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
        _plays = List.filled(tests.length, 0),
        _unstable = List.filled(tests.length, false);

  /// One unit is a sixteenth: a 4/4 bar of 16 steps is 2 s. Measured on the
  /// band (as eighths, 250 ms): effect 1 plays about 0.22-0.6 s, 14 about 2-3,
  /// 47 about 3-4, and each half of the 47 + 152 pair about 2.
  static const int defaultUnitMs = 125;

  /// The Bluetooth delay from a play's first write landing to the band
  /// starting, until a play has been measured.
  static const int defaultLeadMs = 300;

  final List<PatternTest> tests;
  final List<List<PatternTranscript>> _renditions;
  final List<int> _plays;
  final List<bool> _unstable;
  final Map<int, int> _spans = {};
  final List<int> _leads = [];

  int testIndex = 0;
  int activeRendition = 0;

  /// 0 to the active transcript's length; the length itself is the empty
  /// "next entry" slot.
  int cursor = 0;

  /// The Note/Rest toggle: what the next tap writes.
  bool nextIsNote = true;

  /// The sticky dynamic the next note is written with. Cursor, test and
  /// rendition changes leave it alone.
  PatternDynamic nextDynamic = PatternDynamic.mf;

  /// The Dot toggle: the next tap writes 3/2 of its length, then it clears.
  bool dotNext = false;

  /// Whether the tempo follows the fit over the measured plays.
  bool dynamicTempo = true;

  PatternTranscript rendition(int test, int r) => _renditions[test][r];

  int plays(int test) => _plays[test];

  /// Whether [test] is flagged unstable: its A and B are the shortest and
  /// longest renditions heard, because the band's timing varies.
  bool unstable(int test) => _unstable[test];

  /// Flip the open test's unstable flag.
  void toggleUnstable() => _unstable[testIndex] = !_unstable[testIndex];

  /// Plays over all tests.
  int get totalPlays => _plays.fold(0, (a, b) => a + b);

  /// Tests with something written in either rendition.
  int get testsTranscribed => [
        for (var i = 0; i < tests.length; i++)
          if (_renditions[i].any((t) => t.length > 0)) i,
      ].length;

  /// Whether any lead was measured (else [leadMs] is the default).
  bool get leadMeasured => _leads.isNotEmpty;

  PatternTranscript get active => _renditions[testIndex][activeRendition];

  void nextTest() => goToTest(testIndex + 1);

  void previousTest() => goToTest(testIndex - 1);

  void goToTest(int i) {
    testIndex = i.clamp(0, tests.length - 1);
    activeRendition = 0;
    cursor = active.length;
    _followCursor();
  }

  void selectRendition(int r) {
    activeRendition = r;
    cursor = active.length;
    _followCursor();
  }

  void moveCursor(int delta) {
    cursor = (cursor + delta).clamp(0, active.length);
    _followCursor();
  }

  /// The toggle goes to the opposite of the entry before the cursor; Note
  /// when there is none.
  void _followCursor() {
    nextIsNote = cursor == 0 ? true : !active.entries[cursor - 1].note;
  }

  /// Override the toggle for the next entry.
  void toggleKind() => nextIsNote = !nextIsNote;

  /// Set the sticky dynamic; with the cursor on a note, that note takes it too.
  void setDynamic(PatternDynamic d) {
    nextDynamic = d;
    final t = active;
    if (cursor >= t.length) return;
    final e = t.entries[cursor];
    if (!e.note) return;
    _renditions[testIndex][activeRendition] =
        t.replaceAt(cursor, PatternEntry(note: true, length: e.length, dynamic: d));
  }

  void toggleDot() => dotNext = !dotNext;

  /// Write an entry of [len] sixteenths at the cursor. With the dot on, [len]
  /// must be 2, 4 or 8 and the entry is 3/2 as long (3, 6, 12), and the dot
  /// clears once it is written; any other [len] is an [ArgumentError] and
  /// changes nothing.
  void tap(int len) {
    if (dotNext && len != 2 && len != 4 && len != 8) {
      throw ArgumentError.value(len, 'len', 'only 2, 4 or 8 can be dotted');
    }
    final e = PatternEntry(
      note: nextIsNote,
      length: dotNext ? len * 3 ~/ 2 : len,
      dynamic: nextIsNote ? nextDynamic : null,
    );
    final t = active;
    if (cursor >= t.length) {
      final next = t.append(e);
      if (next.length == t.length) return;
      _renditions[testIndex][activeRendition] = next;
    } else {
      _renditions[testIndex][activeRendition] = t.replaceAt(cursor, e);
    }
    dotNext = false;
    cursor = cursor + 1;
    nextIsNote = !nextIsNote;
  }

  void delete() {
    final t = active;
    if (t.length == 0) return;
    final at = cursor >= t.length ? t.length - 1 : cursor;
    final next = t.removeAt(at);
    _renditions[testIndex][activeRendition] = next;
    cursor = cursor >= t.length ? next.length : cursor.clamp(0, next.length);
    _followCursor();
  }

  /// Replace the active rendition with [entries] (from taps, 8AD), cut to
  /// [PatternTranscript.maxEntries]. The cursor goes to the empty slot after
  /// them and the toggle follows the last entry; the dot clears.
  void setActive(List<PatternEntry> entries) {
    _renditions[testIndex][activeRendition] = PatternTranscript(
      entries.take(PatternTranscript.maxEntries).toList(),
    );
    dotNext = false;
    cursor = active.length;
    _followCursor();
  }

  /// A play counted for [test] (default: the open test; a play can finish
  /// after the wearer moved on).
  void notePlayed([int? test]) => _plays[test ?? testIndex]++;

  /// The measured span of [test]'s latest play: first live event 60 to last
  /// live event 100, phone receive times.
  void noteMeasured(int test, int ms) => _spans[test] = ms;

  /// One measured Bluetooth lead (a play's first write landing to its first
  /// live event 60).
  void noteLead(int ms) => _leads.add(ms);

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  /// The lead the march allows for: the median measured one, 0 to 1500 ms.
  int get leadMs => _leads.isEmpty
      ? defaultLeadMs
      : _median([for (final l in _leads) l.toDouble()])
          .round()
          .clamp(0, 1500);

  /// Units from the start up to and including the last note; trailing rests
  /// are not counted. 0 when there is no note.
  static int _units(PatternTranscript t) {
    var sum = 0, upToLastNote = 0;
    for (final e in t.entries) {
      sum += e.length;
      if (e.note) upToLastNote = sum;
    }
    return upToLastNote;
  }

  /// (ms per unit, tests it came from), or null with fewer than 2 usable
  /// tests. Per test: span over the units of rendition A and B (averaged when
  /// both have a note), the median over the tests, clamped to 50-400.
  (int, int)? _fit() {
    final perTest = <double>[];
    for (final MapEntry(key: test, value: ms) in _spans.entries) {
      final units = [
        for (final r in _renditions[test])
          if (_units(r) > 0) _units(r),
      ];
      if (units.isEmpty) continue;
      perTest.add(ms * units.length / units.reduce((a, b) => a + b));
    }
    if (perTest.length < 2) return null;
    return (_median(perTest).round().clamp(50, 400), perTest.length);
  }

  int? fittedUnitMs() => _fit()?.$1;

  /// The tempo to play and march at.
  int get unitMs => (dynamicTempo ? fittedUnitMs() : null) ?? defaultUnitMs;

  /// The schedule of a replay: entry i starts [leadMs] + [unitMs] × the units
  /// before it and lasts its length in units.
  static List<({int index, int startMs, int endMs})> march(
    PatternTranscript t,
    int unitMs,
    int leadMs,
  ) {
    var at = leadMs;
    return [
      for (var i = 0; i < t.length; i++)
        (
          index: i,
          startMs: at,
          endMs: at += t.entries[i].length * unitMs,
        ),
    ];
  }

  /// One line per test with a transcript or a play, in test order, then the
  /// tempo line (only when there is at least one test line).
  List<String> logLines() {
    String one(PatternTranscript t) =>
        t.length == 0 ? '—' : '${t.prose} (${t.code})';
    final lines = [
      for (var i = 0; i < tests.length; i++)
        if (_plays[i] > 0 ||
            _unstable[i] ||
            _renditions[i].any((t) => t.length > 0))
          'Pattern probe heard ${i + 1}/${tests.length}, '
              '${tests[i].description}'
              '${_unstable[i] ? ', unstable (A and B are the shortest and longest)' : ''}'
              ': A = ${one(_renditions[i][0])}; '
              'B = ${one(_renditions[i][1])}; played ${_plays[i]}×.',
    ];
    if (lines.isEmpty) return lines;
    final fit = dynamicTempo ? _fit() : null;
    lines.add('Pattern probe tempo: 1 sixteenth ≈ $unitMs ms '
        '${fit == null ? '(fixed)' : '(fitted from ${fit.$2} tests)'}.');
    return lines;
  }
}

/// [ms] milliseconds as a [Duration], for the page's metronome and march
/// timers. They are timing signals, not motion, so they do not go through the
/// reduced-motion gate that UI animation durations do.
Duration patternMs(int ms) => Duration(milliseconds: ms);
