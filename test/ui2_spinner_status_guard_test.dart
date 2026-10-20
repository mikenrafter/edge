// Every spinner says what is happening. `InlineLoading` (lib/ui2/
// inline_loading.dart) is the one loading primitive: a required status line,
// an optional detail line, and a reserved height. A bare
// `CircularProgressIndicator(` anywhere else in lib/ui2 is a spinner with no
// status, unless it is a busy mark inside a control whose own text already
// states the action; those are listed below, one reason each.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';

const _primitive = 'lib/ui2/inline_loading.dart';

/// In-control busy spinners. Each one sits inside a control or row whose own
/// visible text says what is happening. A page or section loading spinner
/// never belongs here: it becomes `InlineLoading(status: ...)`.
const _allowed = <String, String>{
  'lib/ui2/grammar.dart':
      'BigButton busy state: the spinner sits beside the button label',
  'lib/ui2/sync_control.dart':
      'leads the sync status sentence ("Calculating · day 3 of 12"); '
          'syncBusyMark is the profile button beside that sentence',
  'lib/ui2/screens/coach.dart':
      'leads the coach status row, whose text names the current step',
  'lib/ui2/profile/wearable_numbers.dart':
      'replaces the switch while the row subtitle reads deviceUseWorking',
  'lib/ui2/pairing/device_picker.dart':
      'ends the "Scanning for devices nearby…" row',
  'lib/ui2/profile/import_progress_view.dart':
      'sits above the import stage status and its done/total line',
};

String _rel(File f) => f.path.replaceAll('\\', '/');

void main() {
  test('no bare CircularProgressIndicator in lib/ui2', () {
    final offenders = <String>[];
    final spinner = RegExp(r'\bCircularProgressIndicator\(');
    for (final f in dartFilesIn('lib/ui2')) {
      final path = _rel(f);
      if (path == _primitive || _allowed.containsKey(path)) continue;
      final code = codeOnly(f.readAsStringSync());
      for (final m in spinner.allMatches(code)) {
        offenders.add('$path:${lineOf(code, m.start)}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'Spinners with no status. Use InlineLoading(status: ...) or, '
            'for a busy mark inside a control whose text states the action, '
            'add the file to _allowed with a reason:\n${offenders.join('\n')}');
  });

  test('every allow-listed file still has a spinner (no stale entries)', () {
    for (final path in _allowed.keys) {
      expect(File(path).existsSync(), isTrue, reason: path);
      final code = codeOnly(File(path).readAsStringSync());
      expect(code.contains('CircularProgressIndicator('), isTrue,
          reason: '$path is allow-listed but has no spinner; drop the entry');
      expect(_allowed[path]!.trim(), isNotEmpty, reason: path);
    }
  });

  test('no InlineLoading() without a status in lib/ui2', () {
    final offenders = <String>[];
    final empty = RegExp(r'\bInlineLoading\(\s*\)');
    for (final f in dartFilesIn('lib/ui2')) {
      final code = codeOnly(f.readAsStringSync());
      for (final m in empty.allMatches(code)) {
        offenders.add('${_rel(f)}:${lineOf(code, m.start)}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'InlineLoading needs a status:\n${offenders.join('\n')}');
  });
}
