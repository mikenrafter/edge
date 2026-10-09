import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_runner.dart';

/// How many lines of a failed run the error message shows; the log has all.
const failureTailLines = 40;

/// The complete output of one run as text: what ran, how it ended, then stdout
/// and stderr (kept apart: the runner reads them as two pipes).
String renderRunLog(List<String> argv, ProcessOutcome outcome) => [
      'command: ${argv.join(' ')}',
      'exit code: ${outcome.exitCode}'
          '${outcome.timedOut ? ' (timed out)' : ''}${outcome.cancelled ? ' (cancelled)' : ''}'
          '${outcome.outputComplete ? '' : ' (output may be cut short: a surviving process held the pipes)'}',
      '',
      '===== stdout =====',
      ...outcome.stdoutLines,
      '',
      '===== stderr =====',
      outcome.stderr.endsWith('\n') ? outcome.stderr.substring(0, outcome.stderr.length - 1) : outcome.stderr,
      '',
    ].join('\n');

/// The last [lines] lines of the run's stderr, or of its stdout when stderr is
/// empty (a framework crash and a `pub get` failure write to stderr; the JSON
/// reporter writes to stdout).
String failureTail(ProcessOutcome outcome, {int lines = failureTailLines}) =>
    tailLines(outcome.stderr.trim().isNotEmpty ? outcome.stderr : outcome.stdoutLines.join('\n'), lines);

/// The last [n] non-empty-trailing lines of [text].
String tailLines(String text, int n) {
  final all = text.trimRight().split('\n');
  return all.skip(all.length > n ? all.length - n : 0).join('\n');
}

/// Writes [text] to `<outDir>/<name>` (the directory is created) and returns
/// the path, or null when it cannot be written: a failed log must not hide the
/// failure it describes.
String? saveLog(String outDir, String name, String text) {
  try {
    final dir = Directory(p.absolute(outDir))..createSync(recursive: true);
    final file = File(p.join(dir.path, name));
    file.writeAsStringSync(text.endsWith('\n') ? text : '$text\n');
    return file.path;
  } on FileSystemException {
    return null;
  }
}

/// [message], then the tail of [text] and where the whole of it was saved.
String withLogTail(String message, {required String tail, required String? logPath, int lines = failureTailLines}) =>
    [
      message,
      if (tail.trim().isNotEmpty) 'last $lines lines of the output:\n${tailLines(tail, lines).split('\n').map((l) => '  $l').join('\n')}',
      if (logPath != null) 'full output: $logPath',
    ].join('\n');
