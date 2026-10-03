// 8AD: building a device's haptic vocabulary from SEVERAL probe logs.
//
// HapticDeviceProfile.whoopMg was read by hand from the L6 log. This does the
// same reading in code, over any number of logs, so a new log widens the
// table by a reviewed change (tool/build_haptic_vocab.dart prints the diff and
// the new table) instead of a hand edit. Pure Dart.
//
// How a row is read. Every base phrase and gap names the probe tests it was
// measured from. For each of those tests, every log's heard line is gathered:
//
//  * A one-command test (looped, or one command listing the effect twice) is
//    one rendition of the phrase: the A and the B text, leading and trailing
//    rests dropped.
//  * A test of 2 or 3 commands is split back into one rendition per command:
//    the notes are cut into groups of as many notes as the phrase has (taken
//    from the base), each group runs from its first note to its last (rests
//    between them stay), and the rest between two groups is the gap the test
//    heard. If the notes do not divide that way, the test is not read and the
//    base keeps what it had.
//  * A phrase's min and max are the shortest and the longest rendition by
//    total sixteenths. Among equal lengths the rendition heard most often
//    wins (then the smaller code), so a one-off spike does not set the
//    loudness. A phrase is not stable when any log flags any of its tests
//    unstable; a log can only clear stability, never restore it.
//  * A gap row's min and max are the shortest and longest rest heard. Two rows
//    can share a test (the stable and the spread 100 ms rows both list test
//    7), so a heard rest goes to the narrowest row of those listing its test
//    whose base range holds it, else to the widest. That attribution reads the
//    base ranges and is the one judgement in here.
//
// A phrase or gap no log mentions is kept as the base has it. id, name, unitMs
// and probeSetId come from the base; the version is the base's plus one when
// anything changed.

import '../gestures/pattern_transcript.dart';
import 'haptic_profile.dart';
import 'heard_log.dart';

final RegExp _commands = RegExp(r'(\d+) commands');

String _code(List<PatternEntry> es) => es.join(' ');

int _units(List<PatternEntry> es) => es.fold(0, (s, e) => s + e.length);

/// [es] without leading and trailing rests.
List<PatternEntry> _trim(List<PatternEntry> es) {
  final first = es.indexWhere((e) => e.note);
  if (first < 0) return const [];
  return es.sublist(first, es.lastIndexWhere((e) => e.note) + 1);
}

class _Reading {
  final List<List<PatternEntry>> renditions = [];
  final List<int> rests = [];
}

// What one rendition says: its per-command renditions and between-command
// rests, or null when it cannot be split into [commands] groups of
// [notesPerCommand] notes.
_Reading? _read(List<PatternEntry> es, int commands, int notesPerCommand) {
  final t = _trim(es);
  if (t.isEmpty) return _Reading();
  final out = _Reading();
  if (commands <= 1) {
    out.renditions.add(t);
    return out;
  }
  final noteAt = [
    for (var i = 0; i < t.length; i++)
      if (t[i].note) i,
  ];
  if (notesPerCommand < 1 || noteAt.length != commands * notesPerCommand) {
    return null;
  }
  for (var g = 0; g < commands; g++) {
    final from = noteAt[g * notesPerCommand];
    final to = noteAt[(g + 1) * notesPerCommand - 1];
    out.renditions.add(t.sublist(from, to + 1));
    if (g > 0) {
      final prevEnd = noteAt[g * notesPerCommand - 1];
      out.rests.add(_units(t.sublist(prevEnd + 1, from)));
    }
  }
  return out;
}

List<PatternEntry> _withDynamic(List<PatternEntry> es, PatternDynamic d) => [
  for (final e in es)
    e.note ? PatternEntry(note: true, length: e.length, dynamic: d) : e,
];

// The rendition with the fewest (or most) units, ties to the one heard most
// often, then to the smaller code.
List<PatternEntry> _pick(
  Map<String, List<PatternEntry>> byCode,
  Map<String, int> counts, {
  required bool shortest,
}) {
  final keys = byCode.keys.toList()
    ..sort((a, b) {
      final ua = _units(byCode[a]!);
      final ub = _units(byCode[b]!);
      if (ua != ub) return shortest ? ua - ub : ub - ua;
      final c = counts[b]! - counts[a]!;
      return c != 0 ? c : a.compareTo(b);
    });
  return byCode[keys.first]!;
}

