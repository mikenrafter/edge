// wake_stores.dart — the SQLite-backed stores behind the wake orchestrator:
// the persisted run state, the decision trace, and the Smart Wake upgrade
// state. The orchestrator itself only sees the interfaces in
// wake_orchestrator.dart; this is the one file that ties it to LocalDb.

import 'dart:convert';

import '../data/db.dart';
import 'wake_orchestrator.dart';
import 'wake_settings.dart';

/// `wake_meta` keys.
const String kWakeUpgradeKey = 'upgrade_explanation';
const String kWakeRunStateKey = 'run_state';

class DbWakeStateStore implements WakeStateStore {
  const DbWakeStateStore();

  /// Corrupt or missing state reads as absent: the orchestrator starts fresh
  /// (costing a warm-up) instead of failing a wake.
  @override
  Future<Map<String, Object?>?> load() async {
    final raw = await LocalDb.wakeMetaGet(kWakeRunStateKey);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      return j is Map ? j.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(Map<String, Object?> state) =>
      LocalDb.wakeMetaSet(kWakeRunStateKey, jsonEncode(state));
}

/// The most trace rows one read returns (the newest). A night's trace is a few
/// dozen rows; this is a ceiling so a screen that reloads on every tick stays
/// cheap.
const int kWakeTraceReadLimit = 400;

class DbWakeTraceStore implements WakeTraceStore {
  const DbWakeTraceStore();

  @override
  Future<void> append(WakeTraceEntry e) => LocalDb.appendWakeTrace(
        wakeEpochSec: e.wakeEpochSec,
        atMs: e.atMs,
        kind: e.kind,
        dataJson: jsonEncode(e.data),
      );

  @override
  Future<List<WakeTraceEntry>> forWake(int wakeEpochSec) async => [
        for (final r in await LocalDb.wakeTraceRows(wakeEpochSec,
            limit: kWakeTraceReadLimit))
          WakeTraceEntry(
            wakeEpochSec: (r['wake_epoch'] as num).toInt(),
            atMs: (r['at_ms'] as num).toInt(),
            kind: r['kind'] as String,
            data: _decode(r['data_json'] as String),
          ),
      ];

  static Map<String, Object?> _decode(String raw) {
    try {
      final j = jsonDecode(raw);
      return j is Map ? j.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }
}

Future<WakeUpgradeState> loadWakeUpgradeState() async =>
    switch (await LocalDb.wakeMetaGet(kWakeUpgradeKey)) {
      'pending' => WakeUpgradeState.pending,
      'acknowledged' => WakeUpgradeState.acknowledged,
      _ => WakeUpgradeState.none,
    };

Future<void> saveWakeUpgradeState(WakeUpgradeState state) =>
    state == WakeUpgradeState.none
        ? Future.value()
        : LocalDb.wakeMetaSet(kWakeUpgradeKey, state.name);

/// HR/accel/RR from the high-frequency collection store (`decoded_onehz`,
/// `decoded_rr`) for [from, to). The live high-rate streams (0x28/0x2B/0x33)
/// are never persisted and never read here; this is the 1 Hz row the band's
/// high-frequency prompt already lands. A NULL hr or accel is left out so the
/// stager reports `missingHr`/`missingAccel` instead of reading a zero.
Future<WakeSamples> loadWakeSamples(DateTime from, DateTime to) async {
  final fromSec = from.millisecondsSinceEpoch ~/ 1000;
  final toSec = (to.millisecondsSinceEpoch + 999) ~/ 1000;
  final rows = await LocalDb.onehzForStager(fromSec, toSec);
  final hr = <List<double>>[], accel = <List<double>>[];
  for (final r in rows) {
    final ts = (r['rec_ts'] as num).toDouble() * 1000;
    final h = r['hr'] as num?;
    if (h != null) hr.add([ts, h.toDouble()]);
    final x = r['ax'] as num?, y = r['ay'] as num?, z = r['az'] as num?;
    if (x != null && y != null && z != null) {
      accel.add([ts, x.toDouble(), y.toDouble(), z.toDouble()]);
    }
  }
  final beats = await LocalDb.rrForStager(fromSec * 1000, toSec * 1000);
  return WakeSamples(
    hr: hr,
    accel: accel,
    rr: [
      for (final b in beats)
        [(b['rr_ts_ms'] as num).toDouble(), (b['rr_ms'] as num).toDouble()],
    ],
  );
}
