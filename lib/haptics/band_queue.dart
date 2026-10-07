// The one queue every band haptic job goes through. A band plays one
// thing at a time and drops a command written while it plays, and we hold the
// band's haptic motor to a rolling command limit (30 in any 2 minutes unless
// the developer changed it; a precaution we chose, not a known band limit, see
// [BandCommandLedger]). Two alerts at once, a tap ack during a rule's rhythm, or
// the pattern probe next to a real alert would break one or both. So every job
// (a rule's rhythm, a single buzz, a tap ack, a preview, the ECG count buzzes)
// waits its turn here.
//
// A job starts when the previous one has finished (its last write landed and
// the band's "ended" event 100 came, or a bounded playback timeout) AND the
// shared [BandCommandLedger] has room for it. Once a job has started, its
// transport timeout counts from the start.
//
// Two kinds of job meet the limit differently:
//  * A NON-GESTURE job (an alert, a preview, breathing cues, the relay) is
//    never dropped for the limit or for waiting its turn. It waits for room, in
//    order, and plays with a gap of at least the vocabulary's minimum gap and
//    one second after the job before it.
//  * A GESTURE job (queued inside [BandHapticQueue.asGesture]) is never played
//    late. A gesture's first haptic needs room when its turn comes, else it is
//    rejected on the spot, nothing written. Once a gesture's first haptic has
//    started, all of that gesture's later haptics play even if the window runs
//    out; the ledger counts no more than the limit (see
//    [BandCommandLedger.reserveUpTo]). A gesture job that cannot start within
//    its own [BandHapticQueue.run] `startBy` is also rejected.
//
//  * An ALARM job (queued inside [BandHapticQueue.asAlarm]: ONLY the snooze's
//    re-alarm; its confirm, dismiss and cancel cues are plain jobs) is never
//    held for the limit at all. It still waits its turn for the band (one thing
//    plays at a time), but it starts without waiting for room, and EVERY
//    command it writes is counted in the ledger, also past the limit, so what
//    follows it waits for the real count. Waking the wearer outranks our own
//    precaution: a re-alarm held two minutes by the 30-in-2 rule is a wearer
//    who sleeps on.
//
// Between two jobs the band is also left the vocabulary's minimum gap after the
// last vibration ended ([BandHapticQueue.minGap]), so a second gesture job
// is not written the instant the first one stops. Lab jobs are not spaced.
//
// Lab mode: while the Device lab is open ([BandHapticQueue.beginLab]),
// lab jobs (the probes, the touch counter's buzzes) go first and every other
// job is HELD: not started, its alert deadline suspended. A gesture job still
// waiting when the lab opens is rejected (it must not play late). A job
// already playing is never preempted.
//
// No Flutter, no BLE. Time comes from package:clock, so tests drive it with
// fake_async.

import 'dart:async';

import 'package:clock/clock.dart';

import '../notify/buzz_sequence.dart';

/// How long a queued gesture or lab job may wait to START (a plain job waits as
/// long as it must). The alert dispatcher adds this to a band delivery's
/// deadline so waiting in the queue does not eat the transport time.
const Duration kBandQueueWait = Duration(seconds: 15);

/// How long a band is held after a haptic write when its ended event (100) does
/// not come: one buzz plays for about 1.05 to 1.5 s. A gen 4 band may send no
/// event 100 at all, so this bounds every hold.
const Duration kBandBuzzPlayback = Duration(milliseconds: 1500);

/// The most a band is held after a job's last write waiting for its playback
/// to end, whatever the pattern's estimated length.
const Duration kBandSettleMax = Duration(seconds: 12);

/// How long a timed-out job's write may stay in flight before the queue stops
/// waiting for it and goes on.
const Duration kBandWriteGrace = Duration(seconds: 3);

// How soon a job blocked only by a live reservation (the lab, another job)
// looks again; a reservation has no expiry time to wait for.
const Duration _kReservedRetry = Duration(seconds: 1);

// How often a job waiting for room looks again, so a limit raised meanwhile
// (a developer setting, read at every use) lets it go on promptly.
const Duration _kBudgetPoll = Duration(seconds: 1);

// The least gap left before the next job when a job had to wait for room.
const Duration _kBudgetGap = Duration(seconds: 1);

// How long the queue remembers that a gesture's first haptic started.
const Duration _kGestureMemory = Duration(minutes: 5);

