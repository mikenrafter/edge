import '../util/heavy.dart';
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';

@heavy
Aggregator<dynamic, DoubleColumn, Metric<PrsaResult>> _dcHeavy() =>
    prsaAggregator(deceleration: true);
@heavy
Aggregator<dynamic, DoubleColumn, Metric<PrsaResult>> _acHeavy() =>
    prsaAggregator(deceleration: false);

/// Settled night NN in reference order. Provisional tails only touch copies.
class NightPrsa {
  NightPrsa._();
  Object? _dcState, _acState;

  @heavy
  Map<String, dynamic> toJsonHeavy() => {
    'v': 1, 'dc': _dcHeavy().encodeState(_dcState), 'ac': _acHeavy().encodeState(_acState),
  };

  @heavy
  static NightPrsa fromJsonHeavy(Object? raw, [int? expectedFed]) {
    if (raw is! Map) throw const FormatException('night PRSA');
    final json = raw.cast<String, dynamic>();
    final dcCount = json['dc'];
    if (dcCount is! List || dcCount.isEmpty || dcCount.first is! int) {
      throw const FormatException('night PRSA count');
    }
    final fed = expectedFed ?? dcCount.first as int;
    if (json['v'] != 1) throw const FormatException('PRSA version');
    final dc = json['dc'], ac = json['ac'];
    if (dc is! List || ac is! List || dc.first != fed || ac.first != fed) {
      throw const FormatException('PRSA feed count');
    }
    return NightPrsa.emptyHeavy()
      .._dcState = _dcHeavy().decodeState(dc)
      .._acState = _acHeavy().decodeState(ac);
  }

  @heavy
  void foldHeavy(List<double> nn) {
    final column = DoubleColumn(Float64List.fromList(nn));
    _dcState = _dcHeavy().addSlice(_dcState, column, 0, column.length);
    _acState = _acHeavy().addSlice(_acState, column, 0, column.length);
  }

  @heavy
  (Metric<PrsaResult>, Metric<PrsaResult>) snapshotHeavy(List<double> tailNn) {
    final tail = DoubleColumn(Float64List.fromList(tailNn));
    Metric<PrsaResult> finish(
        Aggregator<dynamic, DoubleColumn, Metric<PrsaResult>> agg,
        Object? state) {
      final copy = agg.decodeState(agg.encodeState(state));
      return agg.finish(agg.addSlice(copy, tail, 0, tail.length));
    }
    // Sequential addSlice preserves anchor order; never combine partial sums.
    // Merged analytics prsa_aggregator.dart declares profile/capacity abs+rel 1e-9,
    // confidence abs 1e-12 parity with the batch functions.
    return (finish(_dcHeavy(), _dcState), finish(_acHeavy(), _acState));
  }

  @heavy
  static NightPrsa emptyHeavy() => NightPrsa._()
      .._dcState = _dcHeavy().empty()
      .._acState = _acHeavy().empty();
  @heavy
  Metric<PrsaResult> dcHeavy(List<double> tail) => snapshotHeavy(tail).$1;
  @heavy
  Metric<PrsaResult> acHeavy(List<double> tail) => snapshotHeavy(tail).$2;

}
