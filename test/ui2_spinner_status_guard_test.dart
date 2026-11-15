// WHY: every app route must use debounced placeholders. Whole-tree scan is
// a dependency guard; the positive control proves a spinner is recognised.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'support/dart_source_lexical.dart';

void main() {
  final spinner = RegExp(r'\b(?:CircularProgressIndicator|CupertinoActivityIndicator)\s*\(');
  test('spinner detector recognises Material and Cupertino spinners', () {
    expect(spinner.allMatches('CircularProgressIndicator() CupertinoActivityIndicator()').length, 2);
  });
  test('no spinners anywhere in lib', () {
    final offenders = <String>[];
    for (final f in dartFilesIn('lib')) {
      final code = codeOnly(f.readAsStringSync());
      for (final m in spinner.allMatches(code)) {
        offenders.add('${f.path}:${lineOf(code, m.start)}');
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