/// The developer-set band command limit (per [BandCommandLedger.window]):
/// least, most and default.
const int kBandCommandLimitMin = 10;
const int kBandCommandLimitMax = 60;
const int kBandCommandLimitDefault = 30;

/// Room for commands taken out of a [BandCommandLedger] before they are
/// written. Each real write turns one of them into a write stamped when it
/// happened ([take]); what is left when the owner is done goes back with
/// [release].
class BandReservation {
  BandReservation._(this._ledger, this._left, this._held);
  final BandCommandLedger _ledger;
  int _left;

  // How many of the reserved commands are counted in the ledger. Fewer than
  // [_left] only for a gesture that is allowed past the limit.
  int _held;

  /// Commands still reserved.
  int get remaining => _left;

  /// Turn one reserved command into a write at [at]. False when none is left
  /// (released, or all used): the caller must not write.
  bool take(DateTime at) {
    if (_left <= 0) return false;
    _left--;
    if (_held > 0) {
      _held--;
      _ledger._reserved--;
      _ledger._addWrite(at);
    }
    return true;
  }

  /// Give back what was not written. Safe to call twice.
  void release() {
    _ledger._reserved -= _held;
    _held = 0;
    _left = 0;
  }
}

/// The rolling command limit: at most [limitNow] band haptic commands in any
/// [window] (30 unless the developer set another, 10 to 60). One instance is
/// shared by the alert queue and both lab probes, so the lab and real alerts
/// cannot exceed it together.
///
/// Why a limit at all. No published report or teardown shows a WHOOP motor
/// damaged by vibration commands. General motor literature: linear resonant
/// actuators (likely the 5.0/MG) wear mainly through the spring, which is
/// designed below fatigue; the documented risk is overdrive beyond the
/// datasheet, and resonance drifts with age (Precision Microdrives LRA; TI
/// SLOA207). Brushed ERM motors (possibly the 4.0) wear their brushes and heat
/// under continuous running, about 100,000 cycles typical (Precision
/// Microdrives). The 30 per 2 minutes default is our own precaution, not a
/// WHOOP figure; battery drain is the known cost.
///   https://www.precisionmicrodrives.com/product-catalogue/linear-resonant-actuator
///   https://ti.com/lit/pdf/sloa207
///   https://www.precisionmicrodrives.com/?p=1190
///   https://support.whoop.com/hc/en-us/articles/4407117388955-Haptic-Alarm-Overview
///
/// The limit never holds back an ALARM job (the snooze's re-alarm only,
/// [BandHapticQueue.asAlarm]): waking the user outranks our own precaution. Its
/// commands are all counted, past the limit if need be (through [reserveUpTo]):
/// the ledger holds the real number of writes in the window, so an ordinary job
/// that follows waits for the real count rather than running on top of an
/// uncounted alarm. [commandsLeft] never reads below zero.
///
/// Two kinds of entry: WRITES (a timestamp per command actually sent, which
/// leave the window two minutes after they were written) and RESERVATIONS
/// (room held by a job or probe for commands it is about to write; they count
/// until released or written).
class BandCommandLedger {
  /// [limit] is the developer-set limit, read at every use and clamped to
  /// [kBandCommandLimitMin]..[kBandCommandLimitMax]; null is the default.
  BandCommandLedger({this.limit});
  final int Function()? limit;

  /// The default limit (what [limitNow] is with no setting).
  static const int maxCommands = kBandCommandLimitDefault;
  static const Duration window = Duration(minutes: 2);

  /// The limit in force now, within [kBandCommandLimitMin]..
  /// [kBandCommandLimitMax].
  int get limitNow => (limit?.call() ?? kBandCommandLimitDefault)
      .clamp(kBandCommandLimitMin, kBandCommandLimitMax);

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
  /// reservations in the window plus [n] would pass [limitNow].
  BandReservation? reserve(int n, DateTime at) {
    _prune(at);
    if (n < 0 || _at.length + _reserved + n > limitNow) return null;
    _reserved += n;
    return BandReservation._(this, n, n);
  }

  /// A reservation for [n] commands that never fails, whatever the window
  /// holds. With [countAll] (an ALARM job) every one of the [n] is counted,
  /// also past [limitNow]: the ledger must say how many writes really are in
  /// the window, so that what follows waits for them. Without it (a started
  /// gesture, which must play to its end) it holds what room there is and the
  /// rest is written uncounted, so the ledger never counts more than the
  /// limit. Null only for a negative [n].
  BandReservation? reserveUpTo(int n, DateTime at, {bool countAll = false}) {
    if (n < 0) return null;
    _prune(at);
    final held = countAll || n < commandsLeft(at) ? n : commandsLeft(at);
    _reserved += held;
    return BandReservation._(this, n, held);
  }

