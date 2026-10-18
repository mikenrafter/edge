// sqlite_floor_guard_test.dart — the SQL in lib/ must run on SQLite 3.18.
//
// THE FLOOR. minSdk is 26 (Android 8.0), whose system SQLite is 3.18. sqflite on
// Android uses the system library, so every statement the app issues has to be
// valid there. Anything newer fails at run time with a syntax error or
// `no such function` - on a launch path (`_repairOpenSchema` runs on every
// open) that means the database does not open at all on Android 8-10.
//
// WHY THE DESKTOP TESTS CANNOT CATCH THIS. `flutter test` runs sqflite_common_ffi
// against the host's libsqlite3, which is 3.40 or newer: every feature below
// works there. A statement that is fine in every test can still brick a phone.
// So this guard reads the SQL text instead of running it.
//
// WHAT IT SCANS. Every Dart string literal in lib/ (adjacent literals are
// joined, because SQL is often split across several), but only literals that
// look like SQL (they contain SELECT / INSERT / UPDATE / DELETE / CREATE /
// ALTER / PRAGMA / WITH / FROM / WHERE / VALUES as a whole word). Comments are
// skipped. Patterns are whole-word and case-insensitive.
//
// WHAT IT FLAGS (SQLite version that introduced it):
//   OVER (...)            window functions            3.25
//   FILTER (WHERE ...)    aggregate FILTER            3.30
//   ON CONFLICT .. DO UPDATE  upsert                  3.24
//   RETURNING             RETURNING clause            3.35
//   IIF(                  iif()                       3.32
//   ->  /  ->>            JSON operators              3.38
//   DROP COLUMN           ALTER TABLE ... DROP COLUMN 3.35
//   RENAME COLUMN         ALTER TABLE ... RENAME COLUMN  3.25
//   NULLS FIRST / LAST    ORDER BY ... NULLS          3.30
//   GENERATED ALWAYS      generated columns           3.31
//   STRICT                STRICT tables               3.37
//
// To use one on purpose, gate it behind a version check at run time - do not
// add it to this list's tolerance.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// (name, version, pattern). Patterns run on the joined text of one SQL literal.
final List<(String, String, RegExp)> _features = [
  ('window function (OVER)', '3.25', RegExp(r'\bOVER\s*\(', caseSensitive: false)),
  // A named window (`OVER w … WINDOW w AS (…)`) has no parenthesis after OVER;
  // its WINDOW clause is the unambiguous part.
  ('named window (WINDOW … AS)', '3.25',
      RegExp(r'\bWINDOW\s+\w+\s+AS\s*\(', caseSensitive: false)),
  ('aggregate FILTER (WHERE', '3.30', RegExp(r'\bFILTER\s*\(\s*WHERE\b', caseSensitive: false)),
  ('upsert (DO UPDATE)', '3.24', RegExp(r'\bON\s+CONFLICT\b[^;]*\bDO\s+UPDATE\b', caseSensitive: false)),
  ('RETURNING', '3.35', RegExp(r'\bRETURNING\b', caseSensitive: false)),
  ('IIF()', '3.32', RegExp(r'\bIIF\s*\(', caseSensitive: false)),
  // A path ('$.a') or an array index (0) operand; `a -> b` prose stays unflagged.
  ("JSON operator (-> / ->>)", '3.38', RegExp(r"->>?\s*(['\x22]|\d)")),
  ('DROP COLUMN', '3.35', RegExp(r'\bDROP\s+COLUMN\b', caseSensitive: false)),
  ('RENAME COLUMN', '3.25', RegExp(r'\bRENAME\s+COLUMN\b', caseSensitive: false)),
  ('NULLS FIRST/LAST', '3.30', RegExp(r'\bNULLS\s+(FIRST|LAST)\b', caseSensitive: false)),
  ('GENERATED ALWAYS', '3.31', RegExp(r'\bGENERATED\s+ALWAYS\b', caseSensitive: false)),
  ('STRICT table', '3.37', RegExp(r'\)\s*STRICT\b', caseSensitive: false)),
];

final RegExp _looksLikeSql = RegExp(
  r'\b(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|PRAGMA|WITH|FROM|WHERE|VALUES)\b',
  caseSensitive: false,
);

