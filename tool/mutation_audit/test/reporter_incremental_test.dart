import 'package:mutation_audit/mutation_audit.dart';
import 'package:test/test.dart';

import 'support/events.dart';

/// The parser the heartbeat reads while a run is still streaming: the same
/// rules as `parseReporterStream`, fed one line at a time.
void main() {
  const suite = 'test/a_test.dart';

  StreamBuilder mixed() => StreamBuilder()
      .loaded(suite)
      .pass(suite, 'g one')
      .fail(suite, 'g two')
      .test(suite, 'g three', skipped: true)
      .throws(suite, 'g (setUpAll)')
      .raw('Running flutter pub get...')
      .test(suite, 'g hidden', hidden: true)
      .pass(suite, 'g four')
      .done(success: false);

  test('feeding line by line ends in exactly what parseReporterStream returns', () {
    final lines = mixed().build();
    final parser = ReporterStreamParser();
    for (final l in lines) {
      parser.addLine(l);
    }
    final live = parser.snapshot();
    final batch = parseReporterStream(lines);
    expect([for (final t in live.tests) t.key], [for (final t in batch.tests) t.key]);
    expect([for (final t in live.tests) t.result], [for (final t in batch.tests) t.result]);
    expect([for (final t in live.tests) t.skipped], [for (final t in batch.tests) t.skipped]);
    expect(live.setupFailures.map((f) => f.name), batch.setupFailures.map((f) => f.name));
    expect(live.nonJsonLines, batch.nonJsonLines);
    expect(live.sawDone, batch.sawDone);
    expect(live.doneSuccess, batch.doneSuccess);
  });

  test('the counters follow the stream as it arrives', () {
    final p = ReporterStreamParser();
    expect((p.testsDone, p.passed, p.failed, p.lastTest), (0, 0, 0, null));

    var seen = 0;
    List<(int, int, int, String?)> history = [];
    for (final l in mixed().build()) {
      p.addLine(l);
      seen++;
      history.add((p.testsDone, p.passed, p.failed, p.lastTest));
    }
    expect(seen, greaterThan(10));
    // After the whole stream: one, two (failed), three (skipped), four; the hook,
    // the loading pseudo-test and the hidden test are plumbing, not tests.
    expect(history.last, (4, 2, 1, 'g four'));
    expect(p.skipped, 1);
    // Counts only ever grow.
    for (var i = 1; i < history.length; i++) {
      expect(history[i].$1, greaterThanOrEqualTo(history[i - 1].$1));
    }
  });

  test('last is the test that started last, finished or not: the one a hang is in', () {
    final p = ReporterStreamParser();
    for (final l in StreamBuilder().loaded(suite).pass(suite, 'g done').unfinished(suite, 'g stuck').build()) {
      p.addLine(l);
    }
    expect(p.testsDone, 1);
    expect(p.lastTest, 'g stuck');
  });

  test('a loading pseudo-test or a hook never becomes "last"', () {
    final p = ReporterStreamParser();
    for (final l in StreamBuilder().pass(suite, 'g real').loaded('test/b_test.dart').throws(suite, 'g (tearDownAll)').build()) {
      p.addLine(l);
    }
    expect(p.lastTest, 'g real');
  });

  test('lines that are not events, and half-written ones, change nothing', () {
    final p = ReporterStreamParser();
    for (final l in ['', 'Resolving dependencies...', '{"type":"testSta', '[1,2]', '{"type":"unknown"}']) {
      p.addLine(l);
    }
    expect((p.testsDone, p.passed, p.failed, p.lastTest), (0, 0, 0, null));
    expect(p.snapshot().nonJsonLines, ['Resolving dependencies...', '{"type":"testSta', '[1,2]']);
  });

  test('suite paths inside root are relative, as in parseReporterStream', () {
    final lines = StreamBuilder().pass('/x/export/test/a_test.dart', 'g one').build();
    final p = ReporterStreamParser(root: '/x/export');
    lines.forEach(p.addLine);
    expect(p.snapshot().tests.single.suite, 'test/a_test.dart');
  });
}
