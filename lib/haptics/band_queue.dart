// 8AC: the one queue every band haptic job goes through. A band plays one
// thing at a time and drops a command written while it plays, and the band's
// haptic motor must not be driven past 30 commands in any 2 minutes. Two alerts
// at once, a tap ack during a rule's rhythm, or the pattern probe next to a
// real alert would break one or both. So every job (a rule's rhythm, a single
// buzz, a tap ack, a preview, the ECG count buzzes) waits its turn here.
//
// A job starts when the previous one has finished (its last write landed and
// the band's "ended" event 100 came, or a bounded playback timeout) AND the
// shared [BandCommandLedger] has room to reserve its whole command count. A
// job that cannot start before its deadline (measured from when it was queued)
// is dropped as [BuzzDelivery.rejected] with nothing written, which the alert
// dispatcher reads as "give the claim back". Once a job has started, its
// transport timeout counts from the start.
//
// Lab mode (8AF): while the Device lab is open ([BandHapticQueue.beginLab]),
// lab jobs (the probes, the touch counter's buzzes) go first and every other
// job is HELD: not started, its start deadline suspended, restarted when the
// lab closes. A job already playing is never preempted.
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

/// How long a band is held after a haptic write when its ended event (100) does
/// not come: one buzz plays for about 1.05 to 1.5 s. A gen 4 band may send no
/// event 100 at all, so this bounds every hold.
const Duration kBandBuzzPlayback = Duration(milliseconds: 1500);

/// How long a timed-out job's write may stay in flight before the queue stops
/// waiting for it and goes on.
const Duration kBandWriteGrace = Duration(seconds: 3);

// How soon a job blocked only by a live reservation (the lab, another job)
// looks again; a reservation has no expiry time to wait for.
const Duration _kReservedRetry = Duration(seconds: 1);

/// Room for commands taken out of a [BandCommandLedger] before they are
/// written. Each real write turns one of them into a write stamped when it
/// happened ([take]); what is left when the owner is done goes back with
/// [release].
class BandReservation {
  BandReservation._(this._ledger, this._left);
  final BandCommandLedger _ledger;
  int _left;

  /// Commands still reserved.
  int get remaining => _left;

  /// Turn one reserved command into a write at [at]. False when none is left
  /// (released, or all used): the caller must not write.
  bool take(DateTime at) {
    if (_left <= 0) return false;
    _left--;
    _ledger._reserved--;
    _ledger._addWrite(at);
    return true;
  }

  /// Give back what was not written. Safe to call twice.
  void release() {
    _ledger._reserved -= _left;
    _left = 0;
  }
}

/// The rolling safety limit: at most [maxCommands] band haptic commands in any
/// [window]. One instance is shared by the alert queue and both lab probes, so
/// the lab and real alerts cannot exceed it together.
///
/// Two kinds of entry: WRITES (a timestamp per command actually sent, which
/// leave the window two minutes after they were written) and RESERVATIONS
/// (room held by a job or probe for commands it is about to write; they count
/// until released or written).
class BandCommandLedger {
  static const int maxCommands = 30;
  static const Duration window = Duration(minutes: 2);

  // One entry per written command, oldest first.
  final List<DateTime> _at = <DateTime>[];
  int _reserved = 0;

  void _prune(DateTime now) =>
      _at.removeWhere((w) => !w.add(window).isAfter(now));

  void _addWrite(DateTime at) {
    _at.add(at);
    _at.sort();
  }

  /// Count [n] commands written at [at], with no reservation.
  void record(int n, DateTime at) {
    for (var i = 0; i < n; i++) {
      _addWrite(at);
    }
  }

  /// Hold room for [n] commands, all or nothing: null when writes and live
  /// reservations in the window plus [n] would pass [maxCommands].
  BandReservation? reserve(int n, DateTime at) {
    _prune(at);
    if (n < 0 || _at.length + _reserved + n > maxCommands) return null;
    _reserved += n;
    return BandReservation._(this, n);
  }

