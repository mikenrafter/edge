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

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

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

/// A table identifier as SQL lets it be spelled: bare, or quoted with double
/// quotes, backticks or square brackets, optionally behind a `main.` schema.
/// The lookahead keeps `day_result_other` and `"day_resultx"` out.
const _quote = '["`\\[]';
const _quoteEnd = '["`\\]]';
const _tables = '(?:$_quote?main$_quoteEnd?\\s*\\.\\s*)?$_quote?(day_result|baselines)'
    '$_quoteEnd?(?![A-Za-z0-9_])';

/// INSERT [OR x] INTO, REPLACE INTO, UPDATE [OR x], DELETE FROM. `UPDATE OF col
/// ON t` (a trigger header) has no table right after UPDATE, so it never matches.
final _sqlWrite = RegExp(
  r'\b(INSERT\s+(?:OR\s+\w+\s+)?INTO|REPLACE\s+INTO|'
  r'UPDATE\s+(?:OR\s+(?:REPLACE|ROLLBACK|ABORT|FAIL|IGNORE)\s+)?|DELETE\s+FROM)'
  '\\s*$_tables',
  caseSensitive: false,
);

/// Candidate API writes: insert / update / delete / deleteByIn calls, any
/// receiver. Which table they name is decided by [_literalTable].
class _LiteralApiWrites extends RecursiveAstVisitor<void> {
  _LiteralApiWrites(this.out);
  final List<MethodInvocation> out;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (const {'insert', 'update', 'delete', 'deleteByIn'}
        .contains(node.methodName.name)) {
      out.add(node);
    }
    super.visitMethodInvocation(node);
  }
}

/// The decoded text of [e] when it is a string with no interpolation, looking
/// through parentheses and adjacent literals; null otherwise.
String? _stringValue(Expression e) => switch (e) {
  ParenthesizedExpression(:final expression) => _stringValue(expression),
  StringLiteral() => e.stringValue,
  _ => null,
};

/// `day_result` or `baselines` when [call] writes one of them by a literal
/// table argument. The table is the first positional argument, or the second
/// for the `deleteByIn(txn, table, ...)` helper.
String? _literalTable(MethodInvocation call) {
  final positional = [
    for (final a in call.argumentList.arguments)
      if (a is! NamedExpression) a,
  ];
  final at = call.methodName.name == 'deleteByIn' ? 1 : 0;
  if (positional.length <= at) return null;
  final v = _stringValue(positional[at]);
  return v == 'day_result' || v == 'baselines' ? v : null;
}

String _verbOf(String word) {
  final w = word.trim().toLowerCase();
  if (w.startsWith('insert') || w.startsWith('replace')) return 'insert';
  if (w.startsWith('update')) return 'update';
  return 'delete';
}

