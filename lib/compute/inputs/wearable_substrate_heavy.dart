// wearable_substrate_heavy.dart — a wearable's day substrate as a registered
// worker entry (design 02). Decoding a day's rows, rebuilding the channels and
// laying a strap's session over them is O(day samples) work; it used to run on
// the UI isolate in the per-vendor readers (colmi/garmin/oura/ultrahuman
// `*_inputs.dart`) and in canonical.dart's `withStrapSessions`.
//
// The split, in one place:
//   * UI isolate (this file, the top half): the SQL. One bounded SELECT per
//     table; the rows are handed on UNREAD (no loop over them here).
//   * worker ([wearableSubstrateHeavy], the bottom half): every loop over
//     those rows, every channel rebuild, the strap overlay, the sort.
//   * the engine receives the substrate as a typed transfer
//     ([Substrate.fromTransfer]), as it does from the prepare worker.
//
// One source per concern: the vendor files keep their public signatures
// (`colmiSubstrate`, `sparseHrSubstrate`, `ultrahumanRecords`, ...) as thin
// wrappers over [buildWearableSubstrate] / [readWearableRows], so a second copy
// of a builder cannot grow beside the worker's.
//
// The worker reads no clock and no locale. The Colmi temperature replies are
// placed in the process's local zone (`DateTime(y, m, d - n, h, m)`), exactly
// as before: an isolate shares the process zone, so the answer is the same
// one the UI isolate gave. When design 01 makes the zone a plain input this is
// where it is passed.

import 'dart:isolate';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../../ble/adapters/colmi.dart' show kColmiHistoryDays;
import '../../data/db.dart';
import '../../util/heavy.dart';
import '../../util/worker_audit.dart';
import '../../util/worker_entries.dart';
import '../../util/worker_init.dart';
import '../substrate.dart';
import 'canonical.dart'
    show columnFor, kBeatSourceBucketMs, kStrapTailSec, ownerBy;
import 'colmi_inputs.dart' show kColmiFamily;
import 'garmin_inputs.dart' show kHrCadenceSec;
import 'oura_inputs.dart' show kOuraFamily, ouraTempRows;
import 'ultrahuman_inputs.dart' show kUltrahumanFamily, ultrahumanSkinC;

/// What one [wearableSubstrateHeavy] call builds.
enum WearablePlan {
  /// The family's HR rows alone ([sparseHrSubstrate]).
  sparseHr,

  /// The ring's HR rows, empty when it was set slower than its cadence.
  colmiHr,

  /// [colmiHr] with the skin temperature of the slot each row falls in.
  colmi,

  /// HR with each record's skin temperature beside it.
  ultrahuman,

  /// HR, the nearest temperature reading, and the ring's own beats; the
  /// temperature rows alone when there is no HR.
  oura,

  /// The Colmi temperature slots, as `(slot start, slot end, centi-°C)`.
  colmiSkinTemps,

  /// The Ultrahuman records, as their fields.
  ultrahumanRecords,

  /// Only the strap overlay, over [WearableSubstrateInput.base].
  strapOnly,
}

/// What [wearableSubstrateHeavy] builds from. The row lists are the rows of the
/// bounded SELECTs in [readWearableRows], unread.
@SendableShape('carries sqflite row maps (Map<String, Object?> values, one '
    'list per table read) and a Substrate (typed-data columns and a Set of '
    'device ids); round trip in test/sendable_wearableSubstrateHeavy_test.dart')
class WearableSubstrateInput {
  const WearableSubstrateInput({
    required this.plan,
    required this.family,
    required this.deviceId,
    required this.from,
    required this.to,
    this.hr = const [],
    this.temps = const [],
    this.records = const [],
    this.beats = const [],
    this.base,
    this.strapBeats,
    this.strapHr,
    this.emptyFamily,
  });

  final WearablePlan plan;
  final String family;
  final String deviceId;
  final int from, to;

