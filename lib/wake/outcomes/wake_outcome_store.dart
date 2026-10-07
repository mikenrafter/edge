// wake_outcome_store.dart — the outcome log: one JSON list under one key,
// newest first, capped. Storage is injected (prod: LocalDb.wakeMetaGet/Set with
// [kWakeOutcomesKey]) so tests need no database.

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
  Future<List<WakeOutcome>> load() => throw UnimplementedError();

  /// Replaces the outcome with the same wakeSec, never duplicates it, then
  /// keeps the newest [kWakeOutcomeCap]. A grogginess already stored for that
  /// wakeSec is NOT kept: the caller's value (possibly null) replaces it.
  Future<void> upsert(WakeOutcome outcome) => throw UnimplementedError();

  /// Sets grogginess (1..5; anything else throws ArgumentError, even for an
  /// unknown wakeSec) on the stored outcome. An unknown wakeSec is a no-op
  /// (nothing written). Re-rating replaces the earlier value.
  Future<void> rate(int wakeSec, int grogginess) => throw UnimplementedError();
}