  /// Commands that may still be reserved or sent at [now], never below 0.
  int commandsLeft(DateTime now) {
    _prune(now);
    final limit = limitNow;
    return (limit - _at.length - _reserved).clamp(0, limit);
  }

  /// Time until the oldest written command leaves the window; null when no
  /// write is in it.
  Duration? nextFreeIn(DateTime now) {
    _prune(now);
    if (_at.isEmpty) return null;
    return _at.first.add(window).difference(now);
  }

  /// How long until [n] more commands fit (zero when they fit now). Throws
  /// [ArgumentError] for more than [limitNow]: such a job never fits and
  /// must be rejected, not made to wait for an empty window. When live
  /// reservations alone leave too little room, expiry cannot help: the answer
  /// is a short retry time.
  Duration waitFor(int n, DateTime now) {
    final limit = limitNow;
    if (n > limit) {
      throw ArgumentError.value(n, 'n', 'at most $limit commands');
    }
    _prune(now);
    final over = _at.length + _reserved + n - limit;
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

/// Zone key carrying the id of the gesture whose haptics the work queues.
const Symbol kBandGestureKey = #openstrapBandGesture;

/// Zone key: the gesture in [kBandGestureKey] is already started.
const Symbol kBandGestureStartedKey = #openstrapBandGestureStarted;

/// Zone key marking work whose band jobs are alarm jobs (see
/// [BandHapticQueue.asAlarm]).
const Symbol kBandAlarmKey = #openstrapBandAlarm;

/// Zone key carrying a `bool Function()` "this job is still wanted", asked every
/// time the queue considers starting the job (see [BandHapticQueue.asWanted]).
const Symbol kBandWantedKey = #openstrapBandWanted;

/// Zone key carrying a `void Function(Future<void> over)`: told, for every job
/// queued in the zone, the future that completes when the band is free of it
/// (see [BandHapticQueue.asObserved]).
const Symbol kBandObserveKey = #openstrapBandObserve;

/// Zone key marking work that must start now or be rejected. Phase cues use it
/// so a delayed buzz cannot land in the next breathing phase.
const Symbol kBandImmediateKey = #openstrapBandImmediate;

class _Job {
  _Job(this.run, this.commands, this.timeout, this.settle, this.startBy,
      this.deadline,
      {this.lab = false,
      this.hold,
      this.wanted,
      this.gesture,
      this.exempt = false,
      this.alarm = false});
  final Future<BuzzDelivery> Function(BandJobToken job) run;
  final int commands;

  /// Null: no timeout (a lab probe waits on the wearer).
  final Duration? timeout;
  final Duration settle;
  final Duration startBy;
  DateTime deadline;
  final bool lab;
  final BandHold? hold;

  /// Asked before the job would start (also while the lab holds it): false
  /// drops it as rejected. Null: always wanted.
  final bool Function()? wanted;

  /// The gesture this job's haptic belongs to ([BandHapticQueue.asGesture]).
  final String? gesture;

  /// A gesture job whose gesture already started when it was queued.
  final bool exempt;

  /// A job of waking the wearer: never held for the command limit.
  final bool alarm;

  /// Only a lab or gesture job has a start deadline: it is dropped when it
  /// cannot start within [startBy]. Every other job waits as long as it must.
  bool get expires => lab || gesture != null;

  /// True while the open lab keeps this job from starting.
  bool held = false;
  bool wasHeld = false;

  /// True once the job found no room in the window and had to wait for it.
  bool waitedBudget = false;

  /// True while the dispatcher's own deadline is paused for this job (held by
  /// the lab, or waiting for room).
  bool paused = false;
  final Completer<BuzzDelivery> done = Completer<BuzzDelivery>();

  /// Completes when the band is free of this job: dropped, or run, settled and
  /// spaced. What [BandHapticQueue.whenIdle] waits on.
  final Completer<void> over = Completer<void>();
  Timer? expiry;
}

class BandHapticQueue {
  BandHapticQueue({
    required this.ledger,
    this.waitEnded,
    this.onWrite,
    this.log,
    this.minGap,
    this.onBusyChanged,
  });

  final BandCommandLedger ledger;

  /// Called with true when a job starts and false when the band is free of it
  /// (its playback ended and the gap after it passed): the app is playing on
  /// the band. Never throws into the queue.
  final void Function(bool busy)? onBusyChanged;

  /// A job is running or settling right now.
  bool get busy => _busy;

  void _setBusy(bool b) {
    _busy = b;
    try {
      onBusyChanged?.call(b);
    } catch (_) {}
  }

  /// How long the band is left alone after a job that wrote, once its last
  /// vibration ended, before the next job starts (the vocabulary's minimum
  /// gap, read at every job). Null or zero: none.
  final Duration Function()? minGap;

  /// Waits for the band's ended event; used to hold the slot after a job that
  /// asked to [run] with a settle time. Null: no settling.
  final Future<bool> Function(Duration timeout)? waitEnded;

  /// Called before every write of every job: resets the ended signal so the
  /// hold waits for the event of THIS write.
  final void Function()? onWrite;
  final void Function(String line)? log;

  final List<_Job> _waiting = <_Job>[];
  _Job? _running;
  bool _busy = false;
  int _labs = 0;
  Timer? _wake;
  _Job? _restLogged;

  // Gestures whose first haptic has started, with when it last had a job: the
  // rest of their haptics play whatever the window holds. Forgotten after
  // [_kGestureMemory] without a job, so the map stays small.
  final Map<String, DateTime> _startedGestures = <String, DateTime>{};

  /// Jobs waiting plus the one running (or settling).
  int get pending => _waiting.length + (_busy ? 1 : 0);

  /// Completes when every job queued BEFORE this call is over: delivered, its
  /// playback ended (the band's event 100, or the job's bounded settle) and the
  /// minimum gap after it passed; or dropped. Immediately when nothing is
  /// queued. Jobs queued later are not waited for. Bounded by the queue's own
  /// bounds (a job's transport timeout, its settle, its start deadline), except
  /// that a job held by the open lab waits for the lab.
  Future<void> whenIdle() {
    final ahead = <Future<void>>[
      for (final j in _waiting) j.over.future,
      if (_running != null) _running!.over.future,
    ];
    return ahead.isEmpty ? Future<void>.value() : Future.wait(ahead);
  }

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
      if (j.gesture != null) {
        _drop(j, why: 'could not play now (the lab opened)');
      } else {
        _hold(j);
      }
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
      if (j.expires) j.expiry = Timer(j.startBy, () => _expire(j));
      _resume(j);
    }
    _pump();
  }

