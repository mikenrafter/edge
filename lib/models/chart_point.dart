import 'package:flutter/foundation.dart' show immutable;

/// One stored chart point: [t] is the epoch SECONDS `getChart` stamps on it
/// (local noon of the day the value was derived on), [v] the value.
///
/// [olderVersion] is set when [v] is an OLDER algo version's stored value,
/// served because the current version has none; [olderReason] is why the
/// current one is missing, when the payload carries it. The flag is part of the
/// point, so it follows the point through every list, window and slot a chart
/// puts it in; nothing looks it up by time or value afterwards.
@immutable
class ChartPoint {
  final int t;
  final double v;
  final int? olderVersion;
  final String? olderReason;

  const ChartPoint({
    required this.t,
    required this.v,
    this.olderVersion,
    this.olderReason,
  });

  @override
  bool operator ==(Object other) =>
      other is ChartPoint &&
      other.t == t &&
      other.v == v &&
      other.olderVersion == olderVersion &&
      other.olderReason == olderReason;

  @override
  int get hashCode => Object.hash(t, v, olderVersion, olderReason);

  @override
  String toString() =>
      'ChartPoint(t: $t, v: $v${olderVersion == null ? '' : ', olderVersion: $olderVersion'})';
}
