// D8, one log: the issue report attaches the dev log, and nothing in lib/
// writes the old FileLog (openstrap_sync.log) any more.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/support/issue_report.dart';
import 'package:openstrap_edge/sync/dev_log.dart';

void main() {
  late Directory base;
  late DevLog previous;
  var clock = DateTime(2026, 10, 6, 12);

  setUp(() {
    base = Directory.systemTemp.createTempSync('report_devlog_');
    previous = DevLog.instance;
    DevLog.instance = DevLog(
      baseDir: () async => base,
      now: () => clock,
      devMode: () async => false,
    );
  });

  tearDown(() {
    DevLog.instance = previous;
    base.deleteSync(recursive: true);
  });

  test('the report log holds recent dev log lines, oldest first', () async {
    clock = DateTime(2026, 10, 5, 23);
    await DevLog.write('[sync] drain done yesterday');
    clock = DateTime(2026, 10, 6, 7);
    await DevLog.write('[alarm] armed for 07:30');
    await DevLog.write('[report] slice cut to 3 days', always: true);
    await DevLog.instance.flush();

    final log = await recentReportLog();
    expect(log, contains('drain done yesterday'));
    expect(log, contains('armed for 07:30'));
    expect(log, contains('[report] slice cut'));
    expect(log.indexOf('yesterday'), lessThan(log.indexOf('armed for')));
  });

  test('over the cap the newest bytes are kept', () async {
    final dir = await DevLog.instance.dir();
    File('${dir!.path}/dev-2026-10-05.log')
        .writeAsStringSync('OLD${'a' * kReportLogBytes}\n');
    File('${dir.path}/dev-2026-10-06.log').writeAsStringSync('${'b' * 1000}NEWEST\n');
    final log = await recentReportLog();
    expect(log.length, kReportLogBytes);
    expect(log, endsWith('NEWEST\n'));
    expect(log, isNot(contains('OLD')));
  });

  test('no dev log yet is an empty section', () async {
    expect(await recentReportLog(), '');
  });

  test('lib/ has no FileLog; [report] lines go to the dev log, always on', () {
    expect(File('lib/sync/file_log.dart').existsSync(), isFalse);
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('sync/dev_log.dart')) continue; // comment only
      expect(f.readAsStringSync(), isNot(contains('FileLog')), reason: f.path);
    }
    for (final p in [
      'lib/data/recent_slice.dart',
      'lib/support/issue_report.dart',
      'lib/ui2/profile/report_issue.dart',
    ]) {
      final s = File(p).readAsStringSync();
      expect(RegExp(r"DevLog\.write\(\s*'\[report\]").hasMatch(s), isTrue,
          reason: p);
      // Always on: a report diagnostic is rare and tiny, and developer mode
      // is off for nearly everyone who files one.
      expect(s, contains('always: true'), reason: p);
    }
  });
}
