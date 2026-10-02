import 'dart:async';
import 'dart:io';

import '../data/db.dart';

enum DeriveJobKind { light, heavy }

/// Serializes derive work behind the capture pipeline using durable queued jobs.
///
/// While an offload is active we persist intent in `compute_jobs` and defer the
/// actual derive until capture has settled for a small window. On restart, any
/// interrupted running job is re-queued and resumed.
class DeriveScheduler {
  DeriveScheduler({
    required this.run,
    required this.log,
    required this.onChanged,
    this.lightSettle = const Duration(seconds: 8),
    this.heavySettle = const Duration(seconds: 2),
    this.workoutHoldCap = const Duration(hours: 6),
  });

  final Future<void> Function({required DeriveJobKind kind}) run;
  final void Function(String) log;
  final void Function() onChanged;
  final Duration lightSettle;
  final Duration heavySettle;

  /// Ceiling on the live-workout hold. The hold's whole justification is "a
  /// workout is minutes long and its own results are derived at the end
  /// anyway, so deferring costs nothing" — which inverts the moment the user
  /// forgets to finish the session: capture keeps landing records, every
  /// queued job stays parked, today's `day_result` is never built, and Home
  /// spends the day on "Nothing recorded for today — Sync the band" while the
  /// strap is connected and syncing fine. Past the cap the session is treated
  /// as forgotten and held work drains even though it is still live. Six
  /// hours matches `AppState._kMaxLiveWorkoutAgeMs`, the ceiling past which a
  /// live session row from a previous run is already judged "almost certainly
  /// not something the user is still in".
  final Duration workoutHoldCap;

  bool _offloadActive = false;

  /// True while a live workout is running. Held exactly like [_offloadActive].
  ///
  /// Heavy derivation spawns an isolate (roughly doubling peak heap) and hits
  /// the DB hard. Nothing used to stop that landing in the middle of a run or
  /// ride — and the existing foreground/background gate is INVERTED for this
  /// case: with the phone mounted on the bars and the screen awake the app IS
  /// foregrounded, so derives ran at their most expensive possible moment,
  /// competing with the GPS stream, the live map and the BLE drain. A workout
  /// is minutes long and its own results are derived at the end anyway, so
  /// deferring costs nothing — as long as the session actually ends; a
  /// forgotten one is bounded by [workoutHoldCap].
  bool _workoutActive = false;

  /// True once [workoutHoldCap] has elapsed on the CURRENT session's hold.
  /// Cleared on release, so the next session holds again from scratch.
  bool _workoutHoldExpired = false;
  Timer? _workoutCapTimer;

  /// The gate the drain actually checks: live workout, cap not yet blown.
  bool get _workoutHeld => _workoutActive && !_workoutHoldExpired;

  // While the app is backgrounded we must NOT run derivation: a derive pass
  // decodes the retained substrate + runs the metric compute, and doing
  // that on a short background BLE wake trips iOS's CPU watchdog
  // (cpu_resource_fatal) or memory jetsam → the app gets terminated. Capture
  // (persist + ACK) is lightweight and keeps running; the derive intent is
  // durable in compute_jobs, so it simply waits and drains on foreground
  // return. (No OS periodic scheduler backs this up — the old WorkManager
  // registration was deliberately removed, see main.dart — so on Android,
  // where the foreground service gives derivation a real budget, backgrounded
  // derives DO run; their cadence is capped by DeriveDebouncer's background
  // tier, not blocked here.) Held exactly like _offloadActive.
  bool _background = false;

  /// Manual syncs currently holding the scheduler, keyed by the id
  /// [beginManualSync] returned; the value is the [_storedSeq] seen when that
  /// sync's own derive started (null until then). More than one can exist for a
  /// moment: a run the coordinator timed out may still be unwinding when its
  /// replacement starts.
  ///
  /// A manual sync derives the data its download just stored. While it is in
  /// charge, a debounced light derive for that same data would compute it a
  /// second time, so the scheduler stands down: no timer, no drain. The queued
  /// job stays durable and is dropped only if the sync really derived what it
  /// was queued for ([endManualSync] with `absorb`).
  final Map<int, int?> _manualHolds = {};
  int _nextHold = 0;

