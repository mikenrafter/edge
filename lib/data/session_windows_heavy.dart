// session_windows_heavy.dart — the per-session HR windows of a workout list as
// a registered worker entry (design 02). With a workout sensor flagged on, a
// session's seconds are not a SQL aggregate: they are the rows of
// `sessionWindowRows`, grouped and reduced per session, O(session seconds).
// That used to run on the UI isolate, twice per list load (once for the stats,
// once for the samples).
//
// The split:
//   * UI isolate ([groupSessionWindows], top half): ONE SELECT; the rows are
//     handed on unread.
//   * worker ([sessionWindowsHeavy]): the grouping, the window rule, the
//     stats, the sample lists.
//
// The worker cannot read LocalDb's statics (an isolate has its own, empty
// copies), so the sensor flags travel in the input.

import 'dart:isolate';

import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_entries.dart';
import '../util/worker_init.dart';
import 'db.dart';

/// The entry reads no clock, zone or locale.
const WorkerInputs sessionWindowsWorkerInputs =
    WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en');

/// What [sessionWindowsHeavy] reduces.
@SendableShape('carries sqflite row maps (Map<String, Object?>) and the '
    'sensor flags; round trip in test/sendable_sessionWindowsHeavy_test.dart')
class SessionWindowsInput {
  const SessionWindowsInput({
    required this.rows,
    required this.sensors,
    required this.wearable,
    required this.maxHrCeiling,
    required this.minHrFloor,
  });

  /// `id, source, rec_ts, hr` rows of the sessions x `decoded_onehz` join,
  /// ordered by `id, rec_ts`.
  final List<Map<String, Object?>> rows;
  final List<String> sensors;
  final String? wearable;
  final int maxHrCeiling, minHrFloor;
}

/// Per-session stats (`n, avg_hr, min_hr, max_hr`) and worn HR samples.
@SendableShape('maps of numbers and int lists; round trip in '
    'test/sendable_sessionWindowsHeavy_test.dart')
class SessionWindowsResult {
  const SessionWindowsResult({required this.stats, required this.samples});
  final Map<String, Map<String, num>> stats;
  final Map<String, List<int>> samples;
}

/// Every session in [fromTs, toTs] (epoch SECONDS) with its window's rows,
/// grouped in a worker. Sessions with no worn row are absent. One SELECT per
/// call ([LocalDb.debugSessionWindowReads]).
Future<SessionWindowsResult> groupSessionWindows(
  int fromTs,
  int toTs, {
  int maxHrCeiling = 0,
  int minHrFloor = 0,
}) async {
  LocalDb.debugSessionWindowReads++;
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    'SELECT s.id AS id, d.source AS source, d.rec_ts AS rec_ts, d.hr AS hr '
    'FROM sessions s '
    'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
    '  AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) '
    'WHERE s.start_ts >= ? AND s.start_ts <= ? '
    'ORDER BY s.id, d.rec_ts ASC',
    [fromTs, toTs],
  );
  if (rows.isEmpty) {
    return const SessionWindowsResult(stats: {}, samples: {});
  }
  final input = SessionWindowsInput(
    rows: rows,
    sensors: LocalDb.sessionSensorSources.toList(),
    wearable: LocalDb.sessionWearableSource,
    maxHrCeiling: maxHrCeiling,
    minHrFloor: minHrFloor,
  );
  final dispatchId = WorkerAudit.dispatched(Dispatcher.run, 'session windows');
  final auditPort = WorkerAudit.auditPort; // null in production
  return Isolate.run(() {
    WorkerAudit.adopt(auditPort, dispatchId);
    return sessionWindowsHeavy(sessionWindowsWorkerInputs, input);
  });
}

/// Groups [input]'s rows by session, keeps each window's rows
/// ([sessionWindowRowsFor]), and reduces them. Runs on a worker isolate, never
/// the UI thread; the same code the UI-isolate readers ran.
@heavy
SessionWindowsResult sessionWindowsHeavy(
  WorkerInputs inputs,
  SessionWindowsInput input,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('sessionWindowsHeavy');
  final by = <String, List<Map<String, Object?>>>{};
  for (final r in input.rows) {
    final id = r['id'] as String?;
    if (id != null) (by[id] ??= []).add(r);
  }
  final sensors = input.sensors.toSet();
  final stats = <String, Map<String, num>>{};
  final samples = <String, List<int>>{};
  for (final MapEntry(key: id, value: rs) in by.entries) {
    final hr = <int>[
      for (final r in sessionWindowRowsFor(rs,
          sensors: sensors, wearable: input.wearable))
        if (((r['hr'] as num?) ?? 0) > 0) (r['hr'] as num).toInt(),
    ];
    if (hr.isEmpty) continue;
    samples[id] = hr;
    final low = [
      for (final h in hr)
        if (input.minHrFloor <= 0 || h >= input.minHrFloor) h,
    ];
    final high = [
      for (final h in hr)
        if (input.maxHrCeiling <= 0 || h <= input.maxHrCeiling) h,
    ];
    stats[id] = <String, num>{
      'n': hr.length,
      'avg_hr': hr.fold<int>(0, (a, b) => a + b) / hr.length,
      'min_hr': low.isEmpty ? 0 : low.reduce((a, b) => a < b ? a : b),
      'max_hr': high.isEmpty ? 0 : high.reduce((a, b) => a > b ? a : b),
    };
  }
  return SessionWindowsResult(stats: stats, samples: samples);
}
