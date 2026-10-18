import 'dart:async';
import 'dart:isolate';

/// Runs [body] in a spawned isolate and kills it after [limit]. [body] gets a
/// `step` callback; the last step named before a timeout is reported, so a
/// hang points at the call that never returned. A synchronous infinite loop
/// cannot be stopped by a test timeout in the same isolate; an immediate kill
/// interrupts it.
///
/// Returns the value [body] returned (must be sendable). Throws a
/// [TimeoutException] naming the last step on a hang, and rethrows (as a
/// string) any error raised in [body].
Future<T> boundedRun<T>(
  T Function(void Function(String) step) body, {
  Duration limit = const Duration(seconds: 60),
}) async {
  final port = ReceivePort();
  final errors = ReceivePort();
  final done = Completer<T>();
  var last = '(start)';
  // A top-level entry: a closure here would capture this function's context
  // (the completer), which cannot be sent.
  final iso = await Isolate.spawn<(SendPort, Object? Function(void Function(String)))>(
      _entry, (port.sendPort, body), onError: errors.sendPort);
  port.listen((m) {
    final msg = m as List;
    if (msg[0] == 'step') {
      last = msg[1] as String;
    } else if (!done.isCompleted) {
      done.complete(msg[1] as T);
    }
  });
  errors.listen((e) {
    if (!done.isCompleted) {
      done.completeError(StateError('in step "$last": ${(e as List)[0]}\n${e[1]}'));
    }
  });
  try {
    return await done.future.timeout(limit,
        onTimeout: () => throw TimeoutException(
            'did not return within $limit; hung in step "$last"'));
  } finally {
    iso.kill(priority: Isolate.immediate);
    port.close();
    errors.close();
  }
}

void _entry((SendPort, Object? Function(void Function(String))) m) {
  final (p, body) = m;
  final r = body((s) => p.send(['step', s]));
  p.send(['done', r]);
}
