import 'dart:async';
import 'package:flutter/foundation.dart';

/// The four things a manual sync does, in order.
enum SyncStepId { connect, download, calculate, done }

enum SyncStepStatus { waiting, running, done, failed, skipped }

/// Calculate's note when the derivation found nothing that changed.
const String kCalculateSkippedNote = 'Skipped — nothing new';

/// What the download has banked. Counts are for THIS sync only; the engine's
/// own report accumulates across the whole connection and cannot say that.
class SyncDownloadDetail {
  final int records, chunks;

  /// The band's own clock on the newest record committed so far.
  final DateTime? syncedThrough;

  /// The band's own clock on the newest record IT says it holds. Null until
  /// the band has said so: nothing downstream may guess a total from nothing.
  final DateTime? bandNewest;
  const SyncDownloadDetail({
    this.records = 0,
    this.chunks = 0,
    this.syncedThrough,
    this.bandNewest,
  });

  /// How much band time is still to come, or null when the band has not said
  /// or says nothing newer than we already hold. Never a percentage.
  Duration? get backlog {
    final through = syncedThrough, newest = bandNewest;
    if (through == null || newest == null) return null;
    final d = newest.difference(through);
    return d > Duration.zero ? d : null;
  }
}

/// What a finished download amounts to for the sync that asked for it.
enum DownloadVerdict {
  /// The band said its history is complete.
  complete,

  /// The session ended (time cap, stalled batch) after this sync had banked
  /// records. What arrived is real and is calculated; the rest is a later sync.
  partial,

  /// Nothing usable: a dropped link, a terminal Stuck, or no progress at all.
  failed,
}

/// Pure so the rule is stated once and tested without a band. A download that
/// stopped before completion is [DownloadVerdict.partial] only when it made
/// progress in THIS sync; a lost link or a terminal Stuck stay failures.
DownloadVerdict classifyDownload({
  required bool connected,
  required bool complete,
  required bool progressed,
  required bool stuck,
}) {
  if (!connected || stuck) return DownloadVerdict.failed;
  if (complete) return DownloadVerdict.complete;
  return progressed ? DownloadVerdict.partial : DownloadVerdict.failed;
}

/// Raised by [SyncCancelToken.throwIfCancelled] inside a run the coordinator
/// has already retired. Never user-visible: a retired run publishes nothing.
class SyncCancelled implements Exception {
  const SyncCancelled();
  @override
  String toString() => 'Sync cancelled';
}

/// Handed to each run by the coordinator. Set when the coordinator gives up on
/// the run (timeout), so the run stops between steps instead of carrying on
/// beside the retry that replaced it.
class SyncCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled) throw const SyncCancelled();
  }
}

class SyncCalculateDetail {
  /// Days finished so far and how many this pass will do. [dayTotal] is known
  /// as soon as the derivation has chosen its days (with [dayIndex] 0); both
  /// are null before that.
  final int? dayIndex, dayTotal;

  /// The day that finished most recently.
  final String? day;

  /// Another calculation holds the lock, so this one has not started.
  final bool waiting;
  const SyncCalculateDetail({
    this.dayIndex,
    this.dayTotal,
    this.day,
    this.waiting = false,
  });
}

class SyncStep {
  final SyncStepId id;
  final SyncStepStatus status;
  final DateTime? startedAt, endedAt;

  /// Plain words for a step that did not run ("Already connected").
  final String? note;
  final SyncDownloadDetail? download;
  final SyncCalculateDetail? calculate;
  const SyncStep({
    required this.id,
    this.status = SyncStepStatus.waiting,
    this.startedAt,
    this.endedAt,
    this.note,
    this.download,
    this.calculate,
  });

  /// How long the step took, or has taken so far when it is still running and
  /// [now] is given. Null for a step that never started.
  Duration? duration([DateTime? now]) {
    final start = startedAt;
    if (start == null) return null;
    final end = endedAt ?? now;
    return end?.difference(start);
  }

