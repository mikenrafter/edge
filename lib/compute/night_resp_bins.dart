import 'package:openstrap_analytics/onehz.dart';

/// Thirty-minute bins anchored at the first corrected beat, like the batch.
/// Settled beats close bins; snapshots never commit provisional tail rates.
class NightRespBins {
  NightRespBins();
  double? _origin;
  int _openIndex = 0, _openCount = 0;
  RsaRespStream _open = RsaRespStream();
  final List<double> _closed = [];

  Map<String, dynamic> toJson() => {
    'v': 1, 'origin': _origin, 'index': _openIndex, 'count': _openCount,
    'open': _open.toJson(), 'closed': _closed,
  };

  factory NightRespBins.fromJson(Map<String, dynamic> json, int fed) {
    final origin = json['origin'], index = json['index'], count = json['count'];
    final closed = (json['closed'] as List).cast<num>();
    if (json['v'] != 1 || index is! int || index < 0 || count is! int ||
        count < 0 || count > fed || closed.length > fed ~/ 60 ||
        closed.any((x) => !x.isFinite) ||
        (fed == 0 ? origin != null : origin is! num || !origin.isFinite)) {
      throw const FormatException('RSA bins');
    }
    final open = (json['open'] as Map).cast<String, dynamic>();
    if (open['n'] != count) throw const FormatException('RSA bin count');
    return NightRespBins()
      .._origin = (origin as num?)?.toDouble()
      .._openIndex = index
      .._openCount = count
      .._open = RsaRespStream.fromJson(open)
      .._closed.addAll(closed.map((x) => x.toDouble()));
  }

  int _bin(double time, double origin) => ((time - origin) / 1800000.0).floor();

  void _appendRate(List<double> out, Metric<RespEstimate> metric) {
    final rate = metric.present ? metric.value!.brpm : null;
    if (rate != null) out.add(rate);
  }

  /// Returns the number of nonempty bin slices actually folded.
  int fold(List<double> nn, List<double> times) {
    var from = 0, slices = 0;
    void feed(int end) {
      if (end == from) return;
      _open.fold(nn.sublist(from, end), times.sublist(from, end));
      _openCount += end - from;
      slices++;
    }
    for (var i = 0; i < nn.length; i++) {
      final index = _bin(times[i], _origin ??= times[i]);
      if (index == _openIndex) continue;
      feed(i);
      if (_openCount >= 60) {
        _appendRate(_closed, _open.snapshot(artifactFraction: 0.0));
      }
      _open = RsaRespStream();
      _openCount = 0;
      _openIndex = index;
      from = i;
    }
    feed(nn.length);
    return slices;
  }

  List<double> snapshot(List<double> tailNn, List<double> tailTimes) {
    if (_origin == null && tailNn.isEmpty) return [];
    final origin = _origin ?? tailTimes.first;
    final out = [..._closed];
    var i = 0;
    while (i < tailNn.length && _bin(tailTimes[i], origin) == _openIndex) {
      i++;
    }
    if (_openCount + i >= 60) {
      _appendRate(out, _open.snapshot(tailNnMs: tailNn.sublist(0, i),
          tailNnTimesMs: tailTimes.sublist(0, i), artifactFraction: 0.0));
    }
    while (i < tailNn.length) {
      final index = _bin(tailTimes[i], origin);
      var end = i + 1;
      while (end < tailNn.length && _bin(tailTimes[end], origin) == index) {
        end++;
      }
      if (end - i >= 60) {
        _appendRate(out, rsaRespRate(tailNn.sublist(i, end),
            tailTimes.sublist(i, end), artifactFraction: 0.0));
      }
      i = end;
    }
    return out;
  }
}
