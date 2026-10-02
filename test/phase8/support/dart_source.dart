// Lexical helpers for the phase 8 source guards. Not a parser: just enough to
// make parentheses and brackets in Dart source mean code, not prose.

import 'dart:io';

bool _ident(String ch) => RegExp(r'[A-Za-z0-9_$]').hasMatch(ch);

/// [src] with every comment and every string-literal body blanked to spaces.
/// Quote characters and newlines are kept, so offsets and line numbers still
/// match the original file. Interpolations are blanked with the string.
String codeOnly(String src) {
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
          continue;
        }
        if (src.startsWith('*/', i)) {
          depth--;
          blank(2);
          if (depth == 0) break;
          continue;
        }
        blank(1);
      }
      continue;
    }
    final ch = src[i];
    if (ch == "'" || ch == '"') {
      final raw = i > 0 && src[i - 1] == 'r' && (i < 2 || !_ident(src[i - 2]));
      final quote = src.startsWith(ch * 3, i) ? ch * 3 : ch;
      out.write(quote);
      i += quote.length;
      while (i < n) {
        if (src.startsWith(quote, i)) {
          out.write(quote);
          i += quote.length;
          break;
        }
        if (!raw && src[i] == r'\') {
          blank(2);
          continue;
        }
        if (!raw && src.startsWith(r'${', i)) {
          var depth = 0;
          while (i < n) {
            if (src[i] == '{') depth++;
            if (src[i] == '}') {
              depth--;
              if (depth == 0) {
                blank(1);
                break;
              }
            }
            blank(1);
          }
          continue;
        }
        blank(1);
      }
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

const _open = {'(': ')', '[': ']', '{': '}'};

/// Index of the bracket that closes the one at [open] in [code] (code-only
/// text), or -1.
int closingOf(String code, int open) {
  final stack = <String>[];
  for (var i = open; i < code.length; i++) {
    final ch = code[i];
    if (_open.containsKey(ch)) {
      stack.add(_open[ch]!);
    } else if (ch == ')' || ch == ']' || ch == '}') {
      if (stack.isEmpty || stack.removeLast() != ch) return -1;
      if (stack.isEmpty) return i;
    }
  }
  return -1;
}

/// True when [site] lies inside the argument list of a call matched by
/// [opener] (a pattern ending in the call's `(`).
bool enclosedByCall(String code, int site, RegExp opener) {
  for (final m in opener.allMatches(code)) {
    final paren = m.end - 1;
    if (paren >= site) break;
    if (code[paren] != '(') continue;
    final close = closingOf(code, paren);
    if (close > site) return true;
  }
  return false;
}

int lineOf(String code, int offset) =>
    '\n'.allMatches(code.substring(0, offset)).length + 1;

List<File> dartFilesIn(String dir) => (Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList())
  ..sort((a, b) => a.path.compareTo(b.path));

/// The text of the method/function that starts at the first match of
/// [signature] in [src], from the signature through its closing brace.
String bodyOf(String src, String signature) {
  final code = codeOnly(src);
  final start = src.indexOf(signature);
  if (start < 0) return '';
  final brace = code.indexOf('{', start);
  final arrow = code.indexOf('=>', start);
  if (brace < 0) return '';
  if (arrow >= 0 && arrow < brace) {
    final semi = code.indexOf(';', arrow);
    return src.substring(start, semi < 0 ? src.length : semi + 1);
  }
  final close = closingOf(code, brace);
  return src.substring(start, close < 0 ? src.length : close + 1);
}
