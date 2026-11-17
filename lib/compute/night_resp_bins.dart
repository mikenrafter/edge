import '../util/heavy.dart';
import 'package:openstrap_analytics/onehz.dart';

/// Thirty-minute bins anchored at the first corrected beat, like the batch.
/// Keep closed spectral states so every snapshot applies the current night's
/// artifact gate through analytics, including to bins closed on a prior pass.
class NightRespBins {
  NightRespBins();
  double? _origin;
  int _openIndex = 0, _openCount = 0;
  RsaRespStream _open = RsaRespStream();
  final List<({int count, RsaRespStream stream})> _closed = [];

  @heavy
  Map<String, dynamic> toJsonHeavy() => {
    'v': 2, 'origin': _origin, 'index': _openIndex, 'count': _openCount,
    'open': _open.toJson(),
    'closed': [for (final bin in _closed)
      {'count': bin.count, 'state': bin.stream.toJson()}],
  };

  @heavy
  static NightRespBins fromJsonHeavy(Object? raw, [int? expectedFed]) {
    if (raw is! Map) throw const FormatException('night RSA bins');
    final json = raw.cast<String, dynamic>();
    final savedClosed = json['closed'];
    final savedCount = json['count'];
    if (savedClosed is! List || savedCount is! int) {
      throw const FormatException('night RSA count');
    }
    var fed = expectedFed ?? savedCount;
    if (expectedFed == null) {
      for (final row in savedClosed) { fed += ((row as Map)['count'] as int); }
    }
    final origin = json['origin'], index = json['index'], count = json['count'];
    final closed = json['closed'] as List;
    if (json['v'] != 2 || index is! int || index < 0 || count is! int ||
        count < 0 || count > fed || closed.length > fed ~/ 60 ||
        (fed == 0 ? origin != null : origin is! num || !origin.isFinite)) {
      throw const FormatException('RSA bins');
    }
    final open = (json['open'] as Map).cast<String, dynamic>();
    if (open['n'] != count) throw const FormatException('RSA bin count');
    final result = NightRespBins()
      .._origin = (origin as num?)?.toDouble()
      .._openIndex = index
      .._openCount = count
      .._open = RsaRespStream.fromJson(open);
    var total = count;
    for (final bin in closed) {
      final n = (bin as Map)['count'];
      final state = (bin['state'] as Map).cast<String, dynamic>();
      if (n is! int || n < 60 || n > fed || state['n'] != n) {
        throw const FormatException('closed RSA bin count');
      }
      total += n;
      if (total > fed) throw const FormatException('RSA bins feed count');
      result._closed.add((count: n, stream: RsaRespStream.fromJson(state)));
    }
    return result;
  }

  int _bin(double time, double origin) => ((time - origin) / 1800000.0).floor();

  void _appendRate(List<double> out, Metric<RespEstimate> metric) {
    final rate = metric.present ? metric.value!.brpm : null;
    if (rate != null) out.add(rate);
  }

  /// Returns the number of nonempty bin slices actually folded.
  @heavy
  int foldHeavy(List<double> nn, List<double> times) {
    var from = 0, slices = 0;
    void feed(int end) {
      if (end == from) return;
      _open.fold(nn.sublist(from, end), times.sublist(from, end));
      _openCount += end - from;
      slices++;
    }
    for (var i = 0; i < times.length; i++) {
      final index = _bin(times[i], _origin ??= times[i]);
      if (index == _openIndex) continue;
      feed(i);
      if (_openCount >= 60) _closed.add((count: _openCount, stream: _open));
      _open = RsaRespStream();
      _openCount = 0;
      _openIndex = index;
      from = i;
    }
    feed(nn.length);
    return slices;
  }

  @heavy
  List<double> snapshotHeavy(List<double> tailNn, List<double> tailTimes,
      {required double artifactFraction}) {
    if (_origin == null && tailNn.isEmpty) return [];
    final origin = _origin ?? tailTimes.first;
    final out = <double>[];
    for (final bin in _closed) {
      _appendRate(out, bin.stream.snapshot(artifactFraction: artifactFraction));
    }
    var i = 0;
    while (i < tailNn.length && _bin(tailTimes[i], origin) == _openIndex) {
      i++;
    }
    if (_openCount + i >= 60) {
      _appendRate(out, _open.snapshot(tailNnMs: tailNn.sublist(0, i),
          tailNnTimesMs: tailTimes.sublist(0, i), artifactFraction: artifactFraction));
    }
    while (i < tailNn.length) {
      final index = _bin(tailTimes[i], origin);
      var end = i + 1;
      while (end < tailNn.length && _bin(tailTimes[end], origin) == index) {
        end++;
      }
      if (end - i >= 60) {
        _appendRate(out, rsaRespRate(tailNn.sublist(i, end),
            tailTimes.sublist(i, end), artifactFraction: artifactFraction));
      }
      i = end;
    }
    return out;
  }


}

@heavy
List<double> respPerWindowHeavy(List<double> nn, List<double> nnTimes,
    {double artifactFraction = 0}) {
  if (nn.isEmpty || nn.length != nnTimes.length) return const [];
  final t0 = nnTimes.first;
  final binsNn = <int, List<double>>{};
  final binsTs = <int, List<double>>{};
  for (var i = 0; i < nn.length; i++) {
    final idx = _binOf(nnTimes[i], t0);
    (binsNn[idx] ??= <double>[]).add(nn[i]);
    (binsTs[idx] ??= <double>[]).add(nnTimes[i]);
  }
  final out = <double>[];
  final idxs = binsNn.keys.toList()..sort();
  for (final idx in idxs) {
    final segNn = binsNn[idx]!;
    if (segNn.length < _minBeats) continue;
    final b = _rate(rsaRespRate(segNn, binsTs[idx]!, artifactFraction: artifactFraction));
    if (b != null) out.add(b);
  }
  return out;
}


int _binOf(double t, double t0) => ((t - t0) / (30 * 60 * 1000)).floor();
const _minBeats = 60;
double? _rate(Metric<RespEstimate> metric) => metric.value?.brpm;
