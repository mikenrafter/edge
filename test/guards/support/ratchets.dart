// ratchets.dart — the registry of every "improvement list" (owner rule B).
//
// An improvement list is a baseline, allow-list or exception map that records
// existing debt in a guard. Each may only SHRINK. This file names them all and
// says how to count each. ratchet_lists_test.dart compares the counts at HEAD
// with the same lists at the target branch (env RATCHET_BASE) or, when that is
// unset, with the checked-in snapshot test/guards/ratchet_counts.json, and fails
// if any count grew. A list added to the registry is fine. A list removed from
// it fails (you cannot escape a ratchet by unregistering it).
//
// Counts are `Map<String, int>` per list; the key names are part of the
// contract (see each [RatchetKind]).

import 'dart:convert';
import 'dart:io';

import 'code_lines.dart';

/// How a list is stored, and so how it is counted.
enum RatchetKind {
  /// test/guards/heavy_calc_baseline.json
  /// (`{version, ruleVersions, occurrences: [{..., count}]}`).
  /// Counts: `entries` = occurrences.length, `occurrences` = sum of `count`.
  heavyBaselineJson,

  /// A flat JSON object `{ "<path>": <int size> }`
  /// (test/guards/file_size_exceptions.json).
  /// Counts: `entries` = key count, and one `size:<path>` per key holding that
  /// path's recorded size (a size may only go down; a key new in HEAD is
  /// growth).
  sizeMapJson,

  /// A Dart collection literal assigned to [RatchetList.symbol]
  /// (`symbol = <T>{...}` / `[...]`, optional `const`/type before the symbol,
  /// optional `<...>` type arguments right after `=`). Counts: `entries` = the
  /// number of top-level elements (map entries count once). Strings (single,
  /// double, triple, raw, adjacent-concatenated), comments, nested brackets and
  /// record values `(a: 1, b: 'x, y')` must not confuse the element count. When
  /// [RatchetList.sumField] is set, also `sum` = the sum of that named integer
  /// field over the elements' record values (`(count: 3, why: '...')`).
  dartLiteral,

  /// A Dart map whose values are themselves collection literals.
  /// Counts: `entries` = top-level entries, `leaves` = the total number of
  /// top-level elements across those value literals.
  dartLiteralNested,

  /// A `RegExp(...)` assigned to [RatchetList.symbol] whose pattern is built
  /// from adjacent string literals. Counts: `entries` = the number of TOP-LEVEL
  /// alternatives (split on `|` outside groups, character classes and escapes).
  dartRegexAlternatives,
}

class RatchetList {
  /// Stable name; the key in ratchet_counts.json. Never reused.
  final String id;

  /// Repo-relative path using forward slashes.
  final String file;
  final RatchetKind kind;

  /// The Dart identifier for the Dart kinds; null for the JSON kinds.
  final String? symbol;

  /// For [RatchetKind.dartLiteral]: a record field to sum into `sum`.
  final String? sumField;

  const RatchetList(
    this.id,
    this.file,
    this.kind, {
    this.symbol,
    this.sumField,
  });
}