  void _hold(_Job j) {
    j.held = true;
    j.wasHeld = true;
    j.expiry?.cancel();
    j.expiry = null;
    _pause(j);
  }

  // The dispatcher's own delivery deadline must not run while a job waits for
  // the lab or for room in the window; it restarts (in full) when the job goes.
  void _pause(_Job j) {
    if (j.paused) return;
    j.paused = true;
    j.hold?.onHold?.call();
  }

  void _resume(_Job j) {
    if (!j.paused) return;
    j.paused = false;
    j.hold?.onRelease?.call();
  }

  /// Run [work] so that band jobs queued inside it are lab jobs.
  T asLab<T>(T Function() work) =>
      runZoned(work, zoneValues: <Object?, Object?>{kBandLabKey: true});

  /// Run [work] so every job it queues belongs to gesture [gestureId] (any
  /// string that is the same for every haptic of one gesture and different
  /// between gestures). A gesture's haptics are never played late, and once its
  /// first one has started the rest play whatever the window holds (see the
  /// file header). The id is forgotten five minutes after the gesture's last
  /// job. With [started] the gesture counts as already started (its action
  /// has run, as for the tap ack): its haptics always play, never rejected for
  /// the window, and are counted only up to the limit.
  T asGesture<T>(String gestureId, T Function() work, {bool started = false}) =>
      runZoned(
        work,
        zoneValues: <Object?, Object?>{
          kBandGestureKey: gestureId,
          kBandGestureStartedKey: started,
        },
      );

  /// Run [work] so every job it queues is an alarm job: it waits for the band
  /// like any other, but never for room in the command window. Its commands are
  /// still counted (every write, also past the limit), so what follows it sees the
  /// cost. Waking the wearer outranks the 30-in-2-minutes precaution.
  T asAlarm<T>(T Function() work) => runZoned(
        work,
        zoneValues: <Object?, Object?>{kBandAlarmKey: true},
      );