/// The profile that [logTexts] describe, over [base]. [dynamicOverrides] sets
/// every note of the named phrase's min and max to a dynamic (the L6 table has
/// a single effect 14 at f, "14 is F, while 47 is FF").
HapticDeviceProfile buildProfileFromLogs(
  List<String> logTexts, {
  required HapticDeviceProfile base,
  Map<String, PatternDynamic> dynamicOverrides = const {},
}) {
  final heard = <int, List<HeardTest>>{};
  for (final text in logTexts) {
    for (final h in parseHeardLines(text)) {
      (heard[h.test] ??= []).add(h);
    }
  }

  // The base phrase that owns each test, for the notes-per-command of a split.
  final phraseOf = <int, HapticPhrase>{
    for (final p in base.phrases)
      for (final t in p.sourceTests) t: p,
  };

  final gapSamples = List.generate(base.gaps.length, (_) => <int>[]);
  final phraseReadings = <String, List<List<PatternEntry>>>{};

  for (final e in heard.entries) {
    final owner = phraseOf[e.key];
    for (final h in e.value) {
      final k = int.tryParse(_commands.firstMatch(h.description)?[1] ?? '') ?? 1;
      final m = owner == null ? 0 : owner.min.where((x) => x.note).length;
      for (final rendition in [h.a, h.b]) {
        final r = _read(rendition, k, m);
        if (r == null) continue;
        if (owner != null) {
          (phraseReadings[owner.id] ??= []).addAll(r.renditions);
        }
        for (final rest in r.rests) {
          final rows = [
            for (var i = 0; i < base.gaps.length; i++)
              if (base.gaps[i].sourceTests.contains(e.key)) i,
          ];
          if (rows.isEmpty) continue;
          int spread(int i) => base.gaps[i].maxUnits - base.gaps[i].minUnits;
          final holding = [
            for (final i in rows)
              if (base.gaps[i].minUnits <= rest && rest <= base.gaps[i].maxUnits)
                i,
          ];
          final pool = holding.isEmpty ? rows : holding;
          var best = pool.first;
          for (final i in pool) {
            if (holding.isEmpty ? spread(i) > spread(best) : spread(i) < spread(best)) {
              best = i;
            }
          }
          gapSamples[best].add(rest);
        }
      }
    }
  }

  bool flagged(List<int> tests) => tests.any(
    (t) => heard[t]?.any((h) => h.unstable) ?? false,
  );

  var changed = false;
  final phrases = <HapticPhrase>[];
  for (final p in base.phrases) {
    var min = p.min;
    var max = p.max;
    final seen = phraseReadings[p.id];
    if (seen != null && seen.isNotEmpty) {
      final byCode = <String, List<PatternEntry>>{};
      final counts = <String, int>{};
      for (final r in seen) {
        final c = _code(r);
        byCode[c] = r;
        counts[c] = (counts[c] ?? 0) + 1;
      }
      min = _pick(byCode, counts, shortest: true);
      max = _pick(byCode, counts, shortest: false);
    }
    final d = dynamicOverrides[p.id];
    if (d != null) {
      min = _withDynamic(min, d);
      max = _withDynamic(max, d);
    }
    final stable = p.stable && !flagged(p.sourceTests);
    if (_code(min) != _code(p.min) ||
        _code(max) != _code(p.max) ||
        stable != p.stable) {
      changed = true;
      phrases.add(HapticPhrase(
        id: p.id,
        effects: p.effects,
        loop: p.loop,
        min: min,
        max: max,
        stable: stable,
        sourceTests: p.sourceTests,
      ));
    } else {
      phrases.add(p);
    }
  }

  final gaps = <HapticGap>[];
  for (var i = 0; i < base.gaps.length; i++) {
    final g = base.gaps[i];
    final s = gapSamples[i];
    var lo = g.minUnits;
    var hi = g.maxUnits;
    if (s.isNotEmpty) {
      lo = s.reduce((a, b) => a < b ? a : b);
      hi = s.reduce((a, b) => a > b ? a : b);
    }
    final stable = g.stable && !flagged(g.sourceTests);
    if (lo != g.minUnits || hi != g.maxUnits || stable != g.stable) {
      changed = true;
      gaps.add(HapticGap(
        delayMs: g.delayMs,
        minUnits: lo,
        maxUnits: hi,
        stable: stable,
        sourceTests: g.sourceTests,
      ));
    } else {
      gaps.add(g);
    }
  }

  return HapticDeviceProfile(
    id: base.id,
    name: base.name,
    unitMs: base.unitMs,
    probeSetId: base.probeSetId,
    version: changed ? base.version + 1 : base.version,
    phrases: phrases,
    gaps: gaps,
  );
}