  /// Bumped by every [markStoredData]. A hold compares it with the value at the
  /// moment its derive started: any change means data landed that derive may
  /// not have read, so its light job must survive.
  int _storedSeq = 0;
  bool get _manualHeld => _manualHolds.isNotEmpty;
  bool _running = false;
  bool _pendingLight = false;
  bool _pendingHeavy = false;
  Timer? _timer;
  bool _refreshing = false;

  Future<void> init() async {
    await LocalDb.recoverComputeJobs();
    await _refreshSnapshot();
    _arm();
  }

  bool get offloadActive => _offloadActive;
  bool get running => _running;
  bool get pendingLight => _pendingLight;
  bool get pendingHeavy => _pendingHeavy;

  Map<String, dynamic> snapshot() => {
        'offload_active': _offloadActive,
        'workout_active': _workoutActive,
        'workout_hold_expired': _workoutHoldExpired,
        'background': _background,
        'running': _running,
        'pending_light': _pendingLight,
        'pending_heavy': _pendingHeavy,
        'manual_sync_hold': _manualHeld,
      };

  /// A manual sync takes charge of derivation. Returns the handle to pass to
  /// [markManualDeriveStarted] and [endManualSync]; the caller MUST end it in a
  /// `finally`.
  int beginManualSync() {
    final id = ++_nextHold;
    _manualHolds[id] = null;
    _timer?.cancel();
    _timer = null;
    log('[derive-scheduler] manual sync in charge — holding derive work');
    onChanged();
    return id;
  }

  /// The manual sync's own derive is about to read the database.
  void markManualDeriveStarted(int hold) {
    if (_manualHolds.containsKey(hold)) _manualHolds[hold] = _storedSeq;
  }

  /// Hand derivation back. With [absorb] (the sync's derive completed) a queued
  /// light job is dropped as already done, unless more data was stored after
  /// that derive started. Without it (failed, cancelled) the job stays and runs.
  /// Safe to call twice.
  Future<void> endManualSync(int hold, {required bool absorb}) async {
    if (!_manualHolds.containsKey(hold)) return;
    final startedAt = _manualHolds.remove(hold);
    try {
      if (absorb && startedAt != null && startedAt == _storedSeq) {
        final dropped = await LocalDb.cancelQueuedLightDerive();
        if (dropped > 0) {
          log('[derive-scheduler] manual sync derived this data — '
              'dropped $dropped queued light job(s)');
        }
      }
    } catch (e) {
      log('[derive-scheduler] could not drop absorbed light job: $e');
    } finally {
      await _refreshSnapshot();
      if (!_manualHeld) {
        log('[derive-scheduler] manual sync done — derive may run');
        _arm();
      }
      onChanged();
    }
  }

  void markStoredData() {
    _storedSeq++;
    unawaited(_enqueue(type: 'derive_light', reason: 'stored_data'));
  }

  void requestHeavy() {
    unawaited(_enqueue(type: 'derive_heavy', reason: 'capture_settled'));
  }

  /// Hold derivation for the duration of a live workout (see [_workoutActive]).
  /// Queued jobs stay durable and drain the moment the session ends.
  void setWorkoutActive(bool active) {
    if (_workoutActive == active) return;
    _workoutActive = active;
    if (active) {
      _timer?.cancel();
      _timer = null;
      _workoutCapTimer?.cancel();
      _workoutCapTimer = Timer(workoutHoldCap, () {
        _workoutHoldExpired = true;
        log('[derive-scheduler] workout still live past the hold cap — '
            'treating it as forgotten; derive may run');
        onChanged();
        _arm();
      });
      log('[derive-scheduler] workout live — holding derive work');
      onChanged();
      return;
    }
    _workoutCapTimer?.cancel();
    _workoutCapTimer = null;
    _workoutHoldExpired = false;
    log('[derive-scheduler] workout ended — derive may run');
    onChanged();
    _arm();
  }

  void setOffloadActive(bool active) {
    if (_offloadActive == active) return;
    _offloadActive = active;
    if (active) {
      _timer?.cancel();
      _timer = null;
      log('[derive-scheduler] capture active — holding derive work');
      onChanged();
      return;
    }
    log('[derive-scheduler] capture settled — derive may run');
    onChanged();
    _arm();
  }