/// Every write to `day_result` / `baselines` in [src].
List<WriteSite> scanWriters(String src) {
  final text = _joinAdjacentLiterals(blankComments(src));
  // Cheap pre-filter: a write needs one of these words somewhere.
  if (!RegExp('insert|update|delete|replace', caseSensitive: false)
      .hasMatch(text)) {
    return const [];
  }
  final code = codeOnly(src);
  final hits = <({int at, String verb, String table, String text})>[];
  final literalEnds = _literalEnds(text);
  for (final m in _sqlWrite.allMatches(text)) {
    // To the end of the Dart string literal the SQL sits in, so a raw UPDATE
    // carries its SET list whatever quotes the identifiers use.
    final end = literalEnds.firstWhere((e) => e > m.end, orElse: () => m.end);
    hits.add((
      at: m.start,
      verb: _verbOf(m[1]!),
      table: m[2]!.toLowerCase(),
      text: text.substring(m.start, end),
    ));
  }
  // API writes are decided on the parsed AST, from the DECODED value of the
  // table argument: parentheses, raw strings, triple quotes and adjacent
  // literals all spell the same table.
  final unit = parseString(content: src, throwIfDiagnostics: false).unit;
  final apiCalls = <MethodInvocation>[];
  unit.accept(_LiteralApiWrites(apiCalls));
  final apiMembers = <int, String>{};
  for (final call in apiCalls) {
    final table = _literalTable(call);
    if (table == null) continue;
    final name = call.methodName.name;
    hits.add((
      at: call.methodName.offset,
      verb: _verbOf(name),
      table: table,
      text: src.substring(call.methodName.offset, call.end),
    ));
    apiMembers[call.methodName.offset] = _enclosingMember(call);
  }
  hits.sort((a, b) => a.at.compareTo(b.at));
  return [
    for (final h in hits)
      WriteSite(
        member: apiMembers[h.at] ?? _memberAt(code, h.at),
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
    // A typed literal's `<String>` is not the member's name.
    var bare = h;
    for (var prev = ''; prev != bare;) {
      prev = bare;
      bare = bare.replaceAll(RegExp(r'<[^<>]*>'), '');
    }
    for (final w in RegExp(r'[A-Za-z_]\w*').allMatches(bare).toList().reversed) {
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
      for (final m in RegExp(r'["`\[]?(\w+)["`\]]?\s*=').allMatches(set[1]!))
        m[1]!,
    };
  }
  final brace = t.indexOf('{');
  if (brace < 0) return {'<non-literal values>'};
  final close = closingOf(t, brace);
  final map = close < 0 ? t.substring(brace) : t.substring(brace, close + 1);
  return {for (final m in RegExp('[\'"](\\w+)[\'"]\\s*:').allMatches(map)) m[1]!};
}

/// `Class.member` enclosing [offset] of [src] (offsets as in [blankComments]).
String memberAtOffset(String src, int offset) => _memberAt(codeOnly(src), offset);

/// End offsets (the closing quote) of every Dart string literal in [text],
/// ascending. [text] has its comments blanked already.
List<int> _literalEnds(String text) {
  final ends = <int>[];
  final n = text.length;
  var i = 0;
  while (i < n) {
    final ch = text[i];
    if (ch == "'" || ch == '"') {
      final raw = i > 0 && text[i - 1] == 'r';
      final quote = text.startsWith(ch * 3, i) ? ch * 3 : ch;
      i += quote.length;
      while (i < n && !text.startsWith(quote, i)) {
        i += (!raw && text[i] == '\\') ? 2 : 1;
      }
      ends.add(i);
      i += quote.length;
    } else {
      i++;
    }
  }
  return ends;
}

/// A write to a table the scan cannot name: the table is a variable, or is
/// interpolated into the SQL.
class DynamicWriteSite {
  const DynamicWriteSite({required this.member, required this.line});
  final String member;
  final int line;
  @override
  String toString() => '$member (line $line)';
}

/// Statements that write, interpolating their table: any conflict clause, any
/// identifier quoting (also on the `main.` schema prefix), `$t` or `${t}`.
final _dynamicSql = RegExp(
  r'\b(?:INSERT\s+(?:OR\s+\w+\s+)?INTO|REPLACE\s+INTO|'
  r'UPDATE\s+(?:OR\s+(?:REPLACE|ROLLBACK|ABORT|FAIL|IGNORE)\s+)?|DELETE\s+FROM)\s*'
  r'(?:["`\[]?main["`\]]?\s*\.\s*)?["`\[]?\s*\$',
  caseSensitive: false,
);

/// Whether [text] mentions anything a database write needs. A receiver is only
/// meaningful in a file that has a database in sight.
final _dbInSight = RegExp(
  r'package:sqflite|\bLocalDb\b|\bDatabase\b|\bTransaction\b|\bBatch\b|'
  r'\bDatabaseExecutor\b',
);

const _writeMethods = {
  'insert',
  'update',
  'delete',
  'rawInsert',
  'rawUpdate',
  'rawDelete',
  'execute',
};

class _DynamicCalls extends RecursiveAstVisitor<void> {
  _DynamicCalls(this.unit, this.out);
  final CompilationUnit unit;
  final List<DynamicWriteSite> out;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_writeMethods.contains(node.methodName.name)) {
      final positional = [
        for (final a in node.argumentList.arguments)
          if (a is! NamedExpression) a,
      ];
      // sqflite's table (or statement) is the first POSITIONAL argument. Only a
      // plain string literal, with no interpolation, names it statically;
      // anything else (a variable, an interpolated string, a call, a number) is
      // a call site somebody has to vouch for.
      if (positional.isNotEmpty && !_isPlainString(positional.first)) {
        out.add(DynamicWriteSite(
          member: _enclosingMember(node),
          line: unit.lineInfo.getLocation(node.offset).lineNumber,
        ));
      }
    }
    super.visitMethodInvocation(node);
  }
}

bool _isPlainString(Expression e) => switch (e) {
  SimpleStringLiteral() => true,
  AdjacentStrings(:final strings) => strings.every(_isPlainString),
  ParenthesizedExpression(:final expression) => _isPlainString(expression),
  _ => false,
};