String _range(int lo, int hi) => lo == hi ? '$lo' : '$lo-$hi';

String _gapKey(HapticGap g) => '${g.delayMs}|${g.sourceTests.join(',')}';

/// What changed from [a] to [b], one line each: "No changes" when nothing did;
/// else the version, then every phrase and gap whose range or stability
/// differs, with the old and the new.
String describeProfileDiff(HapticDeviceProfile a, HapticDeviceProfile b) {
  final lines = <String>[];
  if (a.version != b.version) {
    lines.add('version ${a.version} -> ${b.version}');
  }
  final aPhrases = {for (final p in a.phrases) p.id: p};
  final bPhrases = {for (final p in b.phrases) p.id: p};
  for (final id in {...aPhrases.keys, ...bPhrases.keys}) {
    final x = aPhrases[id];
    final y = bPhrases[id];
    if (x == null) {
      lines.add('$id: added (${_code(y!.min)} to ${_code(y.max)})');
    } else if (y == null) {
      lines.add('$id: removed');
    } else {
      final parts = [
        if (_code(x.min) != _code(y.min))
          'min ${_code(x.min)} -> ${_code(y.min)}',
        if (_code(x.max) != _code(y.max))
          'max ${_code(x.max)} -> ${_code(y.max)}',
        if (x.stable && !y.stable) 'now unstable',
        if (!x.stable && y.stable) 'now stable',
      ];
      if (parts.isNotEmpty) lines.add('$id: ${parts.join(', ')}');
    }
  }
  final aGaps = {for (final g in a.gaps) _gapKey(g): g};
  final bGaps = {for (final g in b.gaps) _gapKey(g): g};
  for (final key in {...aGaps.keys, ...bGaps.keys}) {
    final x = aGaps[key];
    final y = bGaps[key];
    final name = 'gap ${(x ?? y)!.delayMs} ms '
        '(tests ${(x ?? y)!.sourceTests.join(', ')})';
    if (x == null) {
      lines.add('$name: added');
    } else if (y == null) {
      lines.add('$name: removed');
    } else {
      final parts = [
        if (x.minUnits != y.minUnits || x.maxUnits != y.maxUnits)
          '${_range(x.minUnits, x.maxUnits)} -> '
              '${_range(y.minUnits, y.maxUnits)} sixteenths',
        if (x.stable && !y.stable) 'now unstable',
        if (!x.stable && y.stable) 'now stable',
      ];
      if (parts.isNotEmpty) lines.add('$name: ${parts.join(', ')}');
    }
  }
  return lines.isEmpty ? 'No changes' : lines.join('\n');
}

/// [p]'s phrases and gaps as the Dart source of a HapticDeviceProfile table.
String describeProfileAsDart(HapticDeviceProfile p) {
  final b = StringBuffer('    phrases: [\n');
  for (final ph in p.phrases) {
    final max = _code(ph.max) == _code(ph.min) ? 'null' : "'${_code(ph.max)}'";
    b.writeln(
      "      _phrase('${ph.id}', ${ph.effects}, ${ph.loop}, "
      "'${_code(ph.min)}', $max, ${ph.sourceTests}"
      '${ph.stable ? '' : ', stable: false'}),',
    );
  }
  b.writeln('    ],\n    gaps: [');
  for (final g in p.gaps) {
    b.writeln(
      '      HapticGap(delayMs: ${g.delayMs}, minUnits: ${g.minUnits}, '
      'maxUnits: ${g.maxUnits}${g.stable ? '' : ', stable: false'}, '
      'sourceTests: ${g.sourceTests}),',
    );
  }
  b.write('    ],');
  return b.toString();
}
