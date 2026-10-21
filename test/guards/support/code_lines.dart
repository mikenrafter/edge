// code_lines.dart — the file-size guard's line counter (owner rule A).
//
// Contract. Count the physical lines of [source] that carry code:
//   * blank (whitespace-only) lines do not count;
//   * a line holding only comment text does not count: `//`, `///`, and every
//     line of a `/* ... */` block (Dart block comments NEST);
//   * a line with code AND a comment (`x(); // note`, `/* a */ x();`) counts;
//   * a multi-line string literal is lexed as a string: `//`, `/*` and quotes
//     inside it are text, never comments. Its first and last physical lines
//     (they hold the delimiters) always count; the lines strictly BETWEEN them
//     count only when the string's text contains an SQL keyword as a whole
//     word, case-insensitively: SELECT INSERT UPDATE DELETE CREATE ALTER DROP
//     WITH PRAGMA. Prose that merely uses the word "with" is therefore SQL.
//   * handled lexically: '...', "...", ''' ''', """ """, raw r'..' / r'''..'''
//     (a backslash escapes nothing), backslash escapes, and `${...}`
//     interpolation whose expression holds further quotes or strings.

final RegExp _sqlKeyword = RegExp(
  r'\b(select|insert|update|delete|create|alter|drop|with|pragma)\b',
  caseSensitive: false,
);

bool _isIdentChar(int c) =>
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) ||
    c == 95 || c == 36;

/// True when a Dart string literal (optionally raw) starts at [i].
bool isDartStringStart(String s, int i) {
  final c = s[i];
  if (c == "'" || c == '"') return true;
  if (c == 'r' && i + 1 < s.length && (s[i + 1] == "'" || s[i + 1] == '"')) {
    return i == 0 || !_isIdentChar(s.codeUnitAt(i - 1));
  }
  return false;
}

/// Index just past the string literal that starts at [i] (see
/// [isDartStringStart]). An unterminated single-line string ends at its line.
int skipDartString(String s, int i) {
  var raw = false;
  if (s[i] == 'r') {
    raw = true;
    i++;
  }
  final q = s[i];
  final triple = s.startsWith(q * 3, i);
  i += triple ? 3 : 1;
  while (i < s.length) {
    final c = s[i];
    if (c == r'\' && !raw) {
      i += 2;
    } else if (c == q) {
      if (!triple) return i + 1;
      if (s.startsWith(q * 3, i)) return i + 3;
      i++;
    } else if (!triple && c == '\n') {
      return i;
    } else if (!raw && c == r'$' && i + 1 < s.length && s[i + 1] == '{') {
      i = _skipInterpolation(s, i + 2);
    } else {
      i++;
    }
  }
  return s.length;
}

int _skipInterpolation(String s, int i) {
  var depth = 1;
  while (i < s.length) {
    if (isDartStringStart(s, i)) {
      i = skipDartString(s, i);
      continue;
    }
    final c = s[i];
    if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      return i + 1;
    }
    i++;
  }
  return s.length;
}

/// Index just past the (nested) block comment that starts at [i].
int skipBlockComment(String s, int i) {
  var depth = 1;
  i += 2;
  while (i < s.length && depth > 0) {
    if (s.startsWith('/*', i)) {
      depth++;
      i += 2;
    } else if (s.startsWith('*/', i)) {
      depth--;
      i += 2;
    } else {
      i++;
    }
  }
  return i;
}

int countCodeLines(String source) {
  final s = source;
  final n = s.length;
  var count = 0;
  var code = false;
  var i = 0;
  void endLine() {
    if (code) count++;
    code = false;
  }

  while (i < n) {
    final c = s[i];
    if (c == '\n') {
      endLine();
      i++;
    } else if (c == ' ' || c == '\t' || c == '\r') {
      i++;
    } else if (s.startsWith('//', i)) {
      while (i < n && s[i] != '\n') {
        i++;
      }
    } else if (s.startsWith('/*', i)) {
      final end = skipBlockComment(s, i);
      for (; i < end; i++) {
        if (s[i] == '\n') endLine();
      }
    } else if (isDartStringStart(s, i)) {
      final end = skipDartString(s, i);
      final text = s.substring(i, end);
      code = true;
      if (text.contains('\n')) {
        final lines = text.split('\n');
        final sql = _sqlKeyword.hasMatch(text);
        endLine();
        if (sql) {
          for (var k = 1; k < lines.length - 1; k++) {
            if (lines[k].trim().isNotEmpty) count++;
          }
        }
        code = true; // the closing line holds the delimiter
      }
      i = end;
    } else {
      code = true;
      i++;
    }
  }
  endLine();
  return count;
}
