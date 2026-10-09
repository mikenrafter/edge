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

/// Spawns real processes (the only place the tool touches real time).
class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
  }) =>
      throw UnimplementedError('SystemProcessRunner.run');
}
