// wake_stores.dart — the SQLite-backed stores behind the wake orchestrator:
// the persisted run state, the decision trace, and the Smart Wake upgrade
// state. The orchestrator itself only sees the interfaces in
// wake_orchestrator.dart; this is the one file that ties it to LocalDb.

import 'dart:convert';

import '../data/day_label.dart';
import '../data/db.dart';
import 'wake_confirmation.dart';
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
  Future<List<WakeTraceEntry>> forWake(int wakeEpochSec) async =>
      _entries(await LocalDb.wakeTraceRows(wakeEpochSec,
          limit: kWakeTraceReadLimit));

  /// The newest [limit] rows across every wake, oldest first (the dev-log
  /// export; the orchestrator itself only ever reads one wake).
  Future<List<WakeTraceEntry>> recent({int limit = kWakeTraceReadLimit}) async =>
      _entries(await LocalDb.wakeTraceRecent(limit: limit));

  static List<WakeTraceEntry> _entries(List<Map<String, Object?>> rows) => [
        for (final r in rows)
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

/// A block that ended longer ago than this is over: confirming it now would put
/// a wake in an unrelated day. A block still open (no offset yet) counts while
/// it began within [kOpenWakeBlockMaxAge]: elapsed time, not a calendar day
/// (no sleep still running after 18 h is the one in progress).
const Duration kWakeBlockLookback = Duration(hours: 12);
const Duration kOpenWakeBlockMaxAge = Duration(hours: 18);

/// The SQLite-backed [WakeConfirmationStore]. The block is the newest stored
/// sleep window (`day_result.window_json`, onset/offset) that is recent enough;
/// evidence persists in `wake_evidence` keyed by the block's onset (an alarm
/// that fired while the app was dead still counts after a relaunch);
/// [confirmWake] writes `LocalDb.putWakeConfirmation` under that block's day.
class DbWakeConfirmationStore implements WakeConfirmationStore {
  DbWakeConfirmationStore({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  Future<({String dayId, int onsetSec, int? offsetSec})?> _block() async {
    final nowSec = _now().millisecondsSinceEpoch ~/ 1000;
    for (final r in await LocalDb.sleepWindowRows(4)) {
      final w = _window(r['window_json'] as String?);
      final onMs = (w?['onset_ms'] as num?)?.toInt();
      if (onMs == null) continue; // no sleep that day: look at the one before
      final offMs = (w?['offset_ms'] as num?)?.toInt();
      final onset = onMs ~/ 1000;
      final offset = offMs == null ? null : offMs ~/ 1000;
      final age = nowSec - (offset ?? onset);
      final max = (offset == null ? kOpenWakeBlockMaxAge : kWakeBlockLookback)
          .inSeconds;
      // Newest night wins: if it is stale every older one is staler.
      if (age > max) return null;
      return (dayId: r['day_id'] as String, onsetSec: onset, offsetSec: offset);
    }
    return null;
  }

  /// Both shapes `window_json` has: the Metric envelope (`{value: {...}}`; the
  /// value is the string '—' on a night with no sleep) and the bare window.
  static Map<String, Object?>? _window(String? raw) {
    try {
      final j = jsonDecode(raw ?? '{}');
      if (j is! Map) return null;
      final v = j['value'];
      if (v is Map) return v.cast<String, Object?>();
      return j['onset_ms'] != null || j['offset_ms'] != null
          ? j.cast<String, Object?>()
          : null;
    } catch (_) {
      return null;
    }
  }

  /// The day label the block in progress or just ended belongs to (the key its
  /// confirmation is stored under), or null when no block is known.
  Future<String?> blockDayId() async => (await _block())?.dayId;

  @override
  Future<int?> sleepOnsetSec() async => (await _block())?.onsetSec;

  @override
  Future<int?> confirmedWakeSec() async {
    final b = await _block();
    if (b == null) return null;
    final at = (await LocalDb.wakeConfirmation(b.dayId))?.atSec;
    // The row is per day: one from an earlier block that day is not this one's.
    return at != null && at >= b.onsetSec ? at : null;
  }

  @override
  Future<List<WakeEvidenceEvent>> evidence() async {
    final b = await _block();
    if (b == null) return const [];
    return [
      for (final r in await LocalDb.wakeEvidence(b.onsetSec))
        (
          kind: WakeEvidenceKind.values.byName(r['kind'] as String),
          sec: (r['at_sec'] as num).toInt(),
        ),
    ];
  }

  @override
  Future<void> addEvidence(WakeEvidenceKind kind, int sec) async {
    final b = await _block();
    if (b == null) return;
    await LocalDb.putWakeEvidence(
        onsetSec: b.onsetSec, kind: kind.name, atSec: sec);
  }

  @override
  Future<void> confirmWake(int sec, {required WakeEvidenceKind basis}) async {
    final b = await _block();
    await LocalDb.putWakeConfirmation(
      dayId: b?.dayId ??
          dayLabelOf(DateTime.fromMillisecondsSinceEpoch(sec * 1000)),
      atSec: sec,
      basis: _basisWire(basis),
    );
  }

  static String _basisWire(WakeEvidenceKind k) => switch (k) {
        WakeEvidenceKind.bandMovement => 'movement',
        WakeEvidenceKind.alarmFired => 'alarm_fired',
        WakeEvidenceKind.alarmAcknowledged => 'alarm_acknowledged',
        WakeEvidenceKind.naturalWake => 'natural_wake',
        // An open is never the evidence that completes it (it only pairs).
        WakeEvidenceKind.appOpened => 'app_opened',
      };
}