/// Every improvement list found under lib/ and test/. Counts at the time of
/// writing are in the comment on each row.
const List<RatchetList> kRatchets = <RatchetList>[
  // 1986 entries, 2190 occurrences.
  RatchetList('heavy_calc_baseline', 'test/guards/heavy_calc_baseline.json',
      RatchetKind.heavyBaselineJson),
  // One entry per file over 6,000 code lines.
  RatchetList('file_size_exceptions', 'test/guards/file_size_exceptions.json',
      RatchetKind.sizeMapJson),
  // 33
  RatchetList('worker_unresolved_ok', 'lib/util/worker_entries.dart',
      RatchetKind.dartLiteral,
      symbol: 'kUnresolvedOk'),
  // 50
  RatchetList('p21_pinned_dynamic_writers',
      'test/step2/p21_write_seam_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_pinnedDynamicWriters'),
  // 13
  RatchetList('p21_pinned_table_lists',
      'test/step2/p21_write_seam_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_pinnedTableLists'),
  // 2 tables, 12 writer members (`LocalDb.putDayResult` -> verbs).
  RatchetList('p21_allowed_writers',
      'test/step2/p21_write_seam_guard_test.dart', RatchetKind.dartLiteralNested,
      symbol: '_allowed'),
  // 6
  RatchetList('p22_legacy_callers', 'test/step2/p22_decode_guard_test.dart',
      RatchetKind.dartLiteral,
      symbol: '_legacyCallers'),
  // 6
  RatchetList('p23_direct_callers', 'test/step2/p23_call_sites_test.dart',
      RatchetKind.dartLiteral,
      symbol: '_directCallers'),
  // 2 files, `count` sums to 9.
  RatchetList('p24_from_json_callers', 'test/step2/p24_call_sites_test.dart',
      RatchetKind.dartLiteral,
      symbol: '_fromJsonCallers', sumField: 'count'),
  // 10
  RatchetList('ecg_gesture_consumer_allow',
      'test/ecg_gesture_consumer_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_allow'),
  // 1
  RatchetList('observation_isolation_allowed',
      'test/observation_isolation_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowedToNameTheTable'),
  // 2 alternatives.
  RatchetList('sample_guard_slice_entry',
      'test/sample_archive/sample_guard_test.dart',
      RatchetKind.dartRegexAlternatives,
      symbol: '_sliceEntry'),
  // 3
  RatchetList('scan_lock_entry_points_allowlist',
      'test/scan_lock_entry_points_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowlist'),
  // 1
  RatchetList('one_band_event_switch_allowlist',
      'test/one_band_event_switch_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowlist'),
  // 6
  RatchetList('ui2_spinner_status_allowed',
      'test/ui2_spinner_status_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowed'),
  // 1
  RatchetList('copy_jargon_allowed_keys', 'test/copy_jargon_guard_test.dart',
      RatchetKind.dartLiteral,
      symbol: '_allowedKeys'),
  // 3
  RatchetList('copy_jargon_allowed_prefixes',
      'test/copy_jargon_guard_test.dart', RatchetKind.dartLiteral,
      symbol: '_allowedPrefixes'),
  // 1
  RatchetList('background_legacy_inline_dispatches',
      'test/guards/support/legacy_inline_dispatches.dart',
      RatchetKind.dartLiteral,
      symbol: 'kLegacyInlineDispatches'),
  // 0 (empty today: a new exemption is growth).
  RatchetList('heavy_migration_methods',
      'test/guards/support/heavy_guard.dart', RatchetKind.dartLiteral,
      symbol: 'kMigrationMethods'),
  // 3 (edge entries only until design 06 step 1b; it may only shrink).
  RatchetList('group_unknown_cost_members',
      'lib/compute/groups/edge_groups.dart', RatchetKind.dartLiteral,
      symbol: 'kGroupUnknownCostMembers'),
];

/// Reads a repo-relative file; null when it does not exist.
typedef SourceReader = Future<String?> Function(String repoRelativePath);

/// Reads from a directory (a work tree or a fixture).
SourceReader dirReader(String root) => (String rel) async {
      final f = File('$root/$rel');
      return f.existsSync() ? f.readAsString() : null;
    };

/// Reads `git show <ref>:<path>` in [repoDir]. Null when the file does not
/// exist at the ref. An unresolvable ref throws a [StateError] naming the ref
/// (never silently skips; same behaviour as readBaselineAtRef).
SourceReader gitRefReader(String ref, {required String repoDir}) =>
    (String rel) async {
      final check = await Process.run(
        'git',
        ['rev-parse', '--verify', '--quiet', '$ref^{commit}'],
        workingDirectory: repoDir,
      );
      if (check.exitCode != 0) {
        throw StateError('cannot resolve git ref "$ref" in $repoDir');
      }
      final r = await Process.run(
        'git',
        ['show', '$ref:$rel'],
        workingDirectory: repoDir,
      );
      return r.exitCode == 0 ? r.stdout as String : null;
    };

/// Same-length copies of [s]: `stripped` blanks comments, `masked` also
/// replaces every string literal by `S` plus spaces, so structure (brackets,
/// commas, `:`) can be scanned without strings getting in the way. Newlines
/// are kept; indexes agree across all three.
({String stripped, String masked}) _prepare(String s) {
  final st = StringBuffer();
  final mk = StringBuffer();
  void blank(int from, int to) {
    for (var k = from; k < to; k++) {
      final c = s[k] == '\n' ? '\n' : ' ';
      st.write(c);
      mk.write(c);
    }
  }

  var i = 0;
  while (i < s.length) {
    if (s.startsWith('//', i)) {
      var e = i;
      while (e < s.length && s[e] != '\n') {
        e++;
      }
      blank(i, e);
      i = e;
    } else if (s.startsWith('/*', i)) {
      final e = skipBlockComment(s, i);
      blank(i, e);
      i = e;
    } else if (isDartStringStart(s, i)) {
      final e = skipDartString(s, i);
      st.write(s.substring(i, e));
      mk.write('S');
      for (var k = i + 1; k < e; k++) {
        mk.write(s[k] == '\n' ? '\n' : ' ');
      }
      i = e;
    } else {
      st.write(s[i]);
      mk.write(s[i]);
      i++;
    }
  }
  return (stripped: st.toString(), masked: mk.toString());
}

