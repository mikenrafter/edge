// wake_outcome_store.dart — the outcome log: one JSON list under one key,
// newest first, capped. Storage is injected (prod: LocalDb.wakeMetaGet/Set with
// [kWakeOutcomesKey]) so tests need no database.

import 'dart:convert';

import 'wake_outcome.dart';

/// `wake_meta` key.
const String kWakeOutcomesKey = 'outcomes_v1';

/// The most outcomes kept (the newest by wakeSec).
const int kWakeOutcomeCap = 120;

class WakeOutcomeStore {
  WakeOutcomeStore({required this.read, required this.write});

  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String value) write;

  /// Newest first (wakeSec descending), at most [kWakeOutcomeCap]. Missing or
  /// corrupt storage reads as empty and never throws; a corrupt entry inside
  /// an otherwise valid list is skipped.
  Future<List<WakeOutcome>> load() async {
    try {
      final raw = await read(kWakeOutcomesKey);
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final outcomes = <WakeOutcome>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        try {
          outcomes.add(WakeOutcome.fromJson(entry.cast<String, Object?>()));
        } catch (_) {
          // One corrupt outcome must not hide valid, independent outcomes.
        }
      }
      outcomes.sort((a, b) => b.wakeSec.compareTo(a.wakeSec));
      return outcomes.take(kWakeOutcomeCap).toList();
    } catch (_) {
      return [];
    }
  }

  /// Replaces the outcome with the same wakeSec, never duplicates it, then
  /// keeps the newest [kWakeOutcomeCap]. A grogginess already stored for that
  /// wakeSec is NOT kept: the caller's value (possibly null) replaces it.
  Future<void> upsert(WakeOutcome outcome) async {
    final outcomes = await load();
    outcomes.removeWhere((existing) => existing.wakeSec == outcome.wakeSec);
    outcomes.add(outcome);
    outcomes.sort((a, b) => b.wakeSec.compareTo(a.wakeSec));
    await write(
      kWakeOutcomesKey,
      jsonEncode([for (final item in outcomes.take(kWakeOutcomeCap)) item.toJson()]),
    );
  }

  /// Sets grogginess (1..5; anything else throws ArgumentError, even for an
  /// unknown wakeSec) on the stored outcome. An unknown wakeSec is a no-op
  /// (nothing written). Re-rating replaces the earlier value.
  Future<void> rate(int wakeSec, int grogginess) async {
    if (grogginess < 1 || grogginess > 5) {
      throw ArgumentError.value(grogginess, 'grogginess', 'must be from 1 to 5');
    }
    final outcomes = await load();
    final index = outcomes.indexWhere((outcome) => outcome.wakeSec == wakeSec);
    if (index < 0) return;
    final outcome = outcomes[index];
    outcomes[index] = WakeOutcome(
      wakeSec: outcome.wakeSec,
      firedBy: outcome.firedBy,
      firedAtSec: outcome.firedAtSec,
      stageAtFire: outcome.stageAtFire,
      stageAgeSec: outcome.stageAgeSec,
      delivered: outcome.delivered,
      latencySec: outcome.latencySec,
      grogginess: grogginess,
      minutesBeforeT: outcome.minutesBeforeT,
      exclusions: outcome.exclusions,
    );
    await write(
      kWakeOutcomesKey,
      jsonEncode([for (final item in outcomes) item.toJson()]),
    );
  }
}
