// night_resp_bins.dart — the night's 30-min RSA respiration bins behind BRV,
// as one batch function and a stream that reproduces it bit for bit.
//
// Owner: the [NightRespBins] instance is owned by DayCalculationState, which
// feeds it only the night corrector's settled beats.

import 'package:openstrap_analytics/onehz.dart';

import '../util/heavy.dart';

const double _binMs = 1800000.0;
const int _minBeats = 60;

int _binOf(double t, double t0) => ((t - t0) / _binMs).floor();

double? _rate(Metric<RespEstimate> r) => r.present ? r.value!.brpm : null;

/// Per-window RSA respiratory rates (br/min) for the BRV estimator. Buckets the
/// cleaned NN into ~30-min bins by beat time (anchored at the first beat) and
/// runs [rsaRespRate] on each bin with at least 60 beats; keeps only resolved
/// windows, in bin order.
@heavy
List<double> respPerWindowHeavy(List<double> nn, List<double> nnTimes) {
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
    // NN is already artifact-corrected upstream → artifactFraction 0.
    final b = _rate(rsaRespRate(segNn, binsTs[idx]!, artifactFraction: 0.0));
    if (b != null) out.add(b);
  }
  return out;
}

/// [respPerWindowHeavy] over a growing night, folding each settled beat once.
///
/// A bin is closed once a settled beat lies in a later bin; its rate is scored
/// then and kept. The open bin is an [RsaRespStream], snapshotted with the part
/// of the provisional tail inside it (its snapshot equals [rsaRespRate] over
/// folded ++ tail). Tail beats in later bins are scored in batch: they are few.
/// Bin indices are anchored at the first folded beat, which is the night's
/// first corrected beat, so they are the batch's indices.
class NightRespBins {
  NightRespBins();

  double? _t0;
  int _openIdx = 0, _openCount = 0;
  RsaRespStream _open = RsaRespStream();
  final List<double> _closed = [];

  @heavy
  void _closeOpenHeavy() {
    if (_openCount >= _minBeats) {
      final b = _rate(_open.snapshot(artifactFraction: 0.0));
      if (b != null) _closed.add(b);
    }
    _open = RsaRespStream();
    _openCount = 0;
  }

  /// Folds settled beats, in order, after those already folded.
  @heavy
  void foldHeavy(List<double> nn, List<double> nnTimes) {
    var from = 0;
    for (var i = 0; i < nn.length; i++) {
      final k = _binOf(nnTimes[i], _t0 ??= nnTimes[i]);
      if (k == _openIdx) continue;
      if (i > from) {
        _open.fold(nn.sublist(from, i), nnTimes.sublist(from, i));
        _openCount += i - from;
      }
      _closeOpenHeavy();
      _openIdx = k;
      from = i;
    }
    if (nn.length > from) {
      _open.fold(nn.sublist(from), nnTimes.sublist(from));
      _openCount += nn.length - from;
    }
  }

  /// [respPerWindowHeavy] over the folded beats followed by the tail.
  @heavy
  List<double> snapshotHeavy(List<double> tailNn, List<double> tailNnTimes) {
    final t0 = _t0;
    if (t0 == null) return respPerWindowHeavy(tailNn, tailNnTimes);
    final out = [..._closed];
    final n = tailNn.length;
    var i = 0;
    while (i < n && _binOf(tailNnTimes[i], t0) == _openIdx) {
      i++;
    }
    if (_openCount + i >= _minBeats) {
      final b = _rate(_open.snapshot(
        tailNnMs: tailNn.sublist(0, i),
        tailNnTimesMs: tailNnTimes.sublist(0, i),
        artifactFraction: 0.0,
      ));
      if (b != null) out.add(b);
    }
    while (i < n) {
      final k = _binOf(tailNnTimes[i], t0);
      var j = i;
      while (j < n && _binOf(tailNnTimes[j], t0) == k) {
        j++;
      }
      if (j - i >= _minBeats) {
        final b = _rate(rsaRespRate(tailNn.sublist(i, j),
            tailNnTimes.sublist(i, j),
            artifactFraction: 0.0));
        if (b != null) out.add(b);
      }
      i = j;
    }
    return out;
  }

  /// Plain data (maps, lists, numbers) for the checkpoint.
  @heavy
  Map<String, dynamic> toJsonHeavy() => {
        'v': 1,
        't0': _t0,
        'openIdx': _openIdx,
        'openCount': _openCount,
        'open': _open.toJson(),
        'closed': [..._closed],
      };

  /// Inverse of [toJsonHeavy]; throws [FormatException] on anything malformed.
  @heavy
  static NightRespBins fromJsonHeavy(Object? json) {
    try {
      if (json is! Map || json['v'] != 1) {
        throw const FormatException('resp bins: bad version');
      }
      final t0 = json['t0'], idx = json['openIdx'], count = json['openCount'];
      final open = json['open'], closed = json['closed'];
      if ((t0 != null && t0 is! num) ||
          idx is! int ||
          idx < 0 ||
          count is! int ||
          count < 0 ||
          (t0 == null) != (count == 0) ||
          open is! Map ||
          closed is! List) {
        throw const FormatException('resp bins: bad fields');
      }
      return NightRespBins()
        .._t0 = (t0 as num?)?.toDouble()
        .._openIdx = idx
        .._openCount = count
        .._open = RsaRespStream.fromJson(open.cast<String, dynamic>())
        .._closed.addAll([for (final x in closed) (x as num).toDouble()]);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed resp bins: $e');
    }
  }
}
