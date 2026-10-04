// 8AL (red): source guards. No log leaves the app through the clipboard.
//
//   * lib/ui2/profile/device_lab.dart and pattern_probe_page.dart never call
//     `Clipboard.setData` and no longer label a button "Copy all logs".
//   * lib/ui2/profile/settings.dart's AutomationSettings still copies the
//     automation TOKEN (a secret the user pastes elsewhere; not a log). Out of
//     scope: it must keep `Clipboard.setData`.
//   * Across lib/, `Clipboard.setData` appears in no file but settings.dart
//     (the token), so a new log-copy affordance fails here.
//   * The saver is wired in: both screens reference the general log-file seam
//     (lib/util/log_file.dart: `saveLogFile`, `logFileName`) and name their
//     kind: 'device-lab' / 'pattern-probe'.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../phase8/support/dart_source.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  const lab = 'lib/ui2/profile/device_lab.dart';
  const probe = 'lib/ui2/profile/pattern_probe_page.dart';
  const settings = 'lib/ui2/profile/settings.dart';

  for (final p in [lab, probe]) {
    group(p, () {
      test('never writes to the clipboard', () {
        final code = codeOnly(_read(p));
        expect(code, isNot(contains('Clipboard.setData')));
        expect(code, isNot(contains('ClipboardData')));
      });

      test('has no "Copy all logs" button or "Log copied" message', () {
        final src = _read(p);
        expect(src, isNot(contains("'Copy all logs'")));
        expect(src, isNot(contains("'Log copied'")));
        expect(src, isNot(contains("'Copied'")));
      });
    });
  }

  test('the lab and the probe save through the general log-file seam', () {
    for (final p in [lab, probe]) {
      final code = codeOnly(_read(p));
      expect(code, contains('LogFileSaver'), reason: p);
      expect(code, contains('saveLogFile'), reason: p);
      expect(code, contains('logFileName'), reason: p);
    }
    expect(_read(lab), contains("'device-lab'"));
    expect(_read(probe), contains("'pattern-probe'"));
  });

  test('the automation token is still copied (not a log, out of scope)', () {
    final code = codeOnly(_read(settings));
    expect(code, contains('Clipboard.setData'));
    expect(_read(settings), contains('settingsCopyTheToken'));
  });

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
