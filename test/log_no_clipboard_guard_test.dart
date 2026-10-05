// 8AL (red): source guard. No log leaves the app through the clipboard.
//
//   * Across lib/, `Clipboard.setData` appears in no file but settings.dart
//     (the automation TOKEN, a secret the user pastes elsewhere; not a log), so
//     a new log-copy affordance fails here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';

void main() {
  const settings = 'lib/ui2/profile/settings.dart';

  test('no other file under lib/ writes to the clipboard', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('/l10n/') || f.path.contains('/l10n/')) continue;
      if (f.path == settings) continue;
      if (codeOnly(f.readAsStringSync()).contains('Clipboard.setData')) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'a log is saved as a file (lib/util/log_file.dart), not copied');
  });
}
