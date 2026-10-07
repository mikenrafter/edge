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
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:shared_preferences/shared_preferences.dart';

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

  factory SweepSessionRecord.fromJson(Map<String, dynamic> json) {
    final atValue = json['at'];
    final outcomeValue = json['outcome'];
    if (atValue is! String || outcomeValue is! String) {
      throw const FormatException('Missing session fields');
    }

    final outcome = _outcomeFromName(outcomeValue);
    final at = DateTime.tryParse(atValue);
    if (outcome == null || at == null) {
      throw const FormatException('Invalid session fields');
    }

    return SweepSessionRecord(
      at: at,
      outcome: outcome,
      rateBpm: _nullableFiniteDouble(json['rateBpm']),
      range: _rangeFromJson(json['range']),
      blocks: _blocksFromJson(json['blocks']),
    );
  }

  final DateTime at;
  final ComparisonOutcome outcome;
  final double? rateBpm;
  final ({double lo, double hi})? range;
  final List<BlockResult> blocks;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'outcome': outcome.name,
        'rateBpm': rateBpm,
        'range': range == null ? null : {'lo': range!.lo, 'hi': range!.hi},
        'blocks': [for (final block in blocks) _blockToJson(block)],
      };
}

/// A practice rate to suggest, or null. Non-null only when the two most recent
/// sessions whose outcome is tentativeRate or tiedRange agree: their rates or
/// ranges overlap, or come within 0.5 bpm of each other. Inconclusive and
/// stopped sessions in between are skipped, not compared.
///
/// Returns the midpoint of the overlap, or of the gap when they do not quite
/// touch (two single rates: their mean). Null when that rate is one whose block
/// was rejected in either session: it was never measured there, so it is never
/// suggested (a session saved before the analyzer treated a rejected rate
/// inside a tie as a hole can still hold such a range).
double? suggestedPracticeRate(List<SweepSessionRecord> sessionsNewestFirst) {
  final conclusive = sessionsNewestFirst.where(_isConclusive).take(2).toList();
  if (conclusive.length != 2) return null;

  final first = _intervalFor(conclusive[0]);
  final second = _intervalFor(conclusive[1]);
  if (first == null || second == null) return null;

  final overlapLo = first.$1 > second.$1 ? first.$1 : second.$1;
  final overlapHi = first.$2 < second.$2 ? first.$2 : second.$2;
  final gap = overlapLo - overlapHi;
  if (gap > 0.5) return null;
  final suggestion = (overlapLo + overlapHi) / 2;
  for (final session in conclusive) {
    final rejectedHere = session.blocks.any((block) =>
        block.rejection != null && (block.rateBpm - suggestion).abs() < 1e-9);
    if (rejectedHere) return null;
  }
  return suggestion;
}

class ResonanceHistoryStore {
  const ResonanceHistoryStore();

  /// Newest first, at most [kResonanceHistoryMax]. Corrupt storage reads as
  /// an empty list and never throws.
  Future<List<SweepSessionRecord>> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getString(kResonanceHistoryKey);
      if (stored == null) return const [];
      final decoded = jsonDecode(stored);
      if (decoded is! List) return const [];
      final records = <SweepSessionRecord>[];
      for (final entry in decoded) {
        if (entry is! Map) return const [];
        records.add(SweepSessionRecord.fromJson(Map<String, dynamic>.from(entry)));
      }
      return records.take(kResonanceHistoryMax).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> add(SweepSessionRecord record) async {
    final records = await load();
    final retained = <SweepSessionRecord>[record, ...records]
        .take(kResonanceHistoryMax)
        .toList(growable: false);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      kResonanceHistoryKey,
      jsonEncode([for (final item in retained) item.toJson()]),
    );
  }

  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(kResonanceHistoryKey);
  }

  /// The rate the user chose as comfortable. Distinct from any measured
  /// suggestion.
  Future<double?> preferredRate() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getDouble(kResonancePreferredRateKey);
  }

  /// Null clears it.
  Future<void> setPreferredRate(double? rateBpm) async {
    final preferences = await SharedPreferences.getInstance();
    if (rateBpm == null) {
      await preferences.remove(kResonancePreferredRateKey);
      return;
    }
    await preferences.setDouble(kResonancePreferredRateKey, rateBpm);
  }
}

bool _isConclusive(SweepSessionRecord record) =>
    record.outcome == ComparisonOutcome.tentativeRate ||
    record.outcome == ComparisonOutcome.tiedRange;

(double, double)? _intervalFor(SweepSessionRecord record) {
  if (record.outcome == ComparisonOutcome.tentativeRate) {
    final rate = record.rateBpm;
    return rate != null && rate.isFinite ? (rate, rate) : null;
  }
  if (record.outcome == ComparisonOutcome.tiedRange) {
    final range = record.range;
    if (range != null && range.lo.isFinite && range.hi.isFinite &&
        range.lo <= range.hi) {
      return (range.lo, range.hi);
    }
  }
  return null;
}

ComparisonOutcome? _outcomeFromName(String name) {
  for (final outcome in ComparisonOutcome.values) {
    if (outcome.name == name) return outcome;
  }
  return null;
}

double? _nullableFiniteDouble(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite) {
    throw const FormatException('Expected a finite number');
  }
  return value.toDouble();
}

({double lo, double hi})? _rangeFromJson(Object? value) {
  if (value == null) return null;
  if (value is! Map) throw const FormatException('Invalid range');
  final lo = _nullableFiniteDouble(value['lo']);
  final hi = _nullableFiniteDouble(value['hi']);
  if (lo == null || hi == null || lo > hi) {
    throw const FormatException('Invalid range');
  }
  return (lo: lo, hi: hi);
}

List<BlockResult> _blocksFromJson(Object? value) {
  if (value is! List) throw const FormatException('Missing blocks');
  return [
    for (final item in value)
      if (item is Map)
        _blockFromJson(Map<String, dynamic>.from(item))
      else
        throw const FormatException('Invalid block'),
  ];
}

BlockResult _blockFromJson(Map<String, dynamic> json) {
  final rateBpm = _nullableFiniteDouble(json['rateBpm']);
  final coverage = _nullableFiniteDouble(json['coverage']);
  final observedFraction = _nullableFiniteDouble(json['observedFraction']);
  final cycles = json['cycles'];
  final rejection = json['rejection'];
  if (rateBpm == null || coverage == null || observedFraction == null ||
      cycles is! int || cycles < 0 ||
      rejection != null && rejection is! String) {
    throw const FormatException('Invalid block');
  }
  final rejectionValue = rejection == null ? null : _rejectionFromName(rejection);
  if (rejection != null && rejectionValue == null) {
    throw const FormatException('Invalid rejection');
  }
  return BlockResult(
    rateBpm: rateBpm,
    amplitudeBpm: _nullableFiniteDouble(json['amplitudeBpm']),
    coverage: coverage,
    observedFraction: observedFraction,
    cycles: cycles,
    rejection: rejectionValue,
  );
}

Map<String, Object?> _blockToJson(BlockResult block) => {
      'rateBpm': block.rateBpm,
      'amplitudeBpm': block.amplitudeBpm,
      'coverage': block.coverage,
      'observedFraction': block.observedFraction,
      'cycles': block.cycles,
      'rejection': block.rejection?.name,
    };

BlockRejection? _rejectionFromName(String name) {
  for (final rejection in BlockRejection.values) {
    if (rejection.name == name) return rejection;
  }
  return null;
}
