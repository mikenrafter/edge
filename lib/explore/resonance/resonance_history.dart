// What past sweeps concluded, kept on the device in SharedPreferences.
//
// A single sweep is never enough to suggest a rate: a suggestion needs the
// two most recent conclusive sessions to agree. A rate the user picked as
// comfortable is stored apart from any measurement and is never presented as
// one.
//
// Evidence:
//   Lehrer, Vaschillo & Vaschillo 2000, doi 10.1023/A:1009554825745
//   Shaffer & Meehan 2020, doi 10.3389/fnins.2020.570400
//
// RED-phase stub: every body throws until the implementation lands.
import 'package:flutter/foundation.dart' show immutable;

import 'resonance_analyzer.dart';

const String kResonanceHistoryKey = 'explore.resonance.history';
const String kResonancePreferredRateKey = 'explore.resonance.preferred_rate';
const int kResonanceHistoryMax = 20;

@immutable
class SweepSessionRecord {
  const SweepSessionRecord({
    required this.at,
    required this.outcome,
    required this.rateBpm,
    required this.range,
    required this.blocks,
  });

  factory SweepSessionRecord.fromJson(Map<String, dynamic> json) =>
      throw UnimplementedError();

  final DateTime at;
  final ComparisonOutcome outcome;
  final double? rateBpm;
  final ({double lo, double hi})? range;
  final List<BlockResult> blocks;

  Map<String, dynamic> toJson() => throw UnimplementedError();
}

/// A practice rate to suggest, or null. Non-null only when the two most recent
/// sessions whose outcome is tentativeRate or tiedRange agree: their rates or
/// ranges overlap, or come within 0.5 bpm of each other. Inconclusive and
/// stopped sessions in between are skipped, not compared.
///
/// Returns the midpoint of the overlap, or of the gap when they do not quite
/// touch (two single rates: their mean).
double? suggestedPracticeRate(List<SweepSessionRecord> sessionsNewestFirst) =>
    throw UnimplementedError();

class ResonanceHistoryStore {
  const ResonanceHistoryStore();

  /// Newest first, at most [kResonanceHistoryMax]. Corrupt storage reads as
  /// an empty list and never throws.
  Future<List<SweepSessionRecord>> load() => throw UnimplementedError();

  Future<void> add(SweepSessionRecord record) => throw UnimplementedError();

  Future<void> clear() => throw UnimplementedError();

  /// The rate the user chose as comfortable. Distinct from any measured
  /// suggestion.
  Future<double?> preferredRate() => throw UnimplementedError();

  /// Null clears it.
  Future<void> setPreferredRate(double? rateBpm) => throw UnimplementedError();
}
