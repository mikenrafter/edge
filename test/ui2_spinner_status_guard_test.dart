// WHY: every app route must use debounced placeholders. Whole-tree scan is
// a dependency guard; the positive control proves a spinner is recognised.
import 'package:flutter_test/flutter_test.dart';
import 'support/dart_source_lexical.dart';

// Terminal empty allowlist. Kept literal so the registered shrink history is
// countable by ratchet_lists_test. It must never grant a spinner exemption.
const _allowed = <String>{};

// Only a top-level value argument makes a linear indicator determinate.
// A nested constructor's value must not accidentally satisfy this guard.
bool _indeterminateLinear(String args) {
  var depth = 0, start = 0;
  String? value;
  for (var i = 0; i <= args.length; i++) {
    if (i == args.length || depth == 0 && args[i] == ',') {
      final match = RegExp(r'^\s*value\s*:\s*([\s\S]*)$').firstMatch(args.substring(start, i));
      if (match != null) value = match.group(1)!.trim();
      start = i + 1;
    } else if ('([{'.contains(args[i])) {
      depth++;
    } else if (')]}'.contains(args[i])) {
      depth--;
    }
  }
  if (value == null) return true;
  var expression = value;
  while (expression.startsWith('(') && closingOf(expression, 0) == expression.length - 1) {
    expression = expression.substring(1, expression.length - 1).trim();
  }
  return expression == 'null';
}

void main() {
  test('the terminal spinner allowlist is empty', () => expect(_allowed, isEmpty));
  final spinner = RegExp(r'\b(?:CircularProgressIndicator|RefreshProgressIndicator|CupertinoActivityIndicator|CupertinoSliverRefreshControl)\b|\bRefreshIndicator(?:\.adaptive)?\s*\(|\bRefreshIndicator\.(?:new|adaptive)\b|\bLinearProgressIndicator\.new\b');
  test('spinner detector recognises Material and Cupertino spinners', () {
    for (final sample in ['CircularProgressIndicator()', 'CupertinoActivityIndicator()', 'CircularProgressIndicator.adaptive()', 'RefreshProgressIndicator()', 'CupertinoSliverRefreshControl()', 'RefreshIndicator.adaptive()', 'CircularProgressIndicator.new', 'RefreshIndicator.new', 'LinearProgressIndicator.new']) {
      expect(spinner.hasMatch(sample), isTrue, reason: sample);
    }
    for (final args in ['', 'backgroundColor: Color(value: 1)', 'value: null', 'value: ((null))']) {
      expect(_indeterminateLinear(args), isTrue, reason: args);
    }
    for (final args in ['value: .5', 'value: progress.fraction, color: pigment']) {
      expect(_indeterminateLinear(args), isFalse, reason: args);
    }
  });
  test('no spinners anywhere in lib', () {
    final offenders = <String>[];
    for (final f in dartFilesIn('lib')) {
      final code = codeOnly(f.readAsStringSync());
      for (final m in spinner.allMatches(code)) {
        offenders.add('${f.path}:${lineOf(code, m.start)}');
      }
      final linear = RegExp(r'\bLinearProgressIndicator\s*\(');
      for (final m in linear.allMatches(code)) {
        final end = closingOf(code, m.end - 1);
        final args = code.substring(m.end, end);
        if (_indeterminateLinear(args)) {
          offenders.add('${f.path}:${lineOf(code, m.start)}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'Use PendingContent or PendingMark:\n${offenders.join('\n')}');
  });
  test('pull to refresh does not introduce a spinner', () {
    final offenders = <String>[];
    final refresh = RegExp(r'\bRefreshIndicator\s*\(');
    for (final f in dartFilesIn('lib')) {
      final code = codeOnly(f.readAsStringSync());
      for (final m in refresh.allMatches(code)) {
        offenders.add('${f.path}:${lineOf(code, m.start)}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