  /// `decoded_onehz` `rec_ts, hr` rows.
  final List<Map<String, Object?>> hr;

  /// Colmi: `raw_archive` `hex, anchor_ms` temperature replies. Oura:
  /// `decoded_onehz` `rec_ts, skin_temp_c` rows.
  final List<Map<String, Object?>> temps;

  /// Ultrahuman: `raw_archive` `hex` records.
  final List<Map<String, Object?>> records;

  /// Oura: `decoded_rr` `t, rr` beats.
  final List<Map<String, Object?>> beats;

  /// [WearablePlan.strapOnly]: the substrate the overlay goes over.
  final Substrate? base;

  /// The strap overlay's rows, or null for none (no workout sensor flagged on):
  /// `decoded_rr` `src, t, rr` beats and the `sessions` x `decoded_onehz`
  /// `sid, src, t, hr` seconds. Both or neither.
  final List<Map<String, Object?>>? strapBeats;
  final List<Map<String, Object?>>? strapHr;

  /// The family an EMPTY own day is stamped with under the overlay, so a
  /// strap's seconds alone are still the wearable's day; null to leave it.
  final String? emptyFamily;

  /// Whether there is anything to build from: no rows and no base is an empty
  /// day, answered without a worker.
  bool get hasRows =>
      hr.isNotEmpty ||
      temps.isNotEmpty ||
      records.isNotEmpty ||
      beats.isNotEmpty ||
      (base != null && !base!.isEmpty) ||
      (strapBeats?.isNotEmpty ?? false) ||
      (strapHr?.isNotEmpty ?? false);
}

/// What [wearableSubstrateHeavy] gives back: the substrate as
/// [Substrate.toJson] (adopted with [Substrate.fromTransfer]), or the plain
/// rows of [WearablePlan.colmiSkinTemps] / [WearablePlan.ultrahumanRecords].
@SendableShape('a Substrate transfer map (typed-data columns inside a '
    'Map<String, dynamic>) and plain number lists; round trip in '
    'test/sendable_wearableSubstrateHeavy_test.dart')
class WearableSubstrateResult {
  const WearableSubstrateResult({
    this.substrate,
    this.temps = const [],
    this.records = const [],
  });

  final Map<String, dynamic>? substrate;

  /// `[slot start, slot end, centi-°C]` per reading.
  final List<List<int>> temps;

  /// 14 numbers per record (see [ultrahumanRecordRowHeavy]) (integers as doubles; a
  /// missing temperature stays NaN).
  final List<List<double>> records;
}

/// The Ultrahuman record behind one [WearableSubstrateResult.records] row.
UltrahumanRecord ultrahumanRecordOfRow(List<double> f) => UltrahumanRecord(
      tsA: f[0].toInt(),
      hr: f[1].toInt(),
      hrv: f[2].toInt(),
      spo2: f[3].toInt(),
      hrQuality: f[4].toInt(),
      tsB: f[5].toInt(),
      skinTempC: f[6],
      ambientTempC: f[7],
      tsC: f[8].toInt(),
      activity: f[9].toInt(),
      steps: f[10].toInt(),
      hrvSdnn: f[11].toInt(),
      tempQuality: f[12].toInt(),
      index: f[13].toInt(),
    );

// ---------------------------------------------------------------------------
// UI isolate: the SQL and the dispatch. No loop over a row below this line.
// ---------------------------------------------------------------------------

/// The entries read no clock, zone or locale ambiently (see the file header).
const WorkerInputs wearableWorkerInputs =
    WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en');

/// [family]'s HR rows for [deviceId] over `[from, to]`, unread.
Future<List<Map<String, Object?>>> _hrRows(
    String family, String deviceId, int from, int to) async {
  if (ana.calibrationFor(kHrCadenceSec, family) == null) return const [];
  final db = await LocalDb.instance;
  return db.rawQuery(
    'SELECT rec_ts, hr FROM decoded_onehz '
    'WHERE device_id = ? AND device_family = ? AND rec_ts >= ? '
    'AND rec_ts <= ? AND hr > 0 ORDER BY rec_ts',
    [deviceId, family, from, to],
  );
}