  SyncStep copyWith({
    SyncStepStatus? status,
    DateTime? startedAt,
    DateTime? endedAt,
    String? note,
    SyncDownloadDetail? download,
    SyncCalculateDetail? calculate,
  }) => SyncStep(
    id: id,
    status: status ?? this.status,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    note: note ?? this.note,
    download: download ?? this.download,
    calculate: calculate ?? this.calculate,
  );
}

class SyncPresentationState {
  /// 'connecting', 'downloading', 'deriving' while a sync runs; 'completed' and
  /// 'failed' when one ends; 'offline' after a refresh that never touched the
  /// band; and 'idle' for nothing happening while the band is connected (see
  /// [SyncCoordinator.view]). Both settled phases keep [lastSuccess].
  final String phase;
  final bool busy, contactedBand;
  final DateTime? lastSuccess;
  final String? error;

  /// Empty when no sync has run (offline refresh, first launch); otherwise one
  /// entry per [SyncStepId], in order.
  final List<SyncStep> steps;
  final DateTime? startedAt, finishedAt;

  /// Why the sync failed, in words a person can act on. [error] keeps the raw
  /// text for existing callers.
  final String? failureReason;

  /// The sync finished, but the band was not fully drained: more remains and
  /// another sync continues it. Not a failure.
  final bool partial;
  const SyncPresentationState({
    this.phase = 'offline',
    this.busy = false,
    this.contactedBand = false,
    this.lastSuccess,
    this.error,
    this.steps = const [],
    this.startedAt,
    this.finishedAt,
    this.failureReason,
    this.partial = false,
  });

  SyncStep step(SyncStepId id) =>
      steps.firstWhere((s) => s.id == id, orElse: () => SyncStep(id: id));
  SyncDownloadDetail? get download => step(SyncStepId.download).download;
  SyncCalculateDetail? get calculate => step(SyncStepId.calculate).calculate;

  /// Time since the sync began; frozen at its end once it has ended.
  Duration? elapsed(DateTime now) {
    final start = startedAt;
    if (start == null) return null;
    return (finishedAt ?? now).difference(start);
  }

  SyncPresentationState withSteps(List<SyncStep> next) =>
      SyncPresentationState(
        phase: phase,
        busy: busy,
        contactedBand: contactedBand,
        lastSuccess: lastSuccess,
        error: error,
        steps: next,
        startedAt: startedAt,
        finishedAt: finishedAt,
        failureReason: failureReason,
        partial: partial,
      );

  /// The same state under another settled [phase] ('offline' seen as 'idle').
  SyncPresentationState withPhase(String next) => SyncPresentationState(
        phase: next,
        busy: busy,
        contactedBand: contactedBand,
        lastSuccess: lastSuccess,
        error: error,
        steps: steps,
        startedAt: startedAt,
        finishedAt: finishedAt,
        failureReason: failureReason,
        partial: partial,
      );
}

/// A failure as a sentence, not a stack-trace label.
String syncFailureReason(Object e) {
  if (e is TimeoutException) {
    return e.message ?? 'It took too long and was stopped.';
  }
  if (e is StateError) return e.message;
  var text = '$e';
  for (final prefix in const ['Exception: ', 'Error: ']) {
    if (text.startsWith(prefix)) text = text.substring(prefix.length);
  }
  return text;
}

class SyncOperationResult {
  final bool success;
  final String? error;

  /// Succeeded, but the band still holds more than this sync fetched.
  final bool partial;
  const SyncOperationResult(this.success, [this.error, this.partial = false]);
}

