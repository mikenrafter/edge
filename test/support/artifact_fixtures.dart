// Shared fixtures for the artifact tests (analytics out of readers ->
// persisted artifacts, plus the intraday calorie artifact).
//
// This file references NO symbol that does not exist today, so every test file
// that imports it compiles before the implementation lands and fails for its
// own reason. Every brand-new method is reached through `dynamic`.
//
// ARTIFACT KEYS (the single vocabulary all artifact files use; also the
// `last_result.key` the screens, the warmer and the reader share):
//
//   journal_insights|90d     getJournalInsights(range: '90d')
//   weekday_effect           getWeekdayEffect()
//   beats|<night day>        BeatsData.readBeats(repo, day)  {nn, raw_beats,
//                                                             clean_fraction}
//   workout|<session id>     getWorkout(id)
//   circadian                getInsights()  (the cross-day rollup map)
//   kcal_minutes|<day>       the minute-energy payload (see p3_kcal_*.dart)
//
// ASSUMED NEW REPOSITORY SURFACE (all on LocalRepository with a harmless
// default, real on LocalRepositoryImpl):
//
//   Future<String?> artifactSignature(String key);
//       The CURRENT input signature of artifact [key], or null when none can be
//       given (unknown kind, nothing to key on). Cheap: a few indexed reads,
//       never a payload decode. Format: it STARTS WITH '${kAlgoVersion}|'.
//       A LocalRepository subclass that does not override it answers null
//       (=> "never fresh", today's behaviour).
//   Future<Map<String, dynamic>?> computeArtifact(String key);
//       The producer the warmer calls: the same map the matching reader
//       returns (so warm and open write the SAME row). Null = nothing to store
//       (e.g. kcal_minutes for a day with no raw). Throws on a failure.
//   Future<Map<String, dynamic>?> getDayCalorieCurve(String day);
//
// The fake repositories below add `artifactSignature` WITHOUT `@override` on
// purpose (the base class has no such method yet); once it exists they
// override it.

import 'dart:async';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/models.dart';

import 'as_of_recalc_fakes.dart';

export 'as_of_recalc_fakes.dart';

// ── keys ────────────────────────────────────────────────────────────────────

const artJournal = 'journal_insights|90d';
const artWeekday = 'weekday_effect';
const artCircadian = 'circadian';
String artBeats(String day) => 'beats|$day';
String artWorkout(String id) => 'workout|$id';
String artKcal(String day) => 'kcal_minutes|$day';

// ── profile ─────────────────────────────────────────────────────────────────

/// A complete calorie profile (age 34, 72 kg, 178 cm, male, resting HR 55).
const artProfileMap = <String, dynamic>{
  'age': 34,
  'weight_kg': 72.0,
  'height_cm': 178.0,
  'sex': 'm',
  'resting_hr': 55,
};

LocalRepositoryImpl artRepo({Map<String, dynamic> profile = artProfileMap}) =>
    LocalRepositoryImpl(getProfileMap: () => profile);

// ── reaching the new repository API ─────────────────────────────────────────

Future<String?> artSig(Object repo, String key) async =>
    await (repo as dynamic).artifactSignature(key) as String?;

Future<Map<String, dynamic>?> artCompute(Object repo, String key) async {
  final m = await (repo as dynamic).computeArtifact(key);
  return (m as Map?)?.cast<String, dynamic>();
}

// ── time / days ─────────────────────────────────────────────────────────────

/// Long enough that two `DateTime.now().millisecondsSinceEpoch` stamps differ.
Future<void> artTick() => Future<void>.delayed(const Duration(milliseconds: 6));

/// The local day label [back] days before today.
String artDay(int back) {
  final n = DateTime.now();
  return dayLabelOf(DateTime(n.year, n.month, n.day - back));
}

// ── seeding ─────────────────────────────────────────────────────────────────

/// A `day_result` row for [day] (its `computed_at` is "now"). One readiness
/// scalar so `metric_series` has a row too.
Future<void> artPutDay(String day,
    {int version = kAlgoVersion, double readiness = 60}) {
  return LocalDb.putDayResult(
    dayId: day,
    algoVersion: version,
    payloadJson: '{}',
    windowJson: '{}',
    readiness: readiness,
    series: {'readiness': readiness},
  );
}

int _counter = 5000;

/// One decoded 1 Hz row through the real write path (so the `input_rev`
/// triggers fire). REPLACE-in-place when [ts] already exists.
Future<void> artRecord(int ts, {int hr = 62}) async {
  final c = _counter++;
  await LocalDb.insertRecord(
    RawRecord(
      counter: c,
      packetType: 47,
      hex: 'p3$c',
      capturedAt: ts * 1000,
      recTs: ts,
    ),
    Sample(
      tsEpoch: ts,
      counter: c,
      hr: hr,
      rrIntervalsMs: const [],
      ax: 0,
      ay: 0,
      az: 1,
      spo2RedRaw: 1,
      spo2IrRaw: 1,
      skinTempRaw: 3000,
    ),
  );
}

/// One decoded RR beat (touches `decoded_rr` only).
Future<void> artRr(int ts, {int beat = 0, int ms = 900}) async {
  final db = await LocalDb.instance;
  await db.execute(
    'INSERT OR REPLACE INTO decoded_rr '
    '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
    "VALUES ('', ?, ?, ?, ?, ?)",
    [ts * 1000, ts, beat, ts * 1000, ms],
  );
}

/// A `sessions` row, finished, over `[startTs, endTs]`.
Map<String, dynamic> artSession(String id, int startTs, int endTs,
        {double calories = 200, double strain = 8, int? rpe}) =>
    {
      'id': id,
      'start_ts': startTs,
      'end_ts': endTs,
      'type': 'run',
      'status': 'done',
      'calories': calories,
      'strain': strain,
      'max_hr': 170,
      'duration_min': (endTs - startTs) ~/ 60,
      'source': 'manual',
      'rpe': rpe,
      'created_at': startTs * 1000,
    };

/// Noon local of the day [back] days ago, epoch seconds.
int artNoonSec(int back) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - back, 12).millisecondsSinceEpoch ~/
      1000;
}

// ── fakes for the screens ───────────────────────────────────────────────────

/// A repository that answers [artifactSignature] from a map and remembers what
/// it was asked. A key with no entry (or a null entry) answers null.
mixin ArtifactSigs {
  final Map<String, String?> sigs = {};
  final List<String> sigAsks = [];

  // No @override: LocalRepository has no such method.
  Future<String?> artifactSignature(String key) async {
    sigAsks.add(key);
    return sigs[key];
  }
}

class ArtifactMetricRepo extends MetricRepo with ArtifactSigs {}

class ArtifactBeatsRepo extends BeatsRepo with ArtifactSigs {}

class ArtifactWellnessRepo extends WellnessRepo with ArtifactSigs {
  int weekdayCalls = 0;
  Completer<Map<String, dynamic>>? weekdayGate;
  Map<String, dynamic> weekday = const {};

  @override
  Future<Map<String, dynamic>> getWeekdayEffect(
      {String key = 'readiness'}) {
    weekdayCalls++;
    final g = weekdayGate;
    return g != null ? g.future : Future.value(weekday);
  }
}