Future<List<Map<String, Object?>>> _colmiTempRows(
    String deviceId, int from, int to) async {
  final db = await LocalDb.instance;
  // A reply is banked on or after the day it describes and at most the
  // ring's history (kColmiHistoryDays) later: scan only those captures.
  return db.rawQuery(
    'SELECT hex, COALESCE(rec_ts * 1000, captured_at) AS anchor_ms '
    'FROM raw_archive WHERE device_id = ? '
    "AND reason = 'colmi_big_0x${kColmiBigTemperature.toRadixString(16)}' "
    'AND captured_at >= ? AND captured_at <= ?',
    [
      deviceId,
      (from - 86400) * 1000,
      (to + (kColmiHistoryDays + 1) * 86400) * 1000,
    ],
  );
}

Future<List<Map<String, Object?>>> _ultrahumanRecordRows(
    String deviceId, int from, int to) async {
  final db = await LocalDb.instance;
  return db.rawQuery(
    "SELECT hex FROM raw_archive WHERE device_id = ? "
    "AND reason = 'ultrahuman_record' AND rec_ts >= ? AND rec_ts <= ? "
    'ORDER BY rec_ts',
    [deviceId, from, to],
  );
}

Future<List<Map<String, Object?>>> _ouraBeatRows(
    String deviceId, int from, int to) async {
  final db = await LocalDb.instance;
  return db.rawQuery(
    'SELECT COALESCE(beat_ts_ms, rr_ts_ms) AS t, rr_ms AS rr FROM decoded_rr '
    'WHERE device_id = ? AND device_family = ? AND rec_ts >= ? AND rec_ts <= ? '
    'ORDER BY t, beat_index',
    [deviceId, kOuraFamily, from, to],
  );
}

/// The rows the strap overlay reads over `[from, to]`, or null with no workout
/// sensor flagged on ([LocalDb.sessionSensorSources]).
Future<
    ({
      List<Map<String, Object?>> beats,
      List<Map<String, Object?>> hr,
    })?> _strapRows(int from, int to) async {
  final ids = LocalDb.sessionSensorSources;
  if (ids.isEmpty) return null;
  final db = await LocalDb.instance;
  final sources = ids.map((s) => "'$s'").join(', ');
  final beats = await db.rawQuery(
    'SELECT source AS src, COALESCE(beat_ts_ms, rr_ts_ms) AS t, rr_ms AS rr '
    'FROM decoded_rr '
    'WHERE source IN ($sources) '
    'AND rec_ts >= ? AND rec_ts <= ? ORDER BY t, beat_index',
    [from, to],
  );
  final hr = await db.rawQuery(
    'SELECT s.id AS sid, d.source AS src, d.rec_ts AS t, d.hr AS hr '
    'FROM sessions s '
    'JOIN decoded_onehz d ON d.rec_ts >= s.start_ts '
    'AND d.rec_ts <= COALESCE(s.end_ts, s.start_ts) + $kStrapTailSec '
    'WHERE d.hr > 0 AND d.source IN ($sources) '
    'AND d.rec_ts >= ? AND d.rec_ts <= ? ORDER BY d.rec_ts',
    [from, to],
  );
  return (beats: beats, hr: hr);
}