/// One operation shared by every manual sync control. Retire progress after a
/// timeout so a delayed transport cannot claim success over a newer operation.
///
/// Progress arrives two ways: the [run] callback names the phase it has
/// entered, and [reportCommit] / [reportDay] / [reportWaitingForCalculation]
/// carry the live counts from the engine and the derivation. Counts are always
/// current in [presentation]; only the NOTIFICATION is throttled to one per
/// [progressInterval], so a large drain cannot become a rebuild storm.
class SyncCoordinator extends ChangeNotifier {
  final Future<void> Function(void Function(String)) run;
  final bool Function() isConnected;
  final Future<void> Function() reloadLocal;
  final Duration timeout;
  final DateTime Function() _clock;
  final void Function(String)? _log;
  final Duration progressInterval;

  /// How long a new sync waits for a run this coordinator timed out (and
  /// cancelled) to finish unwinding before it starts anyway.
  final Duration retireGrace;
  SyncPresentationState presentation = const SyncPresentationState();

  /// [presentation] as a screen should draw it. A settled 'offline' is only
  /// true while the band is away: with the link up and no sync running nothing
  /// is happening, which is 'idle'. Derived at read time so a connect or a
  /// disconnect needs no publish of its own.
  SyncPresentationState get view =>
      presentation.phase == 'offline' && isConnected()
          ? presentation.withPhase('idle')
          : presentation;
  Future<SyncOperationResult>? _active;
  int _generation = 0;
  SyncCancelToken _token = SyncCancelToken();
  Future<void>? _retiredRun;
  bool _partial = false;
  bool _disposed = false;
  DateTime? _lastNotify;
  Timer? _heldBack;
  Duration _waited = Duration.zero;
  DateTime? _waitingSince;
  SyncCoordinator({
    required this.run,
    required this.isConnected,
    required this.reloadLocal,
    this.timeout = const Duration(minutes: 65),
    DateTime Function()? clock,
    void Function(String)? log,
    this.progressInterval = const Duration(milliseconds: 250),
    this.retireGrace = const Duration(seconds: 30),
  }) : _clock = clock ?? DateTime.now,
       _log = log;

  /// Notify now, or hold the notification back so listeners hear at most one
  /// per [progressInterval] (plus one trailing, so the last update is never
  /// lost). [immediate] is for phase changes and the end of a sync.
  void _emit({bool immediate = false}) {
    if (_disposed) return;
    final now = _clock();
    final last = _lastNotify;
    if (immediate || last == null || now.difference(last) >= progressInterval) {
      _heldBack?.cancel();
      _heldBack = null;
      _lastNotify = now;
      notifyListeners();
      return;
    }
    _heldBack ??= Timer(progressInterval - now.difference(last), () {
      _heldBack = null;
      if (_disposed) return;
      _lastNotify = _clock();
      notifyListeners();
    });
  }

  void _publish(
    String phase, {
    bool busy = false,
    bool contacted = true,
    DateTime? success,
    String? error,
    List<SyncStep> steps = const [],
    DateTime? startedAt,
    DateTime? finishedAt,
    String? failureReason,
    bool partial = false,
  }) {
    if (_disposed) return;
    presentation = SyncPresentationState(
      phase: phase,
      busy: busy,
      contactedBand: contacted,
      lastSuccess: success ?? presentation.lastSuccess,
      error: error,
      steps: steps,
      startedAt: startedAt,
      finishedAt: finishedAt,
      failureReason: failureReason,
      partial: partial,
    );
    _emit(immediate: true);
  }

  static List<SyncStep> _fresh() => [
    for (final id in SyncStepId.values) SyncStep(id: id),
  ];

  /// Open step [to]. Anything before it still running is finished; anything
  /// before it that never ran is skipped, so the list never shows a gap.
  static List<SyncStep> _advance(
    List<SyncStep> from,
    SyncStepId to,
    DateTime now,
  ) => [
    for (final s in from)
      if (s.id.index < to.index && s.status == SyncStepStatus.running)
        s.copyWith(status: SyncStepStatus.done, endedAt: now)
      else if (s.id.index < to.index && s.status == SyncStepStatus.waiting)
        s.copyWith(
          status: SyncStepStatus.skipped,
          note: s.id == SyncStepId.connect ? 'Already connected' : 'Not needed',
        )
      else if (s.id == to)
        s.copyWith(
          status: SyncStepStatus.running,
          startedAt: now,
          download: to == SyncStepId.download
              ? (s.download ?? const SyncDownloadDetail())
              : null,
          calculate: to == SyncStepId.calculate
              ? (s.calculate ?? const SyncCalculateDetail())
              : null,
        )
      else
        s,
  ];