  /// Foreground/background gate. While backgrounded, derivation is held (heavy
  /// compute on a background BLE wake gets the app killed by the OS). Queued jobs
  /// stay durable and drain when we come back to the foreground.
  void setBackground(bool background) {
    // Only defer derivation on iOS. Android has a foreground service, so we have OS budget.
    final effectiveBackground = Platform.isIOS ? background : false;
    if (_background == effectiveBackground) return;
    _background = effectiveBackground;
    if (_background) {
      _timer?.cancel();
      _timer = null;
      log('[derive-scheduler] backgrounded — deferring derive to foreground');
      onChanged();
      return;
    }
    log('[derive-scheduler] foregrounded — draining deferred derive work');
    onChanged();
    _arm();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _workoutCapTimer?.cancel();
    _workoutCapTimer = null;
  }

  Future<void> _enqueue({
    required String type,
    required String reason,
  }) async {
    // Called unawaited: a database error here is logged, never an uncaught
    // async error. The intent is lost only if the write itself failed, and the
    // next stored-data tick enqueues again.
    try {
      await LocalDb.enqueueDeriveJob(type: type, reason: reason);
    } catch (e) {
      log('[derive-scheduler] could not queue $type: $e');
      return;
    }
    await _refreshSnapshot();
    _arm();
  }

  void _arm() {
    if (_running || _offloadActive || _background || _workoutHeld || _manualHeld) {
      return;
    }
    if (!_pendingLight && !_pendingHeavy) {
      unawaited(_refreshSnapshot());
      return;
    }
    _timer?.cancel();
    _timer = Timer(_pendingHeavy ? heavySettle : lightSettle, () {
      unawaited(_drain());
    });
    onChanged();
  }

  Future<void> _drain() async {
    if (_running || _offloadActive || _background || _workoutHeld || _manualHeld) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    final Map<String, dynamic>? job;
    try {
      job = await LocalDb.takeNextComputeJob();
    } catch (e) {
      log('[derive-scheduler] could not take the next job: $e');
      return;
    }
    if (job == null) {
      await _refreshSnapshot();
      return;
    }
    final id = job['id']?.toString();
    // RE-CHECK THE GATES AFTER ACQUISITION. The checks above happened before a
    // DB round-trip, and a workout can start (or an offload/background flip can
    // land) inside it — at which point running the pass is exactly what the
    // gate exists to prevent. The job is already marked `running` by
    // takeNextComputeJob, so hand it back rather than leaving it claimed.
    if (_offloadActive || _background || _workoutHeld || _manualHeld) {
      if (id != null && id.isNotEmpty) {
        await LocalDb.requeueComputeJob(id);
      }
      await _refreshSnapshot();
      return;
    }
    final kind = _parseKind(job['type']?.toString());
    _running = true;
    await _refreshSnapshot();
    log('[derive-scheduler] running ${kind == DeriveJobKind.heavy ? "heavy" : "light"} pass');
    try {
      await run(kind: kind);
      if (id != null && id.isNotEmpty) {
        await LocalDb.completeComputeJob(id);
      }
    } catch (e) {
      // _drain runs unawaited from a timer: a failed pass is recorded on its
      // job and logged, not rethrown into the zone.
      log('[derive-scheduler] ${kind.name} pass failed: $e');
      if (id != null && id.isNotEmpty) {
        try {
          await LocalDb.failComputeJob(id, '$e');
        } catch (_) {}
      }
    } finally {
      _running = false;
      await _refreshSnapshot();
      if (_pendingHeavy || _pendingLight) _arm();
      onChanged();
    }
  }

  DeriveJobKind _parseKind(String? type) {
    switch (type) {
      case 'derive_heavy':
        return DeriveJobKind.heavy;
      case 'derive_light':
      default:
        return DeriveJobKind.light;
    }
  }

  Future<void> _refreshSnapshot() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final jobs = await LocalDb.computeJobs(state: 'queued', limit: 50);
      _pendingLight = jobs.any(
        (job) =>
            job['type']?.toString() == 'derive_light',
      );
      _pendingHeavy = jobs.any(
        (job) =>
            job['type']?.toString() == 'derive_heavy',
      );
    } catch (e) {
      // Keep the last known pending flags; a failed read is not "nothing queued".
      log('[derive-scheduler] could not read the job queue: $e');
    } finally {
      _refreshing = false;
      onChanged();
    }
  }
}