int _skipWs(String s, int i) {
  while (i < s.length && ' \t\r\n'.contains(s[i])) {
    i++;
  }
  return i;
}

/// From [i] skips optional `const` and `<...>` type arguments; returns the
/// index of what follows (whitespace skipped).
int _skipConstAndTypeArgs(String m, int i) {
  i = _skipWs(m, i);
  if (m.startsWith('const', i) &&
      i + 5 < m.length &&
      !_isIdent(m.codeUnitAt(i + 5))) {
    i = _skipWs(m, i + 5);
  }
  if (i < m.length && m[i] == '<') {
    var depth = 0;
    for (; i < m.length; i++) {
      if (m[i] == '<') depth++;
      if (m[i] == '>' && --depth == 0) {
        i++;
        break;
      }
    }
    i = _skipWs(m, i);
  }
  return i;
}

bool _isIdent(int c) =>
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) ||
    c == 95 || c == 36;

/// Index just past `symbol =` for the first declaration-looking match whose
/// right-hand side (after `const` / type arguments) begins with one of
/// [openers]; -1 when there is none.
int _findDeclaration(String masked, String symbol, String openers) {
  final re = RegExp('(?<![A-Za-z0-9_\$])${RegExp.escape(symbol)}\\s*=(?![=>])');
  for (final m in re.allMatches(masked)) {
    final p = _skipConstAndTypeArgs(masked, m.end);
    if (p < masked.length && openers.contains(masked[p])) return p;
  }
  return -1;
}

/// The top-level elements of the collection literal opened at [open]
/// (a `{` or `[` in [masked]), as (start, end) index ranges. Empty elements
/// (trailing commas, empty literals) are dropped.
List<(int, int)> _elements(String masked, int open) {
  final out = <(int, int)>[];
  var depth = 0;
  var start = open + 1;
  void flush(int end) {
    if (masked.substring(start, end).trim().isNotEmpty) out.add((start, end));
  }

  for (var i = open + 1; i < masked.length; i++) {
    final c = masked[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) {
        flush(i);
        return out;
      }
      depth--;
    } else if (c == ',' && depth == 0) {
      flush(i);
      start = i + 1;
    }
  }
  throw StateError('unterminated collection literal');
}

/// Splits the pattern on `|` outside groups, classes and escapes.
int _regexAlternatives(String pattern) {
  var depth = 0;
  var inClass = false;
  var alts = 1;
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == r'\') {
      i++;
    } else if (inClass) {
      if (c == ']') inClass = false;
    } else if (c == '[') {
      inClass = true;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (c == '|' && depth == 0) {
      alts++;
    }
  }
  return alts;
}

