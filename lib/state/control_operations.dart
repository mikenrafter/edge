import 'dart:async';
import 'package:flutter/foundation.dart';

class SyncPresentationState {
  final String phase;
  final bool busy, contactedBand;
  final DateTime? lastSuccess;
  final String? error;
  const SyncPresentationState({
    this.phase = 'offline',
    this.busy = false,
    this.contactedBand = false,
    this.lastSuccess,
    this.error,
  });
  String get description => switch (phase) {
    'connecting' => 'Connecting to the band…',
    'downloading' => 'Downloading recordings…',
    'deriving' => 'Calculating from recordings…',
    'completed' => 'Sync completed',
    'failed' => 'Sync failed: ${error ?? 'Please retry'}',
    _ => 'Local data refreshed. Band not contacted.',
  };
}

class SyncOperationResult {
  final bool success;
  final String? error;
  const SyncOperationResult(this.success, [this.error]);
}

/// One operation shared by every manual sync control. Retire progress after a
/// timeout so a delayed transport cannot claim success over a newer operation.
class SyncCoordinator extends ChangeNotifier {
  final Future<void> Function(void Function(String)) run;
  final bool Function() isConnected;
  final Future<void> Function() reloadLocal;
  final Duration timeout;
  SyncPresentationState presentation = const SyncPresentationState();
  Future<SyncOperationResult>? _active;
  int _generation = 0;
  bool _disposed = false;
  SyncCoordinator({
    required this.run,
    required this.isConnected,
    required this.reloadLocal,
    this.timeout = const Duration(minutes: 65),
  });
  void _publish(
    String phase, {
    bool busy = false,
    bool contacted = true,
    DateTime? success,
    String? error,
  }) {
    if (_disposed) return;
    presentation = SyncPresentationState(
      phase: phase,
      busy: busy,
      contactedBand: contacted,
      lastSuccess: success ?? presentation.lastSuccess,
      error: error,
    );
    notifyListeners();
  }

  Future<SyncOperationResult> syncNow() {
    if (_active case final active?) return active;
    final completer = Completer<SyncOperationResult>();
    _active = completer.future;
    final token = ++_generation;
    () async {
      _publish('connecting', busy: true, contacted: false);
      SyncOperationResult result;
      try {
        await run((phase) {
          if (token == _generation) _publish(phase, busy: true);
        }).timeout(timeout);
        if (token == _generation) {
          _publish('completed', success: DateTime.now());
        }
        result = const SyncOperationResult(true);
      } catch (e) {
        if (token == _generation) {
          _publish(
            'failed',
            error: '$e',
            contacted: presentation.contactedBand,
          );
        }
        result = SyncOperationResult(false, '$e');
      } finally {
        if (token == _generation) {
          ++_generation;
          _active = null;
        }
      }
      completer.complete(result);
    }();
    return completer.future;
  }

  Future<SyncOperationResult> refresh() async {
    if (_active case final active?) return active;
    if (isConnected()) return syncNow();
    try {
      await reloadLocal();
      _publish('offline', contacted: false);
      return const SyncOperationResult(true);
    } catch (e) {
      _publish('failed', contacted: false, error: '$e');
      return SyncOperationResult(false, '$e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
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
