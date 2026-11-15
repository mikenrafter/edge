// Owner: SleepEditRunner owns the interactive sleep worker lane. The durable
// queue is SleepEditStore. Saves only wake this lane; they never await it.
//
// A run that could not finish is not a failed edit when the cause is the
// world moving (an earlier night edited meanwhile, a long pass still running):
// it is requeued. A run that really failed is retried here, with a backoff,
// not only at the next app start. CLAIM(sleep-edit-retry)
// [responsiveness_sleep_retry_test].
import 'dart:async';
import '../data/sleep_edit_store.dart';

/// Thrown by a run that stopped for a reason that will not hold on the next
/// attempt. [counts] false: waiting is not a fault, so it never uses up the
/// attempts (a pass that takes ten minutes is not the edit's failure).
class SleepEditRequeue implements Exception {
  const SleepEditRequeue(this.reason, {this.counts = true});
  final String reason;
  final bool counts;
  @override
  String toString() => reason;
}

class SleepEditRunner {
  SleepEditRunner({
    required this.run,
    required this.publish,
    required this.hold,
    this.onError,
    this.timeout = const Duration(minutes: 15),
    this.maxRequeues = 4,
    this.retryDelays = const [
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
    ],
  });
  final Future<void> Function(SleepEditJob job) run;
  final Future<void> Function() publish;
  final void Function(bool) hold;
  final Duration timeout;

  /// Requeues one revision may use before the edit reports a failure instead.
  final int maxRequeues;

  /// Waits between in-process retries of failed jobs; the last repeats. Empty:
  /// failed jobs wait for the user's Retry or the next start.
  final List<Duration> retryDelays;
  final void Function(Object error)? onError;
  Future<void>? _active;
  bool _disposed = false, _again = false;
  Timer? _retry;
  int _retryStep = 0;
  final _requeues = <String, int>{};

  Future<void> start({bool restart = false}) {
    _again = true;
    _retry?.cancel();
    _retry = null;
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
    var anyFailed = false;
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
            _requeues.remove('${job.day}:${job.revision}');
          } on SleepEditRequeue catch (r) {
            final key = '${job.day}:${job.revision}';
            final used = r.counts ? (_requeues[key] = (_requeues[key] ?? 0) + 1) : 0;
            if (used >= maxRequeues) {
              _requeues.remove(key);
              anyFailed = true;
              await SleepEditStore.advance(job, SleepEditPhase.failed,
                  error: 'Still not applied after $used tries: ${r.reason}');
            } else {
              await SleepEditStore.advance(job, SleepEditPhase.queued);
              _again = true;
            }
            await publish();
          } catch (e) {
            anyFailed = true;
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
      if (anyFailed && !_disposed) {
        _scheduleRetry();
      } else if (!anyFailed) {
        _retryStep = 0;
      }
    }
  }

  void _scheduleRetry() {
    if (retryDelays.isEmpty) return;
    final delay = retryDelays[_retryStep.clamp(0, retryDelays.length - 1)];
    _retryStep++;
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      if (_disposed) return;
      unawaited(start(restart: true).catchError((Object error) {
        onError?.call(error);
      }));
    });
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
  }
}