/// The SELECTs [plan] needs for [deviceId] over `[from, to]`, as an input for
/// the worker. [strap] adds the overlay's rows; [base] is the substrate a
/// [WearablePlan.strapOnly] overlays; [emptyFamily] stamps an empty own day.
Future<WearableSubstrateInput> readWearableRows(
  WearablePlan plan,
  String family,
  String deviceId,
  int from,
  int to, {
  bool strap = false,
  Substrate? base,
  String? emptyFamily,
}) async {
  final overlay = strap ? await _strapRows(from, to) : null;
  List<Map<String, Object?>> hr = const [],
      temps = const [],
      records = const [],
      beats = const [];
  switch (plan) {
    case WearablePlan.sparseHr || WearablePlan.colmiHr:
      hr = await _hrRows(family, deviceId, from, to);
    case WearablePlan.colmi:
      hr = await _hrRows(family, deviceId, from, to);
      if (hr.isNotEmpty) temps = await _colmiTempRows(deviceId, from, to);
    case WearablePlan.ultrahuman:
      hr = await _hrRows(family, deviceId, from, to);
      if (hr.isNotEmpty) records = await _ultrahumanRecordRows(deviceId, from, to);
    case WearablePlan.oura:
      hr = await _hrRows(family, deviceId, from, to);
      if (hr.isEmpty) {
        temps = await ouraTempRows(deviceId, from, to);
      } else {
        final c = kHrCadenceSec[kOuraFamily]!;
        temps = await ouraTempRows(deviceId, from - c, to + c);
        beats = await _ouraBeatRows(deviceId, from, to);
      }
    case WearablePlan.colmiSkinTemps:
      temps = await _colmiTempRows(deviceId, from, to);
    case WearablePlan.ultrahumanRecords:
      records = await _ultrahumanRecordRows(deviceId, from, to);
    case WearablePlan.strapOnly:
      break;
  }
  return WearableSubstrateInput(
    plan: plan,
    family: family,
    deviceId: deviceId,
    from: from,
    to: to,
    hr: hr,
    temps: temps,
    records: records,
    beats: beats,
    base: base,
    strapBeats: overlay?.beats,
    strapHr: overlay?.hr,
    emptyFamily: emptyFamily,
  );
}

/// `Isolate.run(wearableSubstrateHeavy)`, audited as 'wearable substrate'.
Future<WearableSubstrateResult> _dispatchWearable(
    WearableSubstrateInput input) {
  final dispatchId = WorkerAudit.dispatched(Dispatcher.run, 'wearable substrate');
  final auditPort = WorkerAudit.auditPort; // null in production
  return Isolate.run(() {
    WorkerAudit.adopt(auditPort, dispatchId);
    return wearableSubstrateHeavy(wearableWorkerInputs, input);
  });
}

/// The own day of [plan] (and the strap overlay when [strap]) as a substrate,
/// built in a worker; no rows is an empty day, answered here.
Future<Substrate> buildWearableSubstrate(
  WearablePlan plan,
  String family,
  String deviceId,
  int from,
  int to, {
  bool strap = false,
  Substrate? base,
  String? emptyFamily,
}) async {
  final input = await readWearableRows(plan, family, deviceId, from, to,
      strap: strap, base: base, emptyFamily: emptyFamily);
  if (!input.hasRows) return base ?? _emptyDay(emptyFamily);
  final r = await _dispatchWearable(input);
  return Substrate.fromTransfer(r.substrate!);
}

/// An own day with no rows: empty, stamped with [family] when one is given.
Substrate _emptyDay(String? family) => family == null
    ? Substrate.empty
    : Substrate.fromJson(Substrate.empty.toJson()..['device_family'] = family);

/// The Colmi temperature slots over `[from, to]` (see `colmiSkinTemps`).
Future<List<(int, int, int)>> buildColmiSkinTemps(
    String deviceId, int from, int to) async {
  final input = await readWearableRows(
      WearablePlan.colmiSkinTemps, kColmiFamily, deviceId, from, to);
  if (!input.hasRows) return const [];
  final r = await _dispatchWearable(input);
  return [for (final t in r.temps) (t[0], t[1], t[2])];
}

/// The Ultrahuman records over `[from, to]` (see `ultrahumanRecords`).
Future<List<UltrahumanRecord>> buildUltrahumanRecords(
    String deviceId, int from, int to) async {
  final input = await readWearableRows(
      WearablePlan.ultrahumanRecords, kUltrahumanFamily, deviceId, from, to);
  if (!input.hasRows) return const [];
  final r = await _dispatchWearable(input);
  return [for (final f in r.records) ultrahumanRecordOfRow(f)];
}