  void _enter(String phase) {
    final to = switch (phase) {
      'connecting' => SyncStepId.connect,
      'downloading' => SyncStepId.download,
      'deriving' => SyncStepId.calculate,
      _ => null,
    };
    final p = presentation;
    _publish(
      phase,
      busy: true,
      steps: to == null ? p.steps : _advance(p.steps, to, _clock()),
      startedAt: p.startedAt,
    );
  }

  /// Live record count from one committed history chunk. Call only AFTER the
  /// chunk is durable: this reports progress and must never be able to fail,
  /// delay or reorder a commit. A no-op outside a sync.
  void reportCommit({
    required int records,
    DateTime? newest,
    DateTime? bandNewest,
  }) {
    if (_active == null || _disposed) return;
    final old = presentation.download;
    if (old == null) return; // not downloading (yet, or any more)
    final through = old.syncedThrough;
    _patch(
      SyncStepId.download,
      (s) => s.copyWith(
        download: SyncDownloadDetail(
          records: old.records + records,
          chunks: old.chunks + 1,
          syncedThrough: newest != null &&
                  (through == null || newest.isAfter(through))
              ? newest
              : through,
          bandNewest: bandNewest ?? old.bandNewest,
        ),
      ),
    );
  }

  /// The token for the sync now running; set when the coordinator retires it.
  /// A run reads it once at its start and checks it between steps.
  SyncCancelToken get cancelToken => _token;

  /// The download ended before the band said it was complete, after banking
  /// records in this sync. Marks the Download step with a plain note and the
  /// sync as partial; Calculate still runs on what arrived. A no-op outside a
  /// sync.
  void reportPartialDownload() {
    if (_active == null || _disposed) return;
    _partial = true;
    _patch(
      SyncStepId.download,
      (s) => s.copyWith(
        note: 'More remains on the band — sync again to continue',
      ),
      immediate: true,
    );
  }

  /// The derivation has chosen its days: [total] of them (0 = nothing new to
  /// calculate). Shows "day 0 of N" at once instead of nothing until the first
  /// day ends, or marks Calculate skipped. A no-op outside a sync.
  void reportScope(int total) {
    if (_active == null || _disposed || presentation.calculate == null) return;
    if (total <= 0) {
      final now = _clock();
      _patch(
        SyncStepId.calculate,
        (s) => s.copyWith(
          status: SyncStepStatus.skipped,
          note: kCalculateSkippedNote,
          endedAt: now,
        ),
        immediate: true,
      );
      return;
    }
    _patch(
      SyncStepId.calculate,
      (s) => s.copyWith(
        calculate: SyncCalculateDetail(
          dayIndex: 0,
          dayTotal: total,
          waiting: s.calculate?.waiting ?? false,
        ),
      ),
    );
  }

  /// A day finished in the derivation (its `onDayDone`). A no-op outside a sync.
  void reportDay(String day, int index, int total) {
    if (_active == null || _disposed || presentation.calculate == null) return;
    _patch(
      SyncStepId.calculate,
      (s) => s.copyWith(
        calculate: SyncCalculateDetail(
          dayIndex: index,
          dayTotal: total,
          day: day,
        ),
      ),
    );
  }