  /// Run [work] so every job it queues is dropped (rejected, never written)
  /// when [wanted] says false by the time the queue would start it. The queue
  /// asks whenever it looks at its waiting jobs (a job ahead finished, the lab
  /// closed), so a job queued for something that has ended meanwhile never
  /// plays. [wanted] must not throw.
  T asWanted<T>(bool Function() wanted, T Function() work) => runZoned(
        work,
        zoneValues: <Object?, Object?>{kBandWantedKey: wanted},
      );

  /// Run [work] so [onQueued] is handed, for every band job it queues, the
  /// future that completes when the band is free of THAT job: delivered, its
  /// playback ended (or its settle time ran out), the gap after it passed; or
  /// dropped. Unlike [whenIdle] it waits for nothing else.
  T asObserved<T>(
          void Function(Future<void> over) onQueued, T Function() work) =>
      runZoned(
        work,
        zoneValues: <Object?, Object?>{kBandObserveKey: onQueued},
      );

  /// Run [work] so every job it queues either starts immediately or is
  /// rejected. Immediate jobs never wait behind another job, the Device lab,
  /// or the command ledger's rolling budget.
  T asImmediate<T>(T Function() work) => runZoned(
        work,
        zoneValues: <Object?, Object?>{kBandImmediateKey: true},
      );

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

