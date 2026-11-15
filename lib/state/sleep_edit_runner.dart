// Owner: SleepEditRunner owns the interactive sleep worker lane. The durable
// queue is SleepEditStore. Saves only wake this lane; they never await it.
import 'dart:async';
import '../data/sleep_edit_store.dart';

class SleepEditRunner {
  SleepEditRunner({
    required this.run,
    required this.publish,
    required this.hold,
    this.onError,
    this.timeout = const Duration(minutes: 15),
  });
  final Future<void> Function(SleepEditJob job) run;
  final Future<void> Function() publish;
  final void Function(bool) hold;
  final Duration timeout;
  final void Function(Object error)? onError;
  Future<void>? _active;
  bool _disposed = false, _again = false;

  Future<void> start({bool restart = false}) {
    _again = true;
    return _active ??= _drain(restart).whenComplete(() {
      _active = null;
      if (_again && !_disposed) {
        unawaited(
          start().catchError((Object error) {
            onError?.call(error);
          }),
        );
      }
    });
  }

  Future<void> _drain(bool restart) async {
    hold(true);
    try {
      while (!_disposed) {
        _again = false;
        final jobs = await SleepEditStore.pending(retryFailed: restart);
        restart = false;
        if (jobs.isEmpty) break;
        for (final job in jobs) {
          if (_disposed) break;
          Future<void>? work;
          try {
            work = run(job);
            await work.timeout(timeout);
          } catch (e) {
            await SleepEditStore.advance(
              job,
              SleepEditPhase.failed,
              error: '$e',
            );
            await publish();
            // A timeout is not cancellation. Keep ownership until the actual
            // worker exits, even though the saved controls remain available.
            try {
              await work;
            } catch (_) {}
          }
        }
      }
    } finally {
      hold(false);
    }
  }

  void dispose() {
    _disposed = true;
  }
}