  /// Another calculation holds the lock; this sync is waiting its turn.
  void reportWaitingForCalculation(bool waiting) {
    if (_active == null || _disposed) return;
    final old = presentation.calculate;
    if (old == null || old.waiting == waiting) return;
    final now = _clock();
    if (waiting) {
      _waitingSince = now;
    } else if (_waitingSince case final since?) {
      _waited += now.difference(since);
      _waitingSince = null;
    }
    _patch(
      SyncStepId.calculate,
      (s) => s.copyWith(
        calculate: SyncCalculateDetail(
          dayIndex: old.dayIndex,
          dayTotal: old.dayTotal,
          day: old.day,
          waiting: waiting,
        ),
      ),
      immediate: true,
    );
  }

  void _patch(
    SyncStepId id,
    SyncStep Function(SyncStep) change, {
    bool immediate = false,
  }) {
    presentation = presentation.withSteps([
      for (final s in presentation.steps) s.id == id ? change(s) : s,
    ]);
    _emit(immediate: immediate);
  }

  Future<SyncOperationResult> syncNow() {
    if (_active case final active?) return active;
    final completer = Completer<SyncOperationResult>();
    _active = completer.future;
    final token = ++_generation;
    final cancel = _token = SyncCancelToken();
    _waited = Duration.zero;
    _waitingSince = null;
    _partial = false;
    () async {
      _publish(
        'connecting',
        busy: true,
        contacted: false,
        steps: _fresh(),
        startedAt: _clock(),
      );
      SyncOperationResult result;
      var failed = false;
      try {
        // A run this coordinator timed out was told to stop; give it a moment
        // to do so, so the new run does not start beside it. A run that never
        // unwinds is abandoned (its progress is already ignored), not waited
        // on forever.
        if (_retiredRun case final old?) {
          await old.timeout(retireGrace, onTimeout: () {});
        }
        final running = run((phase) {
          if (token == _generation) _enter(phase);
        });
        await running.timeout(
          timeout,
          onTimeout: () {
            // Stop the run between its steps, and remember it so the next sync
            // can wait for it. Its eventual error (it will usually throw
            // SyncCancelled) belongs to nobody.
            cancel.cancel();
            late final Future<void> unwound;
            unwound = running.then<void>((_) {}, onError: (_) {}).whenComplete(() {
              if (identical(_retiredRun, unwound)) _retiredRun = null;
            });
            _retiredRun = unwound;
            throw TimeoutException(null);
          },
        );
        if (token == _generation) {
          final now = _clock();
          _publish(
            'completed',
            success: now,
            steps: _finish(now),
            startedAt: presentation.startedAt,
            finishedAt: now,
            partial: _partial,
          );
        }
        result = SyncOperationResult(true, null, _partial);
      } catch (e) {
        failed = true;
        if (token == _generation) {
          final now = _clock();
          _publish(
            'failed',
            error: '$e',
            contacted: presentation.contactedBand,
            steps: _fail(now),
            startedAt: presentation.startedAt,
            finishedAt: now,
            failureReason: syncFailureReason(e),
          );
        }
        result = SyncOperationResult(false, '$e');
      } finally {
        // Every latch this operation set, on every exit: success, throw,
        // timeout. A retired run (token already moved on) owns nothing.
        if (token == _generation) {
          ++_generation;
          _active = null;
          _heldBack?.cancel();
          _heldBack = null;
          // A log sink that throws must not strand the caller awaiting the
          // result: the latches above are already clear.
          try {
            _logTiming(failed);
          } catch (_) {}
        }
      }
      completer.complete(result);
    }();
    return completer.future;
  }

  List<SyncStep> _finish(DateTime now) => [
    for (final s in presentation.steps)
      if (s.id == SyncStepId.done)
        s.copyWith(
          status: SyncStepStatus.done,
          startedAt: now,
          endedAt: now,
          note: _partial ? 'Done (partial)' : null,
        )
      else if (s.status == SyncStepStatus.running)
        s.copyWith(status: SyncStepStatus.done, endedAt: now)
      else if (s.status == SyncStepStatus.waiting)
        s.copyWith(status: SyncStepStatus.skipped, note: 'Not needed')
      else
        s,
  ];

