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

/// Named effects keep the worker lane traceable by the heavy-work guard.
abstract interface class SleepEditEffects {
  Future<void> run(SleepEditJob job);
  Future<void> publish();
  void hold(bool held);
  void report(Object error);
}

/// Queue acquisition can fail independently of a job's calculation.
abstract interface class SleepEditQueue {
  Future<List<SleepEditJob>> pending({bool retryFailed = false});
}

final class LocalSleepEditQueue implements SleepEditQueue {
  const LocalSleepEditQueue();
  @override
  Future<List<SleepEditJob>> pending({bool retryFailed = false}) =>
      SleepEditStore.pending(retryFailed: retryFailed);
}

class SleepEditRunner {
  SleepEditRunner({
    required this.effects,
    this.queue = const LocalSleepEditQueue(),
    this.timeout = const Duration(minutes: 15),
    this.maxRequeues = 4,
    this.retryDelays = const [
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
    ],
  });
  final SleepEditEffects effects;
  final SleepEditQueue queue;
  final Duration timeout;

  /// Requeues one revision may use before the edit reports a failure instead.
  final int maxRequeues;

  /// Waits between in-process retries of failed jobs; the last repeats. Empty:
  /// failed jobs wait for the user's Retry or the next start.
  final List<Duration> retryDelays;
  Future<void>? _active;
  bool _disposed = false, _again = false, _restart = false;
  Timer? _retry;
  int _retryStep = 0;
  final _requeues = <String, int>{};

  Future<void> start({bool restart = false}) {
    _again = true;
    _restart |= restart;
    if (restart) {
      _retry?.cancel();
      _retry = null;
    }
    return _active ??= _drain().whenComplete(() {
      _active = null;
      if (_again && !_disposed) {
        unawaited(start().catchError(_report));
      }
    });
  }

  Future<void> _drain() async {
    effects.hold(true);
    var queueFailed = false;
    try {
      while (!_disposed) {
        _again = false;
        final jobs = await queue.pending(retryFailed: _restart);
        _restart = false;
        if (jobs.isEmpty) break;
        for (final job in jobs) {
          if (_disposed) break;
          Future<void>? work;
          var changed = false; // the job's state moved without finishing
          try {
            work = effects.run(job);
            await work.timeout(timeout);
            _requeues.remove('${job.day}:${job.revision}');
          } on SleepEditRequeue catch (r) {
            final key = '${job.day}:${job.revision}';
            final used = r.counts
                ? (_requeues[key] = (_requeues[key] ?? 0) + 1)
                : 0;
            if (used >= maxRequeues) {
              _requeues.remove(key);
              await SleepEditStore.advance(
                job,
                SleepEditPhase.failed,
                error: 'Still not applied after $used tries: ${r.reason}',
              );
            } else {
              await SleepEditStore.advance(job, SleepEditPhase.queued);
              _again = true;
            }
            changed = true;
          } catch (e) {
            await SleepEditStore.advance(
              job,
              SleepEditPhase.failed,
              error: '$e',
            );
            changed = true;
          }
          if (changed) await effects.publish();
          // A timeout is not cancellation. Keep ownership until the actual
          // worker exits, even though the saved controls remain available.
          if (changed && work != null) {
            try {
              await work;
            } catch (_) {}
          }
        }
      }
    } catch (error) {
      // Queue acquisition is work too: a transient read error must not strand
      // durable jobs without a wake-up. CLAIM(sleep-edit-retry).
      queueFailed = true;
      _again = false;
      _report(error);
    } finally {
      effects.hold(false);
      if (!_disposed) {
        var outstanding = queueFailed;
        try {
          outstanding |= (await queue.pending(retryFailed: true)).isNotEmpty;
        } catch (error) {
          outstanding = true;
          _report(error);
        }
        if (outstanding) {
          if (_retry == null) _scheduleRetry();
        } else {
          _retry?.cancel();
          _retry = null;
          _retryStep = 0;
        }
      }
    }
  }

  void _report(Object error) => effects.report(error);

  void _scheduleRetry() {
    if (retryDelays.isEmpty) return;
    final delay = retryDelays[_retryStep.clamp(0, retryDelays.length - 1)];
    _retryStep++;
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      if (_disposed) return;
      unawaited(start(restart: true).catchError(_report));
    });
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
  }
}
