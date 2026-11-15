// Source guard for the screen-reader rules that a widget test cannot reach on
// every screen (the companion widget tests are ui2_a11y_grammar_test.dart and
// ui2_a11y_screens_test.dart). Same style as ui2_spinner_status_guard_test.dart.
//
//  1. A spoken label is never an English literal: semanticLabel, semanticsLabel
//     and tooltip go through AppLocalizations (a German TalkBack voice read
//     "Dismiss" in English). Composites of localized parts ('$title. $sub') are
//     fine. Developer screens are exempt.
//  2. Text is never drawn in a raw accent (`F.body.copyWith(color: C.red)`):
//     C.red on white is 3.76:1, under the 4.5:1 body text needs. Use p.on(C.x).
//  3. No `Semantics(selected/expanded/checked/toggled: ..., child: Pressable(`:
//     a Pressable is its own node, so a flag on a wrapper lands on the wrong
//     node. Pass `selected:` / `expanded:` to the Pressable.
//
// CLAIM(A11Y-GUARD) [this file].
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';

/// Developer and design screens: English by design, never shipped to a
/// non-developer path.
const _devScreens = {
  'lib/ui2/profile/device_lab.dart',
  'lib/ui2/profile/motion_lab.dart',
  'lib/ui2/profile/gallery.dart',
  'lib/ui2/profile/pattern_probe_page.dart',
};

String _rel(File f) => f.path.replaceAll('\\', '/');

final _spokenArg = RegExp(r"\b(semanticLabel|semanticsLabel|tooltip)\s*:\s*'");

/// The text OUTSIDE interpolations of the single-quoted literal that opens at
/// [open] (the quote), or null when it is not one. `${...}` is skipped by
/// brace matching, so quotes nested inside an interpolation do not end it.
String? literalText(String src, int open) {
  if (open >= src.length || src[open] != "'") return null;
  final out = StringBuffer();
  var i = open + 1;
  while (i < src.length) {
    final ch = src[i];
    if (ch == r'\') {
      i += 2;
      continue;
    }
    if (ch == "'") return out.toString();
    if (ch == r'$' && i + 1 < src.length && src[i + 1] == '{') {
      var depth = 0;
      while (i < src.length) {
        if (src[i] == '{') depth++;
        if (src[i] == '}' && --depth == 0) break;
        i++;
      }
      i++;
      continue;
    }
    if (ch == r'$') {
      i++;
      while (i < src.length && RegExp(r'[A-Za-z0-9_]').hasMatch(src[i])) {
        i++;
      }
      continue;
    }
    out.write(ch);
    i++;
  }
  return null;
}

/// True when [bare] (literal text outside interpolations) holds English words.
bool englishLiteral(String bare) => RegExp(r'[A-Za-z]{2,}').hasMatch(bare);

final _rawAccentText = RegExp(
    r'\bF\.[a-z0-9]+\.copyWith\([^)]*\bcolor:\s*C\.(red|orange|yellow|green|blue|teal|purple|pink|amber|dom[A-Za-z]+)\b');

final _flagWrapper = RegExp(
    r'\bSemantics\(\s*(?:key:[^,]*,\s*)?(?:(?:selected|expanded|checked|toggled|button|container)\s*:[^,]*,\s*)+child:\s*Pressable\(');

/// Rules 2 and 3 read `codeOnly` (comments and string contents blanked), so
/// they never match inside a string.
List<String> _offenders(RegExp re) {
  final out = <String>[];
  for (final f in dartFilesIn('lib/ui2')) {
    final path = _rel(f);
    if (_devScreens.contains(path)) continue;
    final code = codeOnly(f.readAsStringSync());
    for (final m in re.allMatches(code)) {
      out.add('$path:${lineOf(code, m.start)}: ${m.group(0)!.split('\n').first}');
    }
  }
  return out;
}

String _stripComments(String src) =>
    // [ \t], not \s: \s would eat the newlines before a comment and shift
    // every line number after it.
    src.replaceAll(RegExp(r'^[ \t]*//.*$', multiLine: true), '');

void main() {
  test('1. no English literal is spoken', () {
    final hits = <String>[];
    for (final f in dartFilesIn('lib/ui2')) {
      final path = _rel(f);
      if (_devScreens.contains(path)) continue;
      final src = _stripComments(f.readAsStringSync());
      for (final m in _spokenArg.allMatches(src)) {
        final text = literalText(src, m.end - 1);
        if (text != null && englishLiteral(text)) {
          hits.add('$path:${lineOf(src, m.start)}: ${m.group(0)}$text\'');
        }
      }
    }
    expect(hits, isEmpty,
        reason: 'Spoken labels must go through AppLocalizations:\n${hits.join('\n')}');
  });

  test('2. no text in a raw accent colour', () {
    final hits = _offenders(_rawAccentText);
    expect(hits, isEmpty, reason: 'Use p.on(C.x) for text:\n${hits.join('\n')}');
  });

  test('3. no state flag on a wrapper around a Pressable', () {
    final hits = _offenders(_flagWrapper);
    expect(hits, isEmpty,
        reason: 'Pass selected:/expanded: to the Pressable itself:\n${hits.join('\n')}');
  });

  test('the rules catch what they are for', () {
    // Rule 1.
    String? lit(String code) => literalText(code, code.indexOf("'"));
    expect(englishLiteral(lit("'Dismiss'")!), isTrue);
    expect(englishLiteral(lit(r"'Open $title'")!), isTrue);
    expect(englishLiteral(lit(r"'$title. $sub'")!), isFalse);
    expect(englishLiteral(lit(r"'${a.b}, ${c}'")!), isFalse);
    expect(englishLiteral(lit(r"'${x ?? 'nested'}, ${y}'")!), isFalse,
        reason: 'a quote inside an interpolation does not end the literal');
    expect(englishLiteral(lit(r"'${x}, syncing'")!), isTrue);
    expect(_spokenArg.hasMatch("semanticLabel: 'Dismiss',"), isTrue);
    expect(_spokenArg.hasMatch("tooltip: 'Play',"), isTrue);
    // Rule 2.
    expect(_rawAccentText.hasMatch('F.cap.copyWith(color: C.red)'), isTrue);
    expect(_rawAccentText.hasMatch('F.cap.copyWith(color: p.on(C.red))'), isFalse);
    // Rule 3.
    expect(_flagWrapper.hasMatch('Semantics(selected: on, child: Pressable('), isTrue);
    expect(_flagWrapper.hasMatch(
        'Semantics(\n  key: k,\n  selected: on,\n  button: true,\n  child: Pressable('), isTrue);
    expect(_flagWrapper.hasMatch('Semantics(label: x, child: Pressable('), isFalse);
    // The developer screens exist (no stale exemptions).
    for (final p in _devScreens) {
      expect(File(p).existsSync(), isTrue, reason: p);
    }
  });
}