/// Counts one list from its file's text. See [RatchetKind] for the keys.
/// Throws [FormatException]/[StateError] naming the list when the text does not
/// contain what the kind expects (missing symbol, bad JSON).
Map<String, int> countRatchet(RatchetList list, String source) {
  switch (list.kind) {
    case RatchetKind.heavyBaselineJson:
      final raw = jsonDecode(source);
      final occ = (raw is Map ? raw['occurrences'] : null);
      if (occ is! List) {
        throw StateError('${list.id}: no "occurrences" list');
      }
      var total = 0;
      for (final o in occ) {
        total += (o as Map)['count'] as int;
      }
      return {'entries': occ.length, 'occurrences': total};
    case RatchetKind.sizeMapJson:
      final raw = jsonDecode(source);
      if (raw is! Map) throw StateError('${list.id}: expected a JSON object');
      return {
        'entries': raw.length,
        for (final e in raw.entries) 'size:${e.key}': e.value as int,
      };
    case RatchetKind.dartLiteral:
    case RatchetKind.dartLiteralNested:
      final symbol = list.symbol!;
      final m = _prepare(source).masked;
      final open = _findDeclaration(m, symbol, '{[');
      if (open < 0) {
        throw StateError('${list.id}: no collection literal assigned to '
            '$symbol in ${list.file}');
      }
      final elems = _elements(m, open);
      if (list.kind == RatchetKind.dartLiteralNested) {
        var leaves = 0;
        for (final (s, e) in elems) {
          var depth = 0;
          var colon = -1;
          for (var i = s; i < e && colon < 0; i++) {
            final c = m[i];
            if ('([{'.contains(c)) depth++;
            if (')]}'.contains(c)) depth--;
            if (c == ':' && depth == 0) colon = i;
          }
          if (colon < 0) continue;
          final p = _skipConstAndTypeArgs(m, colon + 1);
          if (p < e && '{['.contains(m[p])) leaves += _elements(m, p).length;
        }
        return {'entries': elems.length, 'leaves': leaves};
      }
      final out = {'entries': elems.length};
      final field = list.sumField;
      if (field != null) {
        final re = RegExp('(?<![A-Za-z0-9_\$])${RegExp.escape(field)}\\s*:\\s*(-?\\d+)');
        var sum = 0;
        for (final (s, e) in elems) {
          for (final f in re.allMatches(m.substring(s, e))) {
            sum += int.parse(f.group(1)!);
          }
        }
        out['sum'] = sum;
      }
      return out;
    case RatchetKind.dartRegexAlternatives:
      final symbol = list.symbol!;
      final p = _prepare(source);
      final re = RegExp(
          '(?<![A-Za-z0-9_\$])${RegExp.escape(symbol)}\\s*=\\s*RegExp\\s*\\(');
      final m = re.firstMatch(p.masked);
      if (m == null) {
        throw StateError('${list.id}: no RegExp assigned to $symbol in '
            '${list.file}');
      }
      final text = p.stripped;
      final pattern = StringBuffer();
      var i = _skipWs(text, m.end);
      while (i < text.length && isDartStringStart(text, i)) {
        final end = skipDartString(text, i);
        final lit = text.substring(i, end);
        final raw = lit.startsWith('r');
        final body = raw ? lit.substring(1) : lit;
        final q = body.startsWith(body[0] * 3) && body.length >= 6 ? 3 : 1;
        final content = body.substring(q, body.length - q);
        pattern.write(raw ? content : content.replaceAll(r'\\', r'\'));
        i = _skipWs(text, end);
      }
      if (pattern.isEmpty) {
        throw StateError('${list.id}: $symbol is not built from string '
            'literals');
      }
      return {'entries': _regexAlternatives(pattern.toString())};
  }
}

/// Counts every list in [lists] through [read]. A list whose file is missing is
/// omitted when [missingIsError] is false (it was introduced after that
/// snapshot) and throws a [StateError] naming the list when true (HEAD must
/// have every registered file).
Future<Map<String, Map<String, int>>> countRatchets(
  SourceReader read, {
  Iterable<RatchetList> lists = kRatchets,
  bool missingIsError = true,
}) async {
  final out = <String, Map<String, int>>{};
  for (final list in lists) {
    final text = await read(list.file);
    if (text == null) {
      if (missingIsError) {
        throw StateError('${list.id}: ${list.file} does not exist');
      }
      continue;
    }
    out[list.id] = countRatchet(list, text);
  }
  return out;
}

/// One reason per count that is higher in [head] than in [base]. A list that is
/// only in [head] (newly registered) is fine. A count key absent from [base]
/// reads as 0 there, so a new key with a positive value is growth. A key that
/// disappeared from [head], or a lower count, is a shrink and passes. Each
/// reason names the list id and the key.
List<String> ratchetGrowth({
  required Map<String, Map<String, int>> base,
  required Map<String, Map<String, int>> head,
}) {
  final reasons = <String>[];
  for (final l in head.entries) {
    final b = base[l.key];
    if (b == null) continue;
    for (final c in l.value.entries) {
      final was = b[c.key] ?? 0;
      if (c.value > was) {
        reasons.add('${l.key}: ${c.key} grew from $was to ${c.value}; '
            'improvement lists may only shrink');
      }
    }
  }
  return reasons;
}

/// One reason per id in [baseIds] that is not in [headIds] (unregistered).
/// Extra ids in [headIds] are fine.
List<String> unregisteredRatchets({
  required Iterable<String> baseIds,
  required Iterable<String> headIds,
}) {
  final head = headIds.toSet();
  return [
    for (final id in baseIds)
      if (!head.contains(id))
        '$id: ratchet list was removed from the registry (kRatchets)',
  ];
}

/// test/guards/ratchet_counts.json: `{"version": 1, "lists": {id: {key: int}}}`.
Map<String, Map<String, int>> parseRatchetSnapshot(String json) {
  final raw = jsonDecode(json);
  if (raw is! Map || raw['version'] != 1 || raw['lists'] is! Map) {
    throw FormatException('unsupported ratchet snapshot format');
  }
  return {
    for (final l in (raw['lists'] as Map).entries)
      l.key as String: {
        for (final c in (l.value as Map).entries) c.key as String: c.value as int,
      },
  };
}

String encodeRatchetSnapshot(Map<String, Map<String, int>> counts) {
  final ids = counts.keys.toList()..sort();
  final lists = <String, Object>{};
  for (final id in ids) {
    final keys = counts[id]!.keys.toList()..sort();
    lists[id] = {for (final k in keys) k: counts[id]![k]!};
  }
  return '${const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'lists': lists,
      })}\n';
}
