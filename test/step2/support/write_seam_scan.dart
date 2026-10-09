// Source scan for writers of `day_result` and `baselines` (design 02, step 2,
// section 4.2 guard tests (a) and (b)).
//
// Why a scan and not a runtime test: the revision identity is kept by triggers,
// so every writer is covered no matter who calls it. What the scan protects is
// the OTHER half of the seam: the rule (frozen rows, compare-and-set,
// value-identical re-encode) lives in a handful of `LocalDb` methods, and a
// writer anywhere else would bypass it. The demo delete in
// `lib/demo/demo_data_generator.dart` was exactly that.
//
// Not a parser. Comments are blanked, adjacent string literals are joined, and
// the member that encloses a hit is found by brace depth over the code-only
// text (`codeOnly` from dart_source_lexical.dart blanks strings, so braces
// inside SQL do not count). Offsets are preserved throughout.

import '../../support/dart_source_lexical.dart';

/// One write to `day_result` or `baselines` found in a source file.
class WriteSite {
  const WriteSite({
    required this.member,
    required this.table,
    required this.verb,
    required this.line,
    required this.text,
  });

  /// `Class.member` of the enclosing declaration, `<top>` outside any.
  final String member;
  final String table; // day_result | baselines
  final String verb; // insert | update | delete
  final int line;

  /// The matched text, or the whole call for an API write.
  final String text;

  @override
  String toString() => '$member $verb $table (line $line)';
}