  List<SyncStep> _fail(DateTime now) => [
    for (final s in presentation.steps)
      if (s.status == SyncStepStatus.running)
        s.copyWith(status: SyncStepStatus.failed, endedAt: now)
      else if (s.status == SyncStepStatus.waiting)
        s.copyWith(status: SyncStepStatus.skipped, note: 'Not reached')
      else
        s,
  ];

  /// `[sync-timing] connect=…ms download=…ms (N records, M chunks) wait=…ms
  /// calculate=…ms (K days) total=…ms` — once per sync, so a slow phase can be
  /// found in a device log. A step that never ran prints `-`. `wait` is the
  /// time spent blocked on another calculation, and is taken OUT of
  /// `calculate`.
  void _logTiming(bool failed) {
    final log = _log;
    if (log == null) return;
    final p = presentation;
    String ms(Duration? d) => d == null ? '-' : '${d.inMilliseconds}ms';
    final download = p.step(SyncStepId.download);
    final calc = p.step(SyncStepId.calculate);
    final end = p.finishedAt ?? _clock();
    final waited = _waitingSince == null
        ? _waited
        : _waited + end.difference(_waitingSince!);
    final calcTime = calc.duration(end);
    final dl = download.download;
    final skipped = calc.status == SyncStepStatus.skipped &&
        calc.note == kCalculateSkippedNote;
    log(
      '[sync-timing] connect=${ms(p.step(SyncStepId.connect).duration())} '
      'download=${ms(download.duration())}'
      '${dl == null ? '' : ' (${dl.records} records, ${dl.chunks} chunks)'} '
      'wait=${ms(waited)} '
      'calculate=${skipped ? 'skipped' : ms(calcTime == null ? null : calcTime - waited)} '
      '(${calc.calculate?.dayIndex ?? 0} days) total=${ms(p.elapsed(end))}'
      '${failed ? ' FAILED' : ''}${!failed && _partial ? ' PARTIAL' : ''}',
    );
  }