  /// Queue [job], which writes [commands] band commands through its token. A
  /// job of more than the ledger's limit is dropped as [BuzzDelivery.rejected]
  /// (never called). A plain job then waits as long as it must (for the band
  /// and for room in the window). A gesture job ([asGesture]) or lab job starts
  /// within [startBy] or is dropped as rejected, and a gesture job with no room
  /// when its gesture starts is dropped at once. Once
  /// started it has [timeout] to answer (else [BuzzDelivery.unknown], and its
  /// token is cancelled); the band is then held until the job's last write has
  /// landed (a bounded grace) and, for a job that wrote, until the band's
  /// ended event or [settle] (default one buzz's playback), while the caller
  /// already has the result. A job that throws hands the error to its caller.
  /// A [lab] job (also any job queued inside [asLab]) goes ahead of waiting
  /// non-lab jobs; with the lab open a non-lab job is held until [endLab], and
  /// a held lab or gesture job's [startBy] counts again from then.
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
          lab: lab || Zone.current[kBandLabKey] == true,
          immediate: Zone.current[kBandImmediateKey] == true);

  Future<BuzzDelivery> _enqueue(
    Future<BuzzDelivery> Function(BandJobToken job) job, {
    required int commands,
    required Duration? timeout,
    required Duration startBy,
    required Duration settle,
    required bool lab,
    bool immediate = false,
  }) {
    final limit = ledger.limitNow;
    final alarm = Zone.current[kBandAlarmKey] == true && !lab;
    if (!alarm && commands > limit) {
      log?.call('Band queue: dropped a job of $commands commands '
          '(the limit is $limit)');
      return Future<BuzzDelivery>.value(BuzzDelivery.rejected);
    }
    final zoned = Zone.current[kBandGestureKey];
    final gesture = zoned is String && !lab && !alarm ? zoned : null;
    if (gesture != null && labOpen) {
      log?.call('Band queue: rejected a gesture job (the lab is open)');
      return Future<BuzzDelivery>.value(BuzzDelivery.rejected);
    }
    if (immediate &&
        !lab &&
        (pending > 0 ||
            labOpen ||
            ledger.commandsLeft(clock.now()) < commands)) {
      log?.call('Band queue: rejected a job that could not start immediately');
      return Future<BuzzDelivery>.value(BuzzDelivery.rejected);
    }
    final hold = Zone.current[kBandHoldKey];
    final wanted = Zone.current[kBandWantedKey];
    final j = _Job(job, commands, timeout, settle, startBy,
        clock.now().add(startBy),
        lab: lab,
        hold: hold is BandHold ? hold : null,
        wanted: wanted is bool Function() ? wanted : null,
        gesture: gesture,
        alarm: alarm,
        exempt: gesture != null && Zone.current[kBandGestureStartedKey] == true);
    final observe = Zone.current[kBandObserveKey];
    if (observe is void Function(Future<void>)) observe(j.over.future);
    _forgetGestures(clock.now());
    if (gesture != null && _startedGestures.containsKey(gesture)) {
      _startedGestures[gesture] = clock.now();
    }
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
    } else if (j.expires) {
      j.expiry = Timer(startBy, () => _expire(j));
    }
    _pump();
    return j.done.future;
  }

  void _forgetGestures(DateTime now) => _startedGestures
      .removeWhere((_, t) => now.difference(t) > _kGestureMemory);

  void _expire(_Job j) {
    if (!_waiting.contains(j)) return;
    _drop(j);
    _pump();
  }

  void _drop(_Job j, {String why = 'could not start in time'}) {
    _waiting.remove(j);
    j.expiry?.cancel();
    if (!j.done.isCompleted) j.done.complete(BuzzDelivery.rejected);
    if (!j.over.isCompleted) j.over.complete();
    log?.call('Band queue: dropped a job that $why');
  }

  void _pump() {
    _wake?.cancel();
    _wake = null;
    _forgetGestures(clock.now());
    var blockedPlain = false; // a plain job is waiting for room: FIFO behind it
    Duration? soonest;
    var i = 0;
    while (!_busy && i < _waiting.length) {
      final j = _waiting[i];
      if (j.wanted != null && !j.wanted!()) {
        _drop(j, why: 'was no longer wanted');
        continue;
      }
      // Lab jobs sit first; a held job means the lab is open and no lab job is
      // waiting: the band stays idle for the lab.
      if (j.held) break;
      if (j.wasHeld && (j.hold?.isStale?.call() ?? false)) {
        // Held through the lab and out of date by now: the alert's own rule
        // says it is no longer worth playing.
        _drop(j, why: 'went stale while the lab was open');
        continue;
      }
      final now = clock.now();
      if (!j.alarm && j.commands > ledger.limitNow) {
        // The limit was lowered under a waiting job: it can never fit.
        _drop(j, why: 'no longer fits the limit');
        continue;
      }
      BandReservation? room;
      if (j.alarm) {
        // Never held for room: written regardless, every write counted.
        room = ledger.reserveUpTo(j.commands, now, countAll: true);
      } else if (j.gesture != null) {
        // Never late: a gesture's first haptic needs room now, else it is
        // dropped; the rest of a started gesture plays regardless.
        final started = j.exempt || _startedGestures.containsKey(j.gesture);
        if (!started && ledger.commandsLeft(now) <= 0) {
          _drop(j, why: 'had no room when its gesture started');
          continue;
        }
        room = ledger.reserveUpTo(j.commands, now);
      } else {
        // A plain job queues behind a plain job that is waiting for room.
        if (blockedPlain && !j.lab) {
          j.waitedBudget = true; // it waits for room too, in line
          i++;
          continue;
        }
        room = ledger.reserve(j.commands, now);
        if (room == null) {
          final wait = ledger.waitFor(j.commands, now);
          if (j.expires && now.add(wait).isAfter(j.deadline)) {
            _drop(j);
            continue;
          }
          if (!identical(_restLogged, j)) {
            _restLogged = j;
            log?.call('Band queue: resting, ready in '
                '${(wait.inMilliseconds / 1000).ceil()} s');
          }
          j.waitedBudget = true;
          _pause(j);
          if (soonest == null || wait < soonest) soonest = wait;
          if (j.lab) break; // a lab job waiting for room holds everything
          blockedPlain = true;
          i++;
          continue;
        }
      }
      _waiting.removeAt(i);
      j.expiry?.cancel();
      _resume(j);
      final id = j.gesture;
      if (id != null) {
        _startedGestures[id] = now;
      }
      _setBusy(true);
      _running = j;
      unawaited(_start(j, room!));
    }
    if (!_busy && soonest != null) {
      // Look again when room frees, or in a second: a limit raised meanwhile
      // lets the job go on promptly.
      _wake = Timer(soonest < _kBudgetPoll ? soonest : _kBudgetPoll, _pump);
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
      var gap = j.lab ? Duration.zero : (minGap?.call() ?? Duration.zero);
      if (!j.lab &&
          gap < _kBudgetGap &&
          (j.waitedBudget || _waiting.any((w) => w.waitedBudget))) {
        // Jobs that had to wait for room play a second apart at least, whatever
        // the band's vocabulary says (a band with no profile has no gap).
        gap = _kBudgetGap;
      }
      if (gap > Duration.zero && token.writes > 0) {
        await Future<void>.delayed(gap);
      }
    } catch (_) {
      // No answer is the same as a timeout: the band has finished by then.
    } finally {
      room.release();
      _setBusy(false);
      _running = null;
      if (!j.over.isCompleted) j.over.complete();
      _pump();
    }
  }
}
