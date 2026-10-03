// 8AC: the one queue every band haptic job goes through. A band plays one
// thing at a time and drops a command written while it plays, and the band's
// haptic motor must not be driven past 30 commands in any 2 minutes. Two alerts
// at once, a tap ack during a rule's rhythm, or the pattern probe next to a
// real alert would break one or both. So every job (a rule's rhythm, a single
// buzz, a tap ack, a preview, the ECG count buzzes) waits its turn here.
//
// A job starts when the previous one has finished (its last command's "ended"
// event 100, or a timeout) AND the shared [BandCommandLedger] allows its
// commands. A job that cannot start before its deadline (measured from when it
// was queued) is dropped as [BuzzDelivery.rejected] with nothing written, which
// the alert dispatcher reads as "give the claim back". Once a job has started,
// its transport timeout counts from the start.
//
// No Flutter, no BLE. Time comes from package:clock, so tests drive it with
// fake_async.

import 'dart:async';

import 'package:clock/clock.dart';

import '../notify/buzz_sequence.dart';

/// How long a queued job may wait to START. The alert dispatcher adds this to
/// a band delivery's deadline so waiting in the queue does not eat the
/// transport time.
const Duration kBandQueueWait = Duration(seconds: 15);

/// The rolling safety limit: at most [maxCommands] band haptic commands in any
/// [window]. One instance is shared by the alert queue and the pattern probe,
/// so the lab and real alerts cannot exceed it together.
class BandCommandLedger {
  static const int maxCommands = 30;
  static const Duration window = Duration(minutes: 2);

  // One entry per command, oldest first.
  final List<DateTime> _at = <DateTime>[];

  /// The list itself, for the pattern probe: it appends one entry per write
  /// and prunes it by the same window.
  List<DateTime> get writeLog => _at;

  void _prune(DateTime now) =>
      _at.removeWhere((w) => !w.add(window).isAfter(now));

  /// Count [n] commands written at [at].
  void record(int n, DateTime at) {
    for (var i = 0; i < n; i++) {
      _at.add(at);
    }
    _at.sort();
  }

  /// Commands that may still be sent at [now], never below 0.
  int commandsLeft(DateTime now) {
    _prune(now);
    return (maxCommands - _at.length).clamp(0, maxCommands);
  }

  /// Time until the oldest command leaves the window; null when it is empty.
  Duration? nextFreeIn(DateTime now) {
    _prune(now);
    if (_at.isEmpty) return null;
    return _at.first.add(window).difference(now);
  }

  /// How long until [n] more commands fit (zero when they fit now). More than
  /// [maxCommands] is treated as [maxCommands]: such a job waits for an empty
  /// window.
  Duration waitFor(int n, DateTime now) {
    _prune(now);
    final want = n > maxCommands ? maxCommands : n;
    final over = _at.length + want - maxCommands;
    if (over <= 0) return Duration.zero;
    return _at[over - 1].add(window).difference(now);
  }
}

/// The band's "ended" event (100) as a wait. [reset] on every write, [signal]
/// on a live event 100; [wait] is true when a 100 has come since the reset,
/// also when it came before the wait began.
class BandEndedSignal {
  bool _got = false;
  Completer<void>? _waiter;

  void reset() => _got = false;

  void signal() {
    _got = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<bool> wait(Duration timeout) async {
    if (_got) return true;
    final c = _waiter ??= Completer<void>();
    try {
      await c.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

class _Job {
  _Job(this.run, this.commands, this.timeout, this.settle, this.deadline);
  final Future<BuzzDelivery> Function() run;
  final int commands;
  final Duration timeout;
  final Duration settle;
  final DateTime deadline;
  final Completer<BuzzDelivery> done = Completer<BuzzDelivery>();
  Timer? expiry;
}

class BandHapticQueue {
  BandHapticQueue({required this.ledger, this.waitEnded, this.log});

  final BandCommandLedger ledger;

  /// Waits for the band's ended event; used to hold the slot after a job that
  /// asked to [run] with a settle time. Null: no settling.
  final Future<bool> Function(Duration timeout)? waitEnded;
  final void Function(String line)? log;

  final List<_Job> _waiting = <_Job>[];
  bool _busy = false;
  Timer? _wake;
  _Job? _restLogged;

  /// Jobs waiting plus the one running (or settling).
  int get pending => _waiting.length + (_busy ? 1 : 0);

  /// Time until the shared ledger frees its oldest command; null when empty.
  Duration? get nextFreeIn => ledger.nextFreeIn(clock.now());

  /// Queue [job], which writes [commands] band commands. It starts within
  /// [startBy] or is dropped as [BuzzDelivery.rejected] (never called). Once
  /// started it has [timeout] to answer (else [BuzzDelivery.unknown]); a job
  /// that ends complete or partial then holds the slot for up to [settle] for
  /// the band's ended event, while its caller already has the result. A job
  /// that throws hands the error to its caller.
  Future<BuzzDelivery> run(
    Future<BuzzDelivery> Function() job, {
    required int commands,
    required Duration timeout,
    Duration startBy = kBandQueueWait,
    Duration settle = Duration.zero,
  }) {
    final j = _Job(job, commands, timeout, settle, clock.now().add(startBy));
    if (pending > 0) {
      log?.call('Band queue: waiting for the band ($pending ahead)');
    }
    _waiting.add(j);
    j.expiry = Timer(startBy, () => _expire(j));
    _pump();
    return j.done.future;
  }

  void _expire(_Job j) {
    if (!_waiting.contains(j)) return;
    _drop(j);
    _pump();
  }

  void _drop(_Job j) {
    _waiting.remove(j);
    j.expiry?.cancel();
    if (!j.done.isCompleted) j.done.complete(BuzzDelivery.rejected);
    log?.call('Band queue: dropped a job that could not start in time');
  }

  void _pump() {
    _wake?.cancel();
    _wake = null;
    while (!_busy && _waiting.isNotEmpty) {
      final j = _waiting.first;
      final now = clock.now();
      final wait = ledger.waitFor(j.commands, now);
      if (wait > Duration.zero) {
        if (now.add(wait).isAfter(j.deadline)) {
          _drop(j);
          continue;
        }
        if (!identical(_restLogged, j)) {
          _restLogged = j;
          log?.call('Band queue: resting, ready in '
              '${(wait.inMilliseconds / 1000).ceil()} s');
        }
        _wake = Timer(wait, _pump);
        return;
      }
      _waiting.removeAt(0);
      j.expiry?.cancel();
      _busy = true;
      unawaited(_start(j));
    }
  }

  Future<void> _start(_Job j) async {
    ledger.record(j.commands, clock.now());
    BuzzDelivery? result;
    try {
      result = await j
          .run()
          .timeout(j.timeout, onTimeout: () => BuzzDelivery.unknown);
      j.done.complete(result);
    } catch (e, st) {
      j.done.completeError(e, st);
    }
    try {
      final w = waitEnded;
      if (w != null &&
          j.settle > Duration.zero &&
          (result == BuzzDelivery.complete || result == BuzzDelivery.partial)) {
        await w(j.settle);
      }
    } catch (_) {
      // No answer is the same as a timeout: the band has finished by then.
    } finally {
      _busy = false;
      _pump();
    }
  }
}