  Future<SyncOperationResult> refresh() async {
    if (_active case final active?) return active;
    if (isConnected()) return syncNow();
    try {
      await reloadLocal();
      _publish('offline', contacted: false);
      return const SyncOperationResult(true);
    } catch (e) {
      _publish(
        'failed',
        contacted: false,
        error: '$e',
        failureReason: syncFailureReason(e),
      );
      return SyncOperationResult(false, '$e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _heldBack?.cancel();
    _heldBack = null;
    ++_generation;
    super.dispose();
  }
}

class ExpectedSleepSchedule {
  final int onsetMinute, wakeMinute;
  const ExpectedSleepSchedule({
    required this.onsetMinute,
    required this.wakeMinute,
  });
  Map<String, Object?> toJson() => {
    'onsetMinute': onsetMinute,
    'wakeMinute': wakeMinute,
  };
  factory ExpectedSleepSchedule.fromJson(Map<String, Object?> json) {
    final onset = (json['onsetMinute'] as num?)?.toInt();
    final wake = (json['wakeMinute'] as num?)?.toInt();
    if (onset == null ||
        wake == null ||
        onset < 0 ||
        onset >= 1440 ||
        wake < 0 ||
        wake >= 1440) {
      throw const FormatException('Invalid expected sleep schedule');
    }
    return ExpectedSleepSchedule(onsetMinute: onset, wakeMinute: wake);
  }
  (DateTime, DateTime) windowFor(DateTime localWakeDate) {
    final d = localWakeDate.toLocal();
    final wake = DateTime(
      d.year,
      d.month,
      d.day,
      wakeMinute ~/ 60,
      wakeMinute % 60,
    );
    final onset = DateTime(
      d.year,
      d.month,
      d.day - (onsetMinute >= wakeMinute ? 1 : 0),
      onsetMinute ~/ 60,
      onsetMinute % 60,
    );
    return (onset, wake);
  }
}

class SleepOperationResult {
  final bool success, metricsAvailable;
  final String? error;
  const SleepOperationResult({
    required this.success,
    this.metricsAvailable = false,
    this.error,
  });
}

/// Serialize edits including their persistence, so each accepted assertion is
/// derived before another edit replaces it. Absent measurements are success.
class SleepCoordinator extends ChangeNotifier {
  final Future<void> Function(String, int, int) persist;
  final Future<Map<String, Object?>> Function(String) derive;
  final Future<void> Function(Map<String, Object?>) saveSchedule;
  ExpectedSleepSchedule? schedule;
  Future<void> _tail = Future.value();
  int _pending = 0;
  bool _disposed = false;
  final Duration timeout;
  bool get busy => _pending > 0;
  SleepCoordinator({
    required this.persist,
    required this.derive,
    required this.saveSchedule,
    this.schedule,
    this.timeout = const Duration(minutes: 15),
  });
  (DateTime, DateTime)? expectedWindowFor(DateTime localWakeDate) =>
      schedule?.windowFor(localWakeDate);
  Future<SleepOperationResult> _queue(
    Future<SleepOperationResult> Function() work,
  ) {
    if (_disposed) {
      return Future.value(
        const SleepOperationResult(
          success: false,
          error: 'Sleep controls are closed.',
        ),
      );
    }
    final result = Completer<SleepOperationResult>();
    ++_pending;
    notifyListeners();
    void finish(SleepOperationResult value) {
      if (result.isCompleted) return;
      result.complete(value);
      --_pending;
      if (!_disposed) notifyListeners();
    }

    final timer = Timer(
      timeout,
      () => finish(
        const SleepOperationResult(
          success: false,
          error:
              'Sleep calculation timed out. Your saved times are unchanged. Retry.',
        ),
      ),
    );
    _tail = _tail.then((_) async {
      try {
        if (result.isCompleted) return;
        if (_disposed) {
          finish(
            const SleepOperationResult(
              success: false,
              error: 'Sleep controls are closed.',
            ),
          );
        } else {
          // Keep the real persistence/worker future in the queue after caller
          // timeout. A late DB write must never overwrite a subsequent edit.
          finish(await work());
        }
      } catch (e) {
        finish(SleepOperationResult(success: false, error: '$e'));
      } finally {
        timer.cancel();
      }
    });
    return result.future;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<SleepOperationResult> mutate(
    String day,
    Future<void> Function() write,
  ) => _queue(() async {
    await write();
    final metrics = await derive(day);
    return SleepOperationResult(
      success: true,
      metricsAvailable: metrics['duration_min'] != null,
    );
  });
  Future<SleepOperationResult> recalculate(String day) => _queue(() async {
    final metrics = await derive(day);
    return SleepOperationResult(
      success: true,
      metricsAvailable: metrics['duration_min'] != null,
    );
  });
  Future<SleepOperationResult> setOverride(
    String day,
    DateTime onset,
    DateTime offset, {
    bool useSchedule = false,
  }) => _queue(() async {
    final start = onset.millisecondsSinceEpoch ~/ 1000;
    final end = offset.millisecondsSinceEpoch ~/ 1000;
    if (end <= start) {
      return const SleepOperationResult(
        success: false,
        error: 'Wake time must be after the start of sleep.',
      );
    }
    await persist(day, start, end);
    if (useSchedule) {
      final localStart = onset.toLocal(), localEnd = offset.toLocal();
      final next = ExpectedSleepSchedule(
        onsetMinute: localStart.hour * 60 + localStart.minute,
        wakeMinute: localEnd.hour * 60 + localEnd.minute,
      );
      await saveSchedule(next.toJson());
      schedule = next;
    }
    final metrics = await derive(day);
    return SleepOperationResult(
      success: true,
      metricsAvailable: metrics['duration_min'] != null,
    );
  });
}
