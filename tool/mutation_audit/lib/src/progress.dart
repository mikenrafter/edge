import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'classifier.dart';
import 'mutant.dart';
import 'process_runner.dart';
import 'reporter_parser.dart';

/// What an operator sees while an audit runs (a long one takes hours), so that
/// a slow run can be told from a hung one.
///
/// * Phase lines, one per event, each prefixed with the wall-clock time and
///   handed to [write] at once (the command line writes it to stderr, unbuffered).
/// * Per mutant a start and an end line; the end line carries the elapsed time
///   and an ETA from the mean duration of the mutants finished so far.
/// * A heartbeat while a child run is in progress ([tracked]): every
///   [heartbeat] a line with the child's pid, the tests it has finished and
///   the one it started last, read from the JSON reporter stream as it arrives.
/// * `progress.jsonl` ([logPath]): the same per-mutant facts, one JSON object
///   per line, appended and flushed after every finished mutant. It is a
///   PARTIAL, diagnostic file (every line says `"partial": true`): it survives
///   an abort, and it is not the result; results.json / summary.md are
///   published only by a run that completed.
///
/// Time comes from [now] and timers from [alarm]; the tool never reads the real
/// clock here, so tests drive both. Owns its state (the mutant timing, the log
/// file); the audit loop only reports events to it.
class ProgressReporter {
  ProgressReporter({
    required this.now,
    required this.write,
    this.heartbeat = const Duration(seconds: 60),
    Alarm Function(Duration after)? alarm,
    this.logPath,
  }) : _alarm = alarm ?? systemAlarm;

  /// Writes nothing, beats never, logs nowhere (the audit loop without a reporter).
  ProgressReporter.silent()
      : now = DateTime.now,
        write = _ignore,
        heartbeat = Duration.zero,
        _alarm = systemAlarm,
        logPath = null;

  static void _ignore(String _) {}

  final DateTime Function() now;
  final void Function(String line) write;

  /// Time between "still running" lines; zero: none.
  final Duration heartbeat;
  final Alarm Function(Duration after) _alarm;

  /// Where `progress.jsonl` goes (null: not written).
  final String? logPath;

  DateTime? _mutantsBeganAt, _mutantStartedAt;
  Duration _mutantTime = Duration.zero;
  bool _logFailureShown = false;

  /// `1h02m03s`, `2m05s`, `12s`, `3.4s`.
  static String formatDuration(Duration d) {
    final ms = d.inMilliseconds;
    if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1)}s';
    final s = (ms / 1000).round();
    if (s < 60) return '${s}s';
    final m = s ~/ 60, h = m ~/ 60;
    String two(int n) => n.toString().padLeft(2, '0');
    if (h == 0) return '${m}m${two(s % 60)}s';
    return '${h}h${two(m % 60)}m${two(s % 60)}s';
  }

  String _stamp() => '${now().toUtc().toIso8601String().substring(0, 19)}Z';

  /// One timestamped line.
  void line(String message) => write('${_stamp()} $message');

  /// `<name> start` now; the returned function prints `<name> done in <t>`
  /// (and `: <detail>`) when called.
  void Function([String? detail]) step(String name) {
    final began = now();
    line('$name start');
    return ([detail]) =>
        line('$name done in ${formatDuration(now().difference(began))}${detail == null ? '' : ': $detail'}');
  }

  /// Runs [body], which starts one child run and passes the [RunObserver] it
  /// gets to the process runner. While [body] is running, a heartbeat line is
  /// printed every [heartbeat]; it stops when [body] ends, however it ends.
  /// [phase] names the run in those lines (`baseline`, `mutant`), [position]
  /// is appended (`[3/10]`).
  Future<T> tracked<T>(String phase, Future<T> Function(RunObserver observer) body, {String? position}) async {
    final parser = ReporterStreamParser();
    final began = now();
    int? pid;
    var active = heartbeat > Duration.zero;
    Alarm? pending;

    void beat() {
      final last = parser.lastTest;
      line('… still running $phase${position == null ? '' : ' $position'} '
          'for ${formatDuration(now().difference(began))}${pid == null ? '' : ' (pid $pid)'}: '
          '${parser.testsDone} tests done (${parser.passed} passed, ${parser.failed} failed)'
          '${last == null ? '' : ', last: $last'}');
    }

    void arm() {
      if (!active) return;
      final alarm = pending = _alarm(heartbeat);
      alarm.fired.then((_) {
        if (!active) return;
        beat();
        arm();
      });
    }

    arm();
    try {
      return await body(RunObserver(onStart: (value) => pid = value, onStdoutLine: parser.addLine));
    } finally {
      active = false;
      pending?.cancel();
    }
  }

  /// The first line of `progress.jsonl` (replacing what an earlier run left):
  /// what is about to be audited. [meta] is merged under `type: meta`.
  void writeMeta(Map<String, Object?> meta) =>
      _log({'type': 'meta', 'partial': true, ...meta}, replace: true);

  /// `[i/N] <id> <file>:<line> <operator> '<original>'->'<mutated>'`, and the
  /// mutant's clock starts.
  void mutantStarted(int index, int total, Mutant m) {
    final t = now();
    _mutantsBeganAt ??= t;
    _mutantStartedAt = t;
    line('[$index/$total] ${m.id} ${m.file}:${m.line} ${m.operator.id} '
        "'${_short(m.original)}'→'${_short(m.mutated)}'");
  }

  /// `[i/N] <status> (<k> killing, <d> discounted) <t>; elapsed <t>; ETA <t>`,
  /// the log line, and the mean for the next ETA. The duration is the wall
  /// time of the mutant: its run, its reruns, the classification.
  void mutantFinished(int index, int total, Mutant m, Classification c) {
    final t = now();
    final took = t.difference(_mutantStartedAt ?? t);
    _mutantTime += took;
    final left = total > index ? total - index : 0;
    final eta = Duration(microseconds: _mutantTime.inMicroseconds * left ~/ (index < 1 ? 1 : index));
    line('[$index/$total] ${c.status.id} (${c.killers.length} killing, ${c.discounted.length} discounted) '
        '${formatDuration(took)}; elapsed ${formatDuration(t.difference(_mutantsBeganAt ?? t))}; '
        'ETA ${formatDuration(eta)}');
    _log({
      'type': 'mutant',
      'partial': true,
      'index': index,
      'total': total,
      'id': m.id,
      'file': m.file,
      'line': m.line,
      'operator': m.operator.id,
      'status': c.status.id,
      'killers': [
        for (final k in c.killers) {'test': k.key, 'kind': k.kind.id}
      ],
      'discounted': c.guardTests,
      'durationMs': took.inMilliseconds,
    });
  }

  /// One line of the log, flushed to disk before returning. A log that cannot
  /// be written is said once and then ignored: it must not stop an audit.
  void _log(Map<String, Object?> row, {bool replace = false}) {
    final path = logPath;
    if (path == null) return;
    try {
      if (replace) Directory(p.dirname(path)).createSync(recursive: true);
      File(path).writeAsStringSync('${jsonEncode(row)}\n',
          mode: replace ? FileMode.write : FileMode.append, flush: true);
    } on FileSystemException catch (e) {
      if (_logFailureShown) return;
      _logFailureShown = true;
      line('progress log $path not written: ${e.message}');
    }
  }
}

/// One line, at most 80 characters: a mutated expression can span lines.
String _short(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 80 ? flat : '${flat.substring(0, 79)}…';
}