/// The string literals of Dart [src] (comments skipped), with adjacent literals
/// joined into one. Interpolations are kept as text.
List<String> dartStringLiterals(String src) {
  final out = <String>[];
  final cur = StringBuffer();
  var open = false; // is `cur` collecting adjacent literals?
  var i = 0;
  final n = src.length;

  void flush() {
    if (open) out.add(cur.toString());
    cur.clear();
    open = false;
  }

  bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  while (i < n) {
    final c = src[i];
    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      final end = src.indexOf('*/', i + 2);
      i = end < 0 ? n : end + 2;
      continue;
    }
    var raw = false;
    var start = i;
    if (c == 'r' && i + 1 < n && (src[i + 1] == "'" || src[i + 1] == '"')) {
      // a raw string only when `r` is not the tail of an identifier
      if (i == 0 || !RegExp(r'[A-Za-z0-9_$]').hasMatch(src[i - 1])) {
        raw = true;
        start = i + 1;
      }
    }
    final q = src[start];
    if (q == "'" || q == '"') {
      final triple = start + 2 < n && src[start + 1] == q && src[start + 2] == q;
      final quoteLen = triple ? 3 : 1;
      var j = start + quoteLen;
      final body = StringBuffer();
      while (j < n) {
        final d = src[j];
        if (!raw && d == r'\') {
          body.write(src.substring(j, j + 2 > n ? n : j + 2));
          j += 2;
          continue;
        }
        if (!raw && d == r'$' && j + 1 < n && src[j + 1] == '{') {
          var depth = 0;
          final from = j;
          while (j < n) {
            if (src[j] == '{') depth++;
            if (src[j] == '}' && --depth == 0) {
              j++;
              break;
            }
            j++;
          }
          body.write(src.substring(from, j));
          continue;
        }
        if (d == q && (!triple || (j + 2 < n && src[j + 1] == q && src[j + 2] == q))) {
          break;
        }
        body.write(d);
        j++;
      }
      cur.write(body);
      open = true;
      i = j + quoteLen;
      // adjacent literal? only whitespace may follow before the next quote
      var k = i;
      while (k < n && isSpace(src.codeUnitAt(k))) {
        k++;
      }
      final next = k < n ? src[k] : '';
      final nextRaw = next == 'r' && k + 1 < n && (src[k + 1] == "'" || src[k + 1] == '"');
      if (next == "'" || next == '"' || nextRaw) {
        cur.write(' ');
        i = k;
        continue;
      }
      flush();
      continue;
    }
    i++;
  }
  flush();
  return out;
}

/// Findings (`path: feature (needs SQLite x): excerpt`) for the SQL in [src].
List<String> sqliteFloorViolations(String path, String src) {
  final found = <String>[];
  for (final literal in dartStringLiterals(src)) {
    if (!_looksLikeSql.hasMatch(literal)) continue;
    for (final (name, version, pattern) in _features) {
      final m = pattern.firstMatch(literal);
      if (m == null) continue;
      final from = (m.start - 30).clamp(0, literal.length);
      final to = (m.end + 30).clamp(0, literal.length);
      found.add(
        '$path: $name (needs SQLite $version): '
        '...${literal.substring(from, to).replaceAll(RegExp(r'\s+'), ' ')}...',
      );
    }
  }
  return found;
}

void main() {
  group('the scanner', () {
    List<String> scan(String code) => sqliteFloorViolations('x.dart', code);

    test('flags each feature newer than SQLite 3.18', () {
      const samples = {
        'window function (OVER)': "'SELECT ROW_NUMBER() OVER (ORDER BY a) FROM t'",
        'upsert (DO UPDATE)': "'INSERT INTO t VALUES (1) ON CONFLICT(a) DO UPDATE SET b = 1'",
        'RETURNING': "'DELETE FROM t RETURNING a'",
        'IIF()': "'SELECT IIF(a, 1, 2) FROM t'",
        'JSON operator': '"SELECT payload ->> \'\$.x\' FROM t"',
        'DROP COLUMN': "'ALTER TABLE t DROP COLUMN a'",
        'RENAME COLUMN': "'ALTER TABLE t RENAME COLUMN a TO b'",
        'NULLS FIRST/LAST': "'SELECT a FROM t ORDER BY a NULLS LAST'",
        'aggregate FILTER': "'SELECT COUNT(*) FILTER (WHERE a) FROM t'",
        'GENERATED ALWAYS': "'CREATE TABLE t (a INT GENERATED ALWAYS AS (1))'",
        'STRICT table': "'CREATE TABLE t (a INT) STRICT'",
      };
      for (final e in samples.entries) {
        expect(scan(e.value), isNotEmpty, reason: e.key);
      }
    });

    test('sees SQL split across adjacent literals and triple-quoted SQL', () {
      expect(scan("'SELECT a, ROW_NUMBER() ' 'OVER (ORDER BY a) FROM t'"), isNotEmpty);
      expect(scan("'''\n  SELECT COUNT(*) OVER () FROM t\n'''"), isNotEmpty);
      expect(scan("'SELECT ROW_NUMBER() OVER w FROM t WINDOW w AS (ORDER BY a)'"),
          isNotEmpty, reason: 'a named window');
      expect(scan("'SELECT payload ->> 0 FROM t'"), isNotEmpty,
          reason: 'a JSON operator with an index operand');
    });

    test('does not flag Dart code, comments, or prose', () {
      expect(scan('// SELECT x OVER (y)\nfinal a = 1;'), isEmpty);
      expect(scan('/* SELECT x OVER (y) */ final a = 1;'), isEmpty);
      expect(scan("final s = 'moved over (the hill)';"), isEmpty);
      expect(scan("final s = 'we do update the row';"), isEmpty);
      expect(scan("final m = {'a': 1}; final f = (x) => x;"), isEmpty);
      expect(scan("final t = 'a -> b';"), isEmpty);
      expect(scan("'SELECT a FROM t WHERE b = 1 ORDER BY a'"), isEmpty);
      expect(scan("'INSERT OR REPLACE INTO t (a) VALUES (?)'"), isEmpty);
    });
  });

  test('lib/ issues no SQL newer than SQLite 3.18 (minSdk 26)', () {
    final violations = <String>[];
    var files = 0;
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.contains('lib/l10n/')) continue; // generated, no SQL
      files++;
      violations.addAll(sqliteFloorViolations(f.path, f.readAsStringSync()));
    }
    expect(files, greaterThan(100), reason: 'guard: it scanned the tree');
    expect(
      violations,
      isEmpty,
      reason: 'minSdk 26 ships SQLite 3.18. These need a newer SQLite and would '
          'fail on Android 8-10:\n${violations.join('\n')}',
    );
  });
}