/// [src] with every comment replaced by spaces and string literals left alone.
/// Length and newlines are preserved. A small lexer: handles `'`, `"`, raw and
/// triple-quoted strings, ignores `${...}` nesting (SQL strings here have none).
String blankComments(String src) {
  final out = StringBuffer();
  final n = src.length;
  var i = 0;
  void blank(int count) {
    for (var k = 0; k < count && i < n; k++, i++) {
      out.write(src[i] == '\n' ? '\n' : ' ');
    }
  }

  while (i < n) {
    if (src.startsWith('//', i)) {
      while (i < n && src[i] != '\n') {
        blank(1);
      }
      continue;
    }
    if (src.startsWith('/*', i)) {
      var depth = 0;
      while (i < n) {
        if (src.startsWith('/*', i)) {
          depth++;
          blank(2);
        } else if (src.startsWith('*/', i)) {
          depth--;
          blank(2);
          if (depth == 0) break;
        } else {
          blank(1);
        }
      }
      continue;
    }
    final ch = src[i];
    if (ch == "'" || ch == '"') {
      final raw = i > 0 && src[i - 1] == 'r';
      final quote = src.startsWith(ch * 3, i) ? ch * 3 : ch;
      out.write(quote);
      i += quote.length;
      while (i < n && !src.startsWith(quote, i)) {
        if (!raw && src[i] == r'\' && i + 1 < n) {
          out.write(src.substring(i, i + 2));
          i += 2;
        } else {
          out.write(src[i]);
          i++;
        }
      }
      if (i < n) {
        out.write(quote);
        i += quote.length;
      }
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// Join adjacent literals (`'a '\n 'b'` becomes `'a b'` plus padding) so a
/// statement split across lines is one string. Same length as the input.
String _joinAdjacentLiterals(String s) => s.replaceAllMapped(
  RegExp(r"""(['"])(\s+)(['"])"""),
  (m) => m[1] == m[3] ? ' ${m[2]} ' : m[0]!,
);

const _tables = r'(day_result|baselines)';

final _sqlWrite = RegExp(
  r'\b(INSERT\s+(?:OR\s+\w+\s+)?INTO|REPLACE\s+INTO|UPDATE|DELETE\s+FROM)'
  '\\s+$_tables\\b',
  caseSensitive: false,
);

/// `insert('t'`, `update('t'`, `delete('t'`, and the `deleteByIn(txn, 't'` helper.
final _apiWrite = RegExp(
  '\\b(insert|update|delete|deleteByIn)\\s*\\(\\s*(?:\\w+\\s*,\\s*)?'
  '[\'"]$_tables[\'"]',
);

String _verbOf(String word) {
  final w = word.toLowerCase();
  if (w.startsWith('insert') || w.startsWith('replace')) return 'insert';
  if (w.startsWith('update')) return 'update';
  return 'delete';
}

/// Every write to `day_result` / `baselines` in [src].
List<WriteSite> scanWriters(String src) {
  final text = _joinAdjacentLiterals(blankComments(src));
  if (!text.contains('day_result') && !text.contains('baselines')) {
    return const [];
  }
  final code = codeOnly(src);
  final hits = <({int at, String verb, String table, String text})>[];
  for (final m in _sqlWrite.allMatches(text)) {
    // To the end of the string literal, so a raw UPDATE carries its SET list.
    final endQuote = text.indexOf(RegExp('[\'"]'), m.end);
    hits.add((
      at: m.start,
      verb: _verbOf(m[1]!),
      table: m[2]!.toLowerCase(),
      text: text.substring(m.start, endQuote < 0 ? m.end : endQuote),
    ));
  }
  for (final m in _apiWrite.allMatches(text)) {
    final paren = text.indexOf('(', m.start);
    final close = closingOf(code, paren);
    hits.add((
      at: m.start,
      verb: _verbOf(m[1]!),
      table: m[2]!,
      text: close < 0 ? m[0]! : text.substring(m.start, close + 1),
    ));
  }
  hits.sort((a, b) => a.at.compareTo(b.at));
  return [
    for (final h in hits)
      WriteSite(
        member: _memberAt(code, h.at),
        table: h.table,
        verb: h.verb,
        line: lineOf(code, h.at),
        text: h.text,
      ),
  ];
}

/// `Class.member` enclosing [offset]: walk the code-only text keeping a stack of
/// brace frames, each with the header text that preceded its `{`. Braces inside
/// parentheses at declaration level are parameter lists (`({required int a})`)
/// and default values, not bodies, so they open no frame.
String _memberAt(String code, int offset) {
  final headers = <String>[];
  var headerStart = 0;
  var parens = 0;
  for (var i = 0; i < offset && i < code.length; i++) {
    final ch = code[i];
    if (ch == '(') {
      parens++;
    } else if (ch == ')') {
      if (parens > 0) parens--;
    } else if (ch == '{' || ch == '}') {
      if (parens > 0 && headers.length <= 1) continue;
      if (ch == '{') {
        headers.add(code.substring(headerStart, i));
      } else if (headers.isNotEmpty) {
        headers.removeLast();
      }
      headerStart = i + 1;
    } else if (ch == ';' && headers.length <= 1 && parens == 0) {
      headerStart = i + 1;
    }
  }
  final pending = code.substring(headerStart, offset);
  String name(String header) {
    final h = header.replaceAll(RegExp(r'@\w+(\.\w+)?(\([^)]*\))?'), ' ').trim();
    const notNames = {'static', 'if', 'for', 'while', 'switch', 'catch'};
    for (final m in RegExp(r'([A-Za-z_]\w*)\s*\(').allMatches(h)) {
      if (!notNames.contains(m[1])) return m[1]!;
    }
    const filler = {'async', 'sync', 'get', 'set', 'static', 'const', 'final'};
    for (final w in RegExp(r'[A-Za-z_]\w*').allMatches(h).toList().reversed) {
      if (!filler.contains(w[0])) return w[0]!;
    }
    return '<unknown>';
  }

  if (headers.isEmpty) return '<top>';
  final cls = RegExp(r'\b(?:class|extension|mixin)\s+(\w+)').firstMatch(
    headers.first,
  );
  if (cls == null) return name(headers.first);
  if (headers.length >= 2) return '${cls[1]}.${name(headers[1])}';
  // Directly in the class body: a field initialiser or an arrow-bodied member.
  return '${cls[1]}.${name(pending)}';
}

/// The call text of an `update` whose map argument sets exactly which columns,
/// for guard (b). Null when [site] is not an API `update(` call.
Set<String>? updatedColumns(WriteSite site) {
  if (site.verb != 'update') return null;
  final t = site.text;
  if (!RegExp(r'^update\s*\(').hasMatch(t)) {
    // raw SQL: `UPDATE day_result SET a = ?, b = ?`
    final set = RegExp(
      r'SET\s+(.*?)(?:\bWHERE\b|$)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(t);
    if (set == null) return {'<unparsed raw update>'};
    return {
      for (final m in RegExp(r'(\w+)\s*=').allMatches(set[1]!)) m[1]!,
    };
  }
  final brace = t.indexOf('{');
  if (brace < 0) return {'<non-literal values>'};
  final close = closingOf(t, brace);
  final map = close < 0 ? t.substring(brace) : t.substring(brace, close + 1);
  return {for (final m in RegExp('[\'"](\\w+)[\'"]\\s*:').allMatches(map)) m[1]!};
}