/// The family's column of the metric table, or null: the stamp an empty own
/// day carries under the strap overlay.
String? emptyFamilyFor(String family) =>
    columnFor(family) == null ? null : family;

// ---------------------------------------------------------------------------
// Worker.
// ---------------------------------------------------------------------------

/// WORKER ENTRY: builds a wearable's day substrate (or Colmi temperature
/// slots, or Ultrahuman records) from the rows [input] carries, then lays the
/// strap's sessions and beats over it when the input has them. Runs on a
/// worker isolate, never the UI thread; the same code and the same rows as the
/// UI-isolate builders it replaced, so the output is bit-identical.
@heavy
WearableSubstrateResult wearableSubstrateHeavy(
  WorkerInputs inputs,
  WearableSubstrateInput input,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('wearableSubstrateHeavy');
  if (input.plan == WearablePlan.colmiSkinTemps) {
    return WearableSubstrateResult(temps: [
      for (final t in colmiSkinTempsHeavy(input.temps, input.from, input.to))
        [t.$1, t.$2, t.$3],
    ]);
  }
  if (input.plan == WearablePlan.ultrahumanRecords) {
    return WearableSubstrateResult(records: [
      for (final r in ultrahumanRecordsHeavy(input.records))
        ultrahumanRecordRowHeavy(r),
    ]);
  }
  var sub = switch (input.plan) {
    WearablePlan.sparseHr =>
      sparseHrSubstrateHeavy(input.family, input.deviceId, input.hr),
    WearablePlan.colmiHr => colmiHrHeavy(
        sparseHrSubstrateHeavy(input.family, input.deviceId, input.hr)),
    WearablePlan.colmi => colmiSubstrateHeavy(
        colmiHrHeavy(
            sparseHrSubstrateHeavy(input.family, input.deviceId, input.hr)),
        colmiSkinTempsHeavy(input.temps, input.from, input.to)),
    WearablePlan.ultrahuman => ultrahumanSubstrateHeavy(
        sparseHrSubstrateHeavy(input.family, input.deviceId, input.hr),
        ultrahumanRecordsHeavy(input.records)),
    WearablePlan.oura => ouraSubstrateHeavy(
        sparseHrSubstrateHeavy(input.family, input.deviceId, input.hr),
        input.deviceId,
        input.temps,
        input.beats),
    _ => input.base ?? Substrate.empty,
  };
  final strapBeats = input.strapBeats;
  final strapHr = input.strapHr;
  if (strapBeats != null && strapHr != null) {
    final family = input.emptyFamily;
    if (sub.isEmpty && family != null) {
      sub = Substrate.fromJson(sub.toJson()..['device_family'] = family);
    }
    sub = withStrapRowsHeavy(sub, strapBeats, strapHr);
  } else if (sub.isEmpty && input.emptyFamily != null) {
    sub = Substrate.fromJson(sub.toJson()..['device_family'] = input.emptyFamily);
  }
  return WearableSubstrateResult(substrate: sub.toJson());
}

/// A family's HR rows as a substrate: HR only, absent gravity (0,0,0), no
/// beats. Empty when there are none, or when the rows are not this family's.
@heavy
Substrate sparseHrSubstrateHeavy(
  String family,
  String deviceId,
  List<Map<String, Object?>> rows,
) {
  if (ana.calibrationFor(kHrCadenceSec, family) == null) {
    return Substrate.empty;
  }
  if (rows.isEmpty) return Substrate.empty;
  final n = rows.length;
  final zeros = List<double>.filled(n, 0);
  final none = List<int>.filled(n, -1);
  return Substrate(
    tsSec: [for (final r in rows) (r['rec_ts'] as num).toInt()],
    hr: [for (final r in rows) (r['hr'] as num).toInt()],
    rrTsMs: const [],
    rrMs: const [],
    ax: zeros,
    ay: zeros,
    az: zeros,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    stepCount: none,
    hrValid: none,
    bandSleepState: none,
    deviceFamily: family,
    deviceIds: {deviceId},
  );
}

