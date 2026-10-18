// night_prsa.dart — the night's PRSA deceleration and acceleration capacity,
// folded across passes with the analytics prsaAggregator.
//
// Owner: the [NightPrsa] instance is owned by DayCalculationState, which feeds
// it only the night corrector's settled beats.

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';

import '../util/heavy.dart';

typedef _PrsaAgg = Aggregator<dynamic, DoubleColumn, Metric<PrsaResult>>;

_PrsaAgg? _dcAgg, _acAgg;

@heavy
_PrsaAgg _aggHeavy(bool deceleration) => deceleration
    ? (_dcAgg ??= prsaAggregator(deceleration: true))
    : (_acAgg ??= prsaAggregator(deceleration: false));

/// [decelerationCapacity] / [accelerationCapacity] over a growing night.
///
/// Settled beats are added with sequential `addSlice` calls only, never
/// `combine`: sequential folding keeps the profile sums in the reference's
/// order, which is what makes the result identical bit for bit. An ask adds
/// the provisional tail to a copy (`addSlice` mutates its state).
class NightPrsa {
  NightPrsa._(this._dc, this._ac);

  @heavy
  static NightPrsa emptyHeavy() =>
      NightPrsa._(_aggHeavy(true).empty(), _aggHeavy(false).empty());

  Object? _dc, _ac;

  @heavy
  void foldHeavy(List<double> nn) {
    if (nn.isEmpty) return;
    final col = DoubleColumn(Float64List.fromList(nn));
    _dc = _aggHeavy(true).addSlice(_dc, col, 0, col.length);
    _ac = _aggHeavy(false).addSlice(_ac, col, 0, col.length);
  }

  @heavy
  static Metric<PrsaResult> _snapshotHeavy(
      _PrsaAgg agg, Object? state, List<double> tailNn) {
    final copy = agg.decodeState(agg.encodeState(state));
    final tail = DoubleColumn(Float64List.fromList(tailNn));
    return agg.finish(agg.addSlice(copy, tail, 0, tail.length));
  }

  /// [decelerationCapacity] over the folded beats followed by [tailNn].
  @heavy
  Metric<PrsaResult> dcHeavy(List<double> tailNn) =>
      _snapshotHeavy(_aggHeavy(true), _dc, tailNn);

  /// [accelerationCapacity] over the folded beats followed by [tailNn].
  @heavy
  Metric<PrsaResult> acHeavy(List<double> tailNn) =>
      _snapshotHeavy(_aggHeavy(false), _ac, tailNn);

  /// Plain data for the checkpoint (the aggregators' own JSON conventions).
  @heavy
  Map<String, dynamic> toJsonHeavy() => {
        'v': 1,
        'dc': _aggHeavy(true).encodeState(_dc),
        'ac': _aggHeavy(false).encodeState(_ac),
      };

  /// Inverse of [toJsonHeavy]; throws [FormatException] on anything malformed.
  @heavy
  static NightPrsa fromJsonHeavy(Object? json) {
    try {
      if (json is! Map || json['v'] != 1) {
        throw const FormatException('night PRSA: bad version');
      }
      return NightPrsa._(_aggHeavy(true).decodeState(json['dc']),
          _aggHeavy(false).decodeState(json['ac']));
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed night PRSA: $e');
    }
  }
}