  /// Commands that may still be reserved or sent at [now], never below 0.
  int commandsLeft(DateTime now) {
    _prune(now);
    return (maxCommands - _at.length - _reserved).clamp(0, maxCommands);
  }

  /// Time until the oldest written command leaves the window; null when no
  /// write is in it.
  Duration? nextFreeIn(DateTime now) {
    _prune(now);
    if (_at.isEmpty) return null;
    return _at.first.add(window).difference(now);
  }

  /// How long until [n] more commands fit (zero when they fit now). Throws
  /// [ArgumentError] for more than [maxCommands]: such a job never fits and
  /// must be rejected, not made to wait for an empty window. When live
  /// reservations alone leave too little room, expiry cannot help: the answer
  /// is a short retry time.
  Duration waitFor(int n, DateTime now) {
    if (n > maxCommands) {
      throw ArgumentError.value(n, 'n', 'at most $maxCommands commands');
    }
    _prune(now);
    final over = _at.length + _reserved + n - maxCommands;
    if (over <= 0) return Duration.zero;
    if (over > _at.length) return _kReservedRetry;
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

/// What a running job writes through. Every band command goes through [write]:
/// it turns one of the job's reservations into a ledger write stamped now,
/// resets the band's ended signal, and tracks the write until it lands. Once
/// the job has timed out (or ended) the token is cancelled and [write] sends
/// nothing, so a job that was told to stop cannot play the rest of its rhythm
/// over the next one.
class BandJobToken {
  BandJobToken._(this._reservation, this._onWrite);
  final BandReservation _reservation;
  final void Function()? _onWrite;
  bool _cancelled = false;
  int _writes = 0;
  final Set<Future<void>> _inflight = <Future<void>>{};

  /// True once the job timed out or ended: no further write may be sent.
  bool get cancelled => _cancelled;

  /// Commands this job has sent so far.
  int get writes => _writes;

  /// Send one band command with [send]. False, with nothing sent, when the job
  /// is cancelled or has used its whole reservation; else what [send] says.
  Future<bool> write(Future<bool> Function() send) async {
    if (_cancelled) return false;
    if (!_reservation.take(clock.now())) return false;
    _writes++;
    _onWrite?.call();
    final f = send();
    final tracked = f.then<void>((_) {}, onError: (Object _) {});
    _inflight.add(tracked);
    try {
      return await f;
    } finally {
      _inflight.remove(tracked);
    }
  }

  Future<void> _landed(Duration grace) async {
    if (_inflight.isEmpty) return;
    await Future.wait(_inflight.toList())
        .timeout(grace, onTimeout: () => <void>[]);
  }
}

/// What the alert dispatcher hands the queue (through the zone, see
/// [kBandHoldKey]) so a job held by the lab does not run out the dispatcher's
/// own delivery deadline: [onHold] pauses it, [onRelease] restarts it, and
/// [isStale] says whether the alert has outlived its rule while it waited.
class BandHold {
  BandHold({this.onHold, this.onRelease, this.isStale});
  void Function()? onHold;
  void Function()? onRelease;
  bool Function()? isStale;
}

/// Zone key under which a [BandHold] travels from the dispatcher to
/// [BandHapticQueue.run].
const Symbol kBandHoldKey = #openstrapBandHold;

/// Zone key marking work whose band jobs are lab jobs.
const Symbol kBandLabKey = #openstrapBandLab;

class _Job {
  _Job(this.run, this.commands, this.timeout, this.settle, this.startBy,
      this.deadline,
      {this.lab = false, this.hold});
  final Future<BuzzDelivery> Function(BandJobToken job) run;
  final int commands;

  /// Null: no timeout (a lab probe waits on the wearer).
  final Duration? timeout;
  final Duration settle;
  final Duration startBy;
  DateTime deadline;
  final bool lab;
  final BandHold? hold;

  /// True while the open lab keeps this job from starting.
  bool held = false;
  bool wasHeld = false;
  final Completer<BuzzDelivery> done = Completer<BuzzDelivery>();
  Timer? expiry;
}

class BandHapticQueue {
  BandHapticQueue({
    required this.ledger,
    this.waitEnded,
    this.onWrite,
    this.log,
  });

  final BandCommandLedger ledger;

  /// Waits for the band's ended event; used to hold the slot after a job that
  /// asked to [run] with a settle time. Null: no settling.
  final Future<bool> Function(Duration timeout)? waitEnded;

  /// Called before every write of every job: resets the ended signal so the
  /// hold waits for the event of THIS write.
  final void Function()? onWrite;
  final void Function(String line)? log;

  final List<_Job> _waiting = <_Job>[];
  bool _busy = false;
  int _labs = 0;
  Timer? _wake;
  _Job? _restLogged;

  /// Jobs waiting plus the one running (or settling).
  int get pending => _waiting.length + (_busy ? 1 : 0);

  /// Time until the shared ledger frees its oldest command; null when empty.
  Duration? get nextFreeIn => ledger.nextFreeIn(clock.now());

  /// True while the Device lab is open: only lab jobs start.
  bool get labOpen => _labs > 0;

  /// The Device lab opened. Waiting and arriving non-lab jobs are held (not
  /// started, their start deadline suspended) until [endLab]. Counted, so two
  /// overlapping lab screens do not end each other's session.
  void beginLab() {
    _labs++;
    if (_labs != 1) return;
    final held = _waiting.where((j) => !j.lab).toList();
    log?.call('Band queue: lab open, holding ${held.length} alerts');
    for (final j in held) {
      _hold(j);
    }
  }

  /// The Device lab closed (safe to call more often than [beginLab]). The jobs
  /// it held start their wait over and go on.
  void endLab() {
    if (_labs == 0) return;
    _labs--;
    if (_labs != 0) return;
    final held = _waiting.where((j) => j.held).toList();
    log?.call('Band queue: lab closed, releasing ${held.length} alerts');
    for (final j in held) {
      j.held = false;
      j.deadline = clock.now().add(j.startBy);
      j.expiry = Timer(j.startBy, () => _expire(j));
      j.hold?.onRelease?.call();
    }
    _pump();
  }

  void _hold(_Job j) {
    j.held = true;
    j.wasHeld = true;
    j.expiry?.cancel();
    j.expiry = null;
    j.hold?.onHold?.call();
  }

  /// Run [work] so that band jobs queued inside it are lab jobs.
  T asLab<T>(T Function() work) =>
      runZoned(work, zoneValues: <Object?, Object?>{kBandLabKey: true});

  /// Run [body] alone on the band as a lab job (a probe's whole play): ahead
  /// of waiting alerts, never before one already playing, no timeout, no
  /// settle (the probe paces itself) and no ledger count (the probe reserves
  /// its own commands). True when [body] ran, false when the band could not be
  /// had within [startBy].
  Future<bool> runLab(
    Future<void> Function() body, {
    Duration startBy = const Duration(minutes: 2),
  }) async {
    var ran = false;
    final r = await _enqueue(
      (_) async {
        ran = true;
        await body();
        return BuzzDelivery.complete;
      },
      commands: 0,
      timeout: null,
      startBy: startBy,
      settle: Duration.zero,
      lab: true,
    );
    return ran && r == BuzzDelivery.complete;
  }

  /// Queue [job], which writes [commands] band commands through its token. It
  /// starts within [startBy] or is dropped as [BuzzDelivery.rejected] (never
  /// called); so is a job of more than [BandCommandLedger.maxCommands]. Once
  /// started it has [timeout] to answer (else [BuzzDelivery.unknown], and its
  /// token is cancelled); the band is then held until the job's last write has
  /// landed (a bounded grace) and, for a job that wrote, until the band's
  /// ended event or [settle] (default one buzz's playback), while the caller
  /// already has the result. A job that throws hands the error to its caller.
  /// A [lab] job (also any job queued inside [asLab]) goes ahead of waiting
  /// non-lab jobs; with the lab open a non-lab job is held until [endLab], and
  /// its [startBy] counts again from then.
  Future<BuzzDelivery> run(
    Future<BuzzDelivery> Function(BandJobToken job) job, {
    required int commands,
    required Duration timeout,
    Duration startBy = kBandQueueWait,
    Duration settle = kBandBuzzPlayback,
    bool lab = false,
  }) =>
      _enqueue(job,
          commands: commands,
          timeout: timeout,
          startBy: startBy,
          settle: settle,
          lab: lab || Zone.current[kBandLabKey] == true);

  Future<BuzzDelivery> _enqueue(
    Future<BuzzDelivery> Function(BandJobToken job) job, {
    required int commands,
    required Duration? timeout,
    required Duration startBy,
    required Duration settle,
    required bool lab,
  }) {
    if (commands > BandCommandLedger.maxCommands) {
      log?.call('Band queue: dropped a job of $commands commands '
          '(the limit is ${BandCommandLedger.maxCommands})');
      return Future<BuzzDelivery>.value(BuzzDelivery.rejected);
    }
    final hold = Zone.current[kBandHoldKey];
    final j = _Job(job, commands, timeout, settle, startBy,
        clock.now().add(startBy),
        lab: lab, hold: hold is BandHold ? hold : null);
    if (pending > 0) {
      log?.call('Band queue: waiting for the band ($pending ahead)');
    }
    if (lab) {
      // Behind the lab jobs already waiting, ahead of every other job.
      var at = 0;
      while (at < _waiting.length && _waiting[at].lab) {
        at++;
      }
      _waiting.insert(at, j);
    } else {
      _waiting.add(j);
    }
    if (labOpen && !lab) {
      _hold(j);
    } else {
      j.expiry = Timer(startBy, () => _expire(j));
    }
    _pump();
    return j.done.future;
  }

  void _expire(_Job j) {
    if (!_waiting.contains(j)) return;
    _drop(j);
    _pump();
  }

  void _drop(_Job j, {String why = 'could not start in time'}) {
    _waiting.remove(j);
    j.expiry?.cancel();
    if (!j.done.isCompleted) j.done.complete(BuzzDelivery.rejected);
    log?.call('Band queue: dropped a job that $why');
  }

  void _pump() {
    _wake?.cancel();
    _wake = null;
    while (!_busy && _waiting.isNotEmpty) {
      final j = _waiting.first;
      // Lab jobs sit first; a held job at the front means the lab is open and
      // no lab job is waiting: the band stays idle for the lab.
      if (j.held) return;
      if (j.wasHeld && (j.hold?.isStale?.call() ?? false)) {
        // Held through the lab and out of date by now: the alert's own rule
        // says it is no longer worth playing.
        _drop(j, why: 'went stale while the lab was open');
        continue;
      }
      final now = clock.now();
      final room = ledger.reserve(j.commands, now);
      if (room == null) {
        final wait = ledger.waitFor(j.commands, now);
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
      unawaited(_start(j, room));
    }
  }

  Future<void> _start(_Job j, BandReservation room) async {
    final token = BandJobToken._(room, onWrite);
    BuzzDelivery? result;
    try {
      try {
        final running = (() async => await j.run(token))();
        final limit = j.timeout;
        result = limit == null
            ? await running
            : await running.timeout(
                limit,
                onTimeout: () {
                  token._cancelled = true;
                  return BuzzDelivery.unknown;
                },
              );
        j.done.complete(result);
      } catch (e, st) {
        j.done.completeError(e, st);
      }
      // The job is over, one way or another: it writes nothing more, and what
      // it reserved but did not write goes back.
      token._cancelled = true;
      room.release();
      // A write still in flight may yet make the band play; do not hand the
      // band on until it has landed (bounded).
      await token._landed(kBandWriteGrace);
      final w = waitEnded;
      if (w != null &&
          j.settle > Duration.zero &&
          (result == BuzzDelivery.complete ||
              result == BuzzDelivery.partial ||
              (result == BuzzDelivery.unknown && token.writes > 0))) {
        await w(j.settle);
      }
    } catch (_) {
      // No answer is the same as a timeout: the band has finished by then.
    } finally {
      room.release();
      _busy = false;
      _pump();
    }
  }
}