/// The ring's HR rows, or empty when they sit further apart than the cadence
/// says (a ring set slower abstains rather than serve numbers scaled by the
/// wrong interval).
@heavy
Substrate colmiHrHeavy(Substrate sub) {
  if (sub.length < 2) return sub;
  final gaps = [
    for (var i = 1; i < sub.length; i++) sub.tsSec[i] - sub.tsSec[i - 1],
  ]..sort();
  return gaps[gaps.length ~/ 2] > kHrCadenceSec[kColmiFamily]!
      ? Substrate.empty
      : sub;
}

/// The Colmi temperature slots from the banked replies, oldest first.
/// Readings outside 30-42 °C are not skin on a finger: dropped.
@heavy
List<(int, int, int)> colmiSkinTempsHeavy(
  List<Map<String, Object?>> rows,
  int from,
  int to,
) {
  final out = <int, (int, int, int)>{};
  for (final r in rows) {
    final hex = r['hex'] as String;
    final bytes = [
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    if (bytes.length < kColmiBigHeaderLength + 2) continue;
    final span = bytes[kColmiBigHeaderLength + 1] * 60;
    final banked = DateTime.fromMillisecondsSinceEpoch(r['anchor_ms'] as int);
    for (final t in colmiTemperatures(bytes)) {
      if (t.celsius < 30 || t.celsius > 42) continue;
      final at = DateTime(banked.year, banked.month, banked.day - t.daysAgo,
                  0, t.minuteOfDay)
              .millisecondsSinceEpoch ~/
          1000;
      if (at + span <= from || at > to) continue;
      out[at] = (at, at + span, (t.celsius * 100).round());
    }
  }
  return out.values.toList()..sort((a, b) => a.$1.compareTo(b.$1));
}

/// The ring's HR substrate with the skin temperature of the slot each row
/// falls in beside it, in centi-°C (0 = none).
@heavy
Substrate colmiSubstrateHeavy(Substrate sub, List<(int, int, int)> temps) {
  if (sub.isEmpty) return sub;
  final skin = <int>[];
  var j = 0;
  for (final t in sub.tsSec) {
    while (j < temps.length && temps[j].$2 <= t) {
      j++;
    }
    skin.add(j < temps.length && temps[j].$1 <= t ? temps[j].$3 : 0);
  }
  return Substrate(
    tsSec: sub.tsSec,
    hr: sub.hr,
    rrTsMs: sub.rrTsMs,
    rrMs: sub.rrMs,
    ax: sub.ax,
    ay: sub.ay,
    az: sub.az,
    spo2Red: sub.spo2Red,
    spo2Ir: sub.spo2Ir,
    skinTemp: skin,
    skinContact: sub.skinContact,
    stepCount: sub.stepCount,
    hrValid: sub.hrValid,
    bandSleepState: sub.bandSleepState,
    deviceFamily: kColmiFamily,
    deviceIds: sub.deviceIds,
  );
}

/// The Ultrahuman records parsed from the banked hex, oldest first. Records
/// the ring itself marks unusable are kept: their steps and activity are real.
@heavy
List<UltrahumanRecord> ultrahumanRecordsHeavy(
    List<Map<String, Object?>> rows) {
  final out = <UltrahumanRecord>[];
  for (final r in rows) {
    final hex = r['hex'] as String;
    final rec = parseUltrahumanRecord([
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ], 0);
    if (rec != null) out.add(rec);
  }
  return out;
}

/// One record as the numbers of a [WearableSubstrateResult.records] row.
@heavy
List<double> ultrahumanRecordRowHeavy(UltrahumanRecord r) => <double>[
      r.tsA.toDouble(),
      r.hr.toDouble(),
      r.hrv.toDouble(),
      r.spo2.toDouble(),
      r.hrQuality.toDouble(),
      r.tsB.toDouble(),
      r.skinTempC,
      r.ambientTempC,
      r.tsC.toDouble(),
      r.activity.toDouble(),
      r.steps.toDouble(),
      r.hrvSdnn.toDouble(),
      r.tempQuality.toDouble(),
      r.index.toDouble(),
    ];

/// The ring's HR substrate with each record's skin temperature beside its HR,
/// in centi-°C.
@heavy
Substrate ultrahumanSubstrateHeavy(
    Substrate sub, List<UltrahumanRecord> records) {
  if (sub.isEmpty) return sub;
  final temp = {
    for (final r in records)
      if (ultrahumanSkinC(r) case final c?) r.tsA: (c * 100).round(),
  };
  return Substrate(
    tsSec: sub.tsSec,
    hr: sub.hr,
    rrTsMs: sub.rrTsMs,
    rrMs: sub.rrMs,
    ax: sub.ax,
    ay: sub.ay,
    az: sub.az,
    spo2Red: sub.spo2Red,
    spo2Ir: sub.spo2Ir,
    skinTemp: [for (final t in sub.tsSec) temp[t] ?? 0],
    skinContact: sub.skinContact,
    stepCount: sub.stepCount,
    hrValid: sub.hrValid,
    bandSleepState: sub.bandSleepState,
    deviceFamily: kUltrahumanFamily,
    deviceIds: sub.deviceIds,
  );
}

/// The ring's day: its HR substrate [sub] with the skin temperature of the
/// reading nearest each (within the cadence, centi-°C, 0 = none) and its own
/// beats; with no HR, the temperature rows alone.
@heavy
Substrate ouraSubstrateHeavy(
  Substrate sub,
  String deviceId,
  List<Map<String, Object?>> temps,
  List<Map<String, Object?>> beats,
) {
  if (sub.isEmpty) return _ouraTempSubstrateHeavy(deviceId, temps);
  final c = kHrCadenceSec[kOuraFamily]!;
  final skin = <int>[];
  var j = 0;
  for (final t in sub.tsSec) {
    while (j + 1 < temps.length &&
        ((temps[j + 1]['rec_ts'] as num) - t).abs() <=
            ((temps[j]['rec_ts'] as num) - t).abs()) {
      j++;
    }
    final near = j < temps.length &&
        ((temps[j]['rec_ts'] as num) - t).abs() <= c;
    skin.add(near ? ((temps[j]['skin_temp_c'] as num) * 100).round() : 0);
  }
  final rr = [
    for (final b in beats)
      if (plausibleRrOrNull(b['rr'] as num) case final ms?)
        ((b['t'] as num).toDouble(), ms),
  ];
  return Substrate.fromJson(sub.toJson()
    ..['skin_temp'] = skin
    ..['rr_ts_ms'] = [for (final b in rr) b.$1]
    ..['rr_ms'] = [for (final b in rr) b.$2]);
}

/// The ring's temperature rows as a substrate: skin temperature in centi-°C,
/// no HR (0), absent gravity, no beats. Empty when there are none.
@heavy
Substrate _ouraTempSubstrateHeavy(
    String deviceId, List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return Substrate.empty;
  final n = rows.length;
  final zeros = List<double>.filled(n, 0);
  final none = List<int>.filled(n, -1);
  return Substrate(
    tsSec: [for (final r in rows) (r['rec_ts'] as num).toInt()],
    hr: List<int>.filled(n, 0),
    rrTsMs: const [],
    rrMs: const [],
    ax: zeros,
    ay: zeros,
    az: zeros,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: [
      for (final r in rows) ((r['skin_temp_c'] as num) * 100).round(),
    ],
    skinContact: List<int>.filled(n, 0),
    stepCount: none,
    hrValid: none,
    bandSleepState: none,
    deviceFamily: kOuraFamily,
    deviceIds: {deviceId},
  );
}

/// The strap overlay on a wearable's day: inside each saved session a
/// flagged-on workout sensor recorded, the strap's 1 Hz HR replaces the
/// wearable's samples from its first row to its last, so the same engine reads
/// the session's strain, zones and heart-rate recovery off the strap. [rows]
/// are the `sessions` x `decoded_onehz` seconds ([_strapRows]); [beats] the
/// strap's `decoded_rr`. [sub] as it is when no session is in the rows.
///
/// Two sensors worn together are never blended: each session is the sensor's
/// that recorded most of it, and each [kBeatSourceBucketMs] of beats the
/// source's with most beats in it ([ownerBy]).
@heavy
Substrate withStrapRowsHeavy(
  Substrate sub,
  List<Map<String, Object?>> beats,
  List<Map<String, Object?>> all,
) {
  final owner = ownerBy([for (final r in all) (r['sid'], r['src'])]);
  final rows = [
    for (final r in all)
      if (r['src'] == owner[r['sid']]) r,
  ];
  // A day the wearable was off with no strap session in it stays empty.
  if (rows.isEmpty) return sub.isEmpty ? sub : _withStrapBeatsHeavy(sub, beats);
  final strap = <int, int>{};
  final spans = <Object?, (int, int)>{};
  for (final r in rows) {
    final t = (r['t'] as num).toInt();
    strap[t] = (r['hr'] as num).toInt();
    final s = spans[r['sid']];
    spans[r['sid']] = s == null ? (t, t) : (s.$1, t);
  }
  bool covered(int t) => spans.values.any((s) => t >= s.$1 && t <= s.$2);
  // Each per-second channel and its absent value on a strap's second.
  const absent = <String, Object?>{
    'ts_sec': null, 'hr': null, 'ax': 0.0, 'ay': 0.0, 'az': 0.0,
    'spo2_red': 0, 'spo2_ir': 0, 'skin_temp': 0, 'skin_contact': 0,
    'step_count': -1, 'hr_valid': -1, 'band_sleep_state': -1,
  };
  final order = [
    for (var i = 0; i < sub.length; i++)
      if (!covered(sub.tsSec[i])) (sub.tsSec[i], i),
    for (final t in strap.keys) (t, -1),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final j = sub.toJson();
  for (final MapEntry(key: k, value: none) in absent.entries) {
    final src = j[k] as List;
    if (src.length != sub.length) continue;
    j[k] = [
      for (final (t, i) in order)
        i >= 0 ? src[i] : (k == 'ts_sec' ? t : k == 'hr' ? strap[t] : none),
    ];
  }
  return _withStrapBeatsHeavy(Substrate.fromJson(j), beats);
}

/// [sub] with the strap's plausible [beats] (`src`, `t` ms, `rr` ms) merged
/// into its own, in time order (ties in arrival order), one source per
/// [kBeatSourceBucketMs]: beats of two sensors interleaved would make every
/// successive difference a cross-device one.
@heavy
Substrate _withStrapBeatsHeavy(
    Substrate sub, List<Map<String, Object?>> beats) {
  final all = [
    for (var i = 0; i < sub.rrMs.length; i++) ('', sub.rrTsMs[i], sub.rrMs[i]),
    for (final b in beats)
      if (plausibleRrOrNull(b['rr'] as num) case final rr?)
        (b['src'], (b['t'] as num).toDouble(), rr),
  ];
  if (all.length == sub.rrMs.length) return sub;
  final owner =
      ownerBy([for (final b in all) (b.$2 ~/ kBeatSourceBucketMs, b.$1)]);
  final merged = [
    for (final (i, b) in all.indexed)
      if (b.$1 == owner[b.$2 ~/ kBeatSourceBucketMs]) (i, b.$2, b.$3),
  ]..sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
  return Substrate.fromJson(sub.toJson()
    ..['rr_ts_ms'] = [for (final b in merged) b.$2]
    ..['rr_ms'] = [for (final b in merged) b.$3]);
}
