import 'dart:async';

import 'package:mutation_audit/mutation_audit.dart';

/// One call the fake runner saw.
class Call {
  Call(this.argv, this.cwd, this.timeout, [this.environment, this.cancel]);
  final Map<String, String>? environment;

  /// The token the caller wants the run to honour (null: not cancellable).
  final CancelToken? cancel;
  final List<String> argv;
  final String cwd;
  final Duration? timeout;
}

/// A process runner whose answer is computed from the call (and, in tests that
/// mutate files, from the file contents at that moment). Records the calls and
/// the largest number of overlapping calls.
class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner(this.handler);

  final FutureOr<ProcessOutcome> Function(Call call) handler;
  final List<Call> calls = [];
  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<ProcessOutcome> run(
    List<String> argv, {
    required String workingDirectory,
    Duration? timeout,
    Map<String, String>? environment,
    CancelToken? cancel,
  }) async {
    final call = Call(argv, workingDirectory, timeout, environment, cancel);
    calls.add(call);
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      // Yield so a runner that overlapped calls would be seen overlapping.
      await Future<void>.delayed(Duration.zero);
      return await handler(call);
    } finally {
      _inFlight--;
    }
  }
}
