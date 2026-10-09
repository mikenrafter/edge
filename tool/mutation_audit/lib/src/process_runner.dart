import 'dart:convert';
import 'dart:io';

/// What one command run produced.
class ProcessOutcome {
  const ProcessOutcome({
    required this.exitCode,
    this.stdoutLines = const [],
    this.stderr = '',
    this.timedOut = false,
    this.elapsed = Duration.zero,
  });

  final int exitCode;
  final List<String> stdoutLines;
  final String stderr;

  /// The run was stopped because it exceeded its timeout.
  final bool timedOut;
  final Duration elapsed;
}

/// Runs a command to completion. The real one spawns a process; tests inject a
/// fake. The runner owns the timeout (the tool never reads the real clock).
abstract class ProcessRunner {
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
  });
}

/// Spawns real processes (the only place the tool touches real time). The
/// environment is the parent's with [environment] on top. On a timeout the
/// process and everything it started (found with `pgrep -P`) is stopped:
/// SIGTERM first, SIGKILL if it is still there a few seconds later.
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
  }) async {
    final clock = Stopwatch()..start();
    final Process process;
    try {
      process = await Process.start(argv.first, argv.sublist(1),
          workingDirectory: workingDirectory, environment: environment);
    } on ProcessException catch (e) {
      return ProcessOutcome(exitCode: 127, stderr: e.toString(), elapsed: clock.elapsed);
    }
    final out = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .toList();
    final err = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    Future<int> exit = process.exitCode;
    if (timeout != null) {
      exit = exit.timeout(timeout, onTimeout: () async {
        timedOut = true;
        await _stopTree(process);
        return process.exitCode;
      });
    }
    final code = await exit;
    return ProcessOutcome(
      exitCode: code,
      stdoutLines: await out,
      stderr: await err,
      timedOut: timedOut,
      elapsed: clock.elapsed,
    );
  }

  Future<void> _stopTree(Process process) async {
    final pids = await _descendants(process.pid);
    for (final pid in pids.reversed) {
      Process.killPid(pid, ProcessSignal.sigterm);
    }
    process.kill(ProcessSignal.sigterm);
    final gone = await process.exitCode
        .then((_) => true)
        .timeout(const Duration(seconds: 5), onTimeout: () => false);
    if (!gone) {
      for (final pid in pids.reversed) {
        Process.killPid(pid);
      }
      process.kill(ProcessSignal.sigkill);
    }
  }

  /// Child pids, breadth first (so reversed is deepest first).
  Future<List<int>> _descendants(int pid) async {
    final found = <int>[];
    final queue = [pid];
    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);
      try {
        final r = await Process.run('pgrep', ['-P', '$parent']);
        for (final line in LineSplitter.split(r.stdout as String)) {
          final child = int.tryParse(line.trim());
          if (child != null) {
            found.add(child);
            queue.add(child);
          }
        }
      } on ProcessException {
        break; // no pgrep: stop what we can
      }
    }
    return found;
  }
}
