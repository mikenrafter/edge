// WHY: every app route must use debounced placeholders. Whole-tree scan is
// a dependency guard; the positive control proves a spinner is recognised.
import 'package:flutter_test/flutter_test.dart';
import 'support/dart_source_lexical.dart';

void main() {
  final spinner = RegExp(r'\b(?:CircularProgressIndicator|RefreshProgressIndicator|CupertinoActivityIndicator|CupertinoSliverRefreshControl)\b|\bRefreshIndicator(?:\.adaptive)?\s*\(');
  test('spinner detector recognises Material and Cupertino spinners', () {
    for (final sample in ['CircularProgressIndicator()', 'CupertinoActivityIndicator()', 'CircularProgressIndicator.adaptive()', 'RefreshProgressIndicator()', 'CupertinoSliverRefreshControl()', 'RefreshIndicator.adaptive()', 'CircularProgressIndicator.new']) {
      expect(spinner.hasMatch(sample), isTrue, reason: sample);
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
        if (!RegExp(r'\bvalue\s*:').hasMatch(args) || RegExp(r'\bvalue\s*:\s*null\b').hasMatch(args)) {
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