String _enclosingMember(AstNode node) {
  AstNode? member;
  String? owner;
  for (AstNode? n = node; n != null; n = n.parent) {
    if (n is MethodDeclaration ||
        n is FieldDeclaration ||
        n is ConstructorDeclaration ||
        (n is FunctionDeclaration && n.parent is CompilationUnit) ||
        n is TopLevelVariableDeclaration) {
      member = n;
    }
    owner ??= switch (n) {
      ClassDeclaration() => n.namePart.typeName.lexeme,
      MixinDeclaration() => n.name.lexeme,
      EnumDeclaration() => n.namePart.typeName.lexeme,
      ExtensionDeclaration() => n.name?.lexeme ?? 'extension',
      _ => null,
    };
  }
  final name = switch (member) {
    MethodDeclaration(:final name) => name.lexeme,
    FunctionDeclaration(:final name) => name.lexeme,
    ConstructorDeclaration(:final name, :final typeName) =>
      name?.lexeme ?? typeName?.name ?? '<ctor>',
    FieldDeclaration(:final fields) => fields.variables.first.name.lexeme,
    _ => '<top>',
  };
  return owner == null ? name : '$owner.$name';
}

/// Every call site of a write method (insert, update, delete, rawInsert,
/// rawUpdate, rawDelete, execute) on ANY receiver whose first positional
/// argument is not a plain string literal, plus every string that interpolates
/// a table into a write statement. Found on the parsed AST, so spelling,
/// receiver names and argument nesting do not matter. Each must be pinned in the
/// guard with a reason. Only files with a database in sight are scanned.
List<DynamicWriteSite> scanDynamicWriters(String src) {
  final text = blankComments(src);
  if (!_dbInSight.hasMatch(text)) return const [];
  final out = <DynamicWriteSite>[];
  final unit = parseString(content: src, throwIfDiagnostics: false).unit;
  unit.accept(_DynamicCalls(unit, out));
  // A statement built with its table interpolated, wherever it ends up.
  for (final m in _dynamicSql.allMatches(text)) {
    out.add(DynamicWriteSite(
      member: memberAtOffset(src, m.start),
      line: lineOf(text, m.start),
    ));
  }
  // A call and the statement inside it are one site.
  final seen = <int>{};
  return [
    for (final w in out)
      if (seen.add(w.line)) w,
  ];
}

/// A declaration of a list or set of table names that names `day_result` or
/// `baselines`.
class TableListSite {
  const TableListSite({required this.member, required this.line});
  final String member;
  final int line;
  @override
  String toString() => '$member (line $line)';
}

/// A list or set literal, typed or not, const or not: `[`/`{` after an optional
/// `const` and an optional `<String>`.
final _listLiteral = RegExp(
  r'(?:\bconst\s*)?(?:<\s*String\s*>\s*)?[\[{]',
);

/// Assignments, arguments and loop sources that are a literal list or set of
/// plain strings, such as `static const x = [...]`, `<String>{...}`,
/// `run(const ['a', 'b'])` or `for (t in const <String>[...])`, whose items
/// include `'day_result'` or `'baselines'`. An index expression (`b['x']`) and
/// a map are not.
List<TableListSite> scanTableLists(String src) {
  final text = blankComments(src);
  final code = codeOnly(src);
  final out = <TableListSite>[];
  for (final m in _listLiteral.allMatches(text)) {
    // `[` right after an identifier, `)` or `]` is an index, not a literal.
    var b = m.start - 1;
    while (b >= 0 && ' \t\n'.contains(text[b])) {
      b--;
    }
    final isIndex = b >= 0 &&
        m.start > 0 &&
        RegExp(r'[\w)\]]').hasMatch(text[b]) &&
        !RegExp(r'\b(?:in|return|const|await|yield|case)$')
            .hasMatch(text.substring(0, b + 1)) &&
        !m[0]!.startsWith('const') &&
        !m[0]!.startsWith('<');
    if (isIndex) continue;
    final open = m.end - 1;
    final close = closingOf(code, open);
    if (close < 0) continue;
    final body = text.substring(open, close);
    // Only literals made of plain strings: a map of values or a call is not a
    // table list.
    final stripped = body
        .replaceAll(RegExp(r"""['"]\w+['"]"""), '')
        .replaceAll(RegExp(r'[\s,\[\]{}]'), '');
    if (stripped.isEmpty && RegExp('[\'"](day_result|baselines)[\'"]').hasMatch(body)) {
      out.add(TableListSite(
        member: memberAtOffset(src, open),
        line: lineOf(text, m.start),
      ));
    }
  }
  return out;
}
