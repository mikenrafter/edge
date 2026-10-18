import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart';

import '../util/heavy.dart';
import 'night_prsa.dart';
import 'night_resp_bins.dart';

/// What a night fold has consumed: the first beat's time, how many beats, and a
/// 64-bit fingerprint of exactly those beats ([nightBeatsFingerprint]). A later
/// slice extends the fold when it starts at [startTsMs], holds at least [count]
/// beats, and its first [count] beats hash to [fingerprint]. The same rule
/// serves the in-memory fold and one restored from a checkpoint, so no copy of
/// the beats is kept anywhere.
typedef NightFoldTag = ({double startTsMs, int count, int fingerprint});

const int _fnvOffset = 0xcbf29ce484222325;
const int _fnvPrime = 0x100000001b3;

final ByteData _bits = ByteData(8);
final Uint8List _bitBytes = _bits.buffer.asUint8List();

/// Continues the 64-bit FNV-1a state [h] over beats [from, to): for each beat the
/// 8 bytes of its interval then the 8 bytes of its time, each the raw IEEE-754
/// bits, little-endian (exact bits: -0.0 differs from 0.0, one ulp differs).
/// The state is a prefix hash, so extending a fold costs only the new beats.
int nightBeatsFingerprintFrom(
  int h,
  List<double> rrMs,
  List<double> rrTsMs,
  int from,
  int to,
) {
  for (var i = from; i < to; i++) {
    _bits.setFloat64(0, rrMs[i], Endian.little);
    for (var k = 0; k < 8; k++) {
      h = (h ^ _bitBytes[k]) * _fnvPrime;
    }
    _bits.setFloat64(0, rrTsMs[i], Endian.little);
    for (var k = 0; k < 8; k++) {
      h = (h ^ _bitBytes[k]) * _fnvPrime;
    }
  }
  return h;
}

/// The fingerprint of the first [count] beats; deterministic across processes
/// (no `hashCode`). 64-bit collision odds (~1e-19) are owner-accepted.
int nightBeatsFingerprint(List<double> rrMs, List<double> rrTsMs, int count) =>
    nightBeatsFingerprintFrom(_fnvOffset, rrMs, rrTsMs, 0, count);

/// Fingerprint of no beats (the seed of a running fold).
const int kNightFingerprintSeed = _fnvOffset;

Object? _copy(Object? v) {
  if (v is Map) return {for (final e in v.entries) e.key as String: _copy(e.value)};
  if (v is List) return [for (final x in v) _copy(x)];
  return v;
}

List<double> _doubles(Object? v) {
  if (v is! List) throw const FormatException('night part: expected a list');
  return [for (final x in v) (x as num).toDouble()];
}

/// The night's incremental state as plain data (maps, lists, numbers), so it
/// crosses to a worker and into the checkpoint blob without any live object:
/// the RR corrector, the settled corrected beats it already handed out, and the
/// streams fed those beats (spectral, CVHR, 30-min RSA bins, PRSA), each
/// optional. Version 1: a part without a stream restarts that stream.
///
/// The UI isolate never holds one of these: it carries the part only as its
/// encoded text (the UTF-8 JSON of [toJson]) and the workers that need it build
/// it, so [captureHeavy] and the `build…Heavy` methods are `@heavy`.
class NightResumePart {
  NightResumePart({
    required this.tag,
    required this.corrector,
    required this.nn,
    required this.nnTimesMs,
    required this.hrv,
    required this.resp,
    required this.spectralFed,
    this.cvhr,
    this.cvhrFed = 0,
    this.respBins,
    this.respBinsFed = 0,
    this.prsa,
    this.prsaFed = 0,
  });

  final NightFoldTag tag;
  final Map<String, dynamic> corrector;
  final List<double> nn;
  final List<double> nnTimesMs;
  final Map<String, dynamic>? hrv;
  final Map<String, dynamic>? resp;

  /// Settled beats the two streams above have been fed (<= [nn].length).
  final int spectralFed;

  /// The CVHR stream (own feed count; absent until the screen was asked).
  final Map<String, dynamic>? cvhr;

  /// Settled beats [cvhr] has been fed (<= [nn].length).
  final int cvhrFed;

  /// The 30-min RSA bins ([NightRespBins]; absent until asked).
  final Map<String, dynamic>? respBins;

  /// Settled beats [respBins] has been fed (<= [nn].length).
  final int respBinsFed;

  /// The PRSA sums ([NightPrsa]; absent until asked).
  final Map<String, dynamic>? prsa;

  /// Settled beats [prsa] has been fed (<= [nn].length).
  final int prsaFed;

  /// A deep copy of live state; the caller's objects stay untouched.
  @heavy
  static NightResumePart captureHeavy({
    required NightFoldTag tag,
    required RrCorrector corrector,
    required List<double> nn,
    required List<double> nnTimesMs,
    required HrvFreqStream? hrv,
    required RsaRespStream? resp,
    required int spectralFed,
    CvhrStream? cvhr,
    int cvhrFed = 0,
    NightRespBins? respBins,
    int respBinsFed = 0,
    NightPrsa? prsa,
    int prsaFed = 0,
  }) {
    final live = hrv != null && resp != null;
    return NightResumePart(
      tag: tag,
      corrector: _copy(corrector.toJson()) as Map<String, dynamic>,
      nn: List<double>.of(nn),
      nnTimesMs: List<double>.of(nnTimesMs),
      hrv: live ? _copy(hrv.toJson()) as Map<String, dynamic> : null,
      resp: live ? _copy(resp.toJson()) as Map<String, dynamic> : null,
      spectralFed: live ? spectralFed : 0,
      cvhr: cvhr == null ? null : _copy(cvhr.toJson()) as Map<String, dynamic>,
      cvhrFed: cvhr == null ? 0 : cvhrFed,
      respBins: respBins == null
          ? null
          : _copy(respBins.toJsonHeavy()) as Map<String, dynamic>,
      respBinsFed: respBins == null ? 0 : respBinsFed,
      prsa: prsa == null ? null : _copy(prsa.toJsonHeavy()) as Map<String, dynamic>,
      prsaFed: prsa == null ? 0 : prsaFed,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'tag': {
          'startTsMs': tag.startTsMs,
          'count': tag.count,
          'fp': tag.fingerprint.toString(),
        },
        'corrector': corrector,
        'nn': nn,
        'nnTimes': nnTimesMs,
        if (hrv != null && resp != null) ...{
          'hrv': hrv,
          'resp': resp,
          'fed': spectralFed,
        },
        if (cvhr != null) ...{'cvhr': cvhr, 'cvhrFed': cvhrFed},
        if (respBins != null) ...{
          'respBins': respBins,
          'respBinsFed': respBinsFed,
        },
        if (prsa != null) ...{'prsa': prsa, 'prsaFed': prsaFed},
      };

  /// Throws [FormatException] on anything structurally malformed. What only
  /// the analytics package can judge (a corrector or stream payload it rejects,
  /// a tag that disagrees with the corrector it describes) is checked where the
  /// part is adopted, in a worker (`DayCalculationState`), by building the
  /// live objects.
  factory NightResumePart.fromJson(Map<String, dynamic> json) {
    try {
      if (json['v'] != 1) throw const FormatException('night part: bad version');
      final t = json['tag'];
      if (t is! Map) throw const FormatException('night part: no tag');
      final start = t['startTsMs'];
      final count = t['count'];
      final fp = t['fp'] is String ? int.tryParse(t['fp'] as String) : null;
      if (start is! num || count is! int || count < 0 || fp == null) {
        throw const FormatException('night part: bad tag');
      }
      final corr = json['corrector'];
      if (corr is! Map) throw const FormatException('night part: no corrector');
      final corrector = (_copy(corr) as Map).cast<String, dynamic>();
      final nn = _doubles(json['nn']), nnTimes = _doubles(json['nnTimes']);
      if (nn.length != nnTimes.length) {
        throw const FormatException('night part: nn lengths');
      }
      Map<String, dynamic>? hrv, resp;
      var fed = 0;
      if (json.containsKey('hrv') || json.containsKey('resp')) {
        final h = json['hrv'], r = json['resp'], f = json['fed'];
        if (h is! Map || r is! Map || f is! int || f < 0 || f > nn.length) {
          throw const FormatException('night part: bad streams');
        }
        hrv = (_copy(h) as Map).cast<String, dynamic>();
        resp = (_copy(r) as Map).cast<String, dynamic>();
        fed = f;
      }
      Map<String, dynamic>? cvhr;
      var cvhrFed = 0;
      if (json.containsKey('cvhr') || json.containsKey('cvhrFed')) {
        final c = json['cvhr'], f = json['cvhrFed'];
        if (c is! Map || f is! int || f < 0 || f > nn.length) {
          throw const FormatException('night part: bad cvhr');
        }
        cvhr = (_copy(c) as Map).cast<String, dynamic>();
        cvhrFed = f;
      }
      (Map<String, dynamic>?, int) optional(String key, String fedKey) {
        if (!json.containsKey(key) && !json.containsKey(fedKey)) return (null, 0);
        final v = json[key], f = json[fedKey];
        if (v is! Map || f is! int || f < 0 || f > nn.length) {
          throw FormatException('night part: bad $key');
        }
        return ((_copy(v) as Map).cast<String, dynamic>(), f);
      }

      final (respBins, respBinsFed) = optional('respBins', 'respBinsFed');
      final (prsa, prsaFed) = optional('prsa', 'prsaFed');
      return NightResumePart(
        tag: (
          startTsMs: start.toDouble(),
          count: count,
          fingerprint: fp,
        ),
        corrector: corrector,
        nn: nn,
        nnTimesMs: nnTimes,
        hrv: hrv,
        resp: resp,
        spectralFed: fed,
        cvhr: cvhr,
        cvhrFed: cvhrFed,
        respBins: respBins,
        respBinsFed: respBinsFed,
        prsa: prsa,
        prsaFed: prsaFed,
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed night part: $e');
    }
  }

  /// Fresh live objects built from this part's data (each call builds new ones).
  /// Each throws [FormatException] when the analytics package rejects the data.
  @heavy
  RrCorrector buildCorrectorHeavy() => RrCorrector.fromJson(corrector);
  @heavy
  HrvFreqStream? buildHrvHeavy() =>
      hrv == null ? null : HrvFreqStream.fromJson(hrv!);
  @heavy
  RsaRespStream? buildRespHeavy() =>
      resp == null ? null : RsaRespStream.fromJson(resp!);
  @heavy
  CvhrStream? buildCvhrHeavy() =>
      cvhr == null ? null : CvhrStream.fromJson(cvhr!);
  @heavy
  NightRespBins? buildRespBinsHeavy() =>
      respBins == null ? null : NightRespBins.fromJsonHeavy(respBins);
  @heavy
  NightPrsa? buildPrsaHeavy() =>
      prsa == null ? null : NightPrsa.fromJsonHeavy(prsa);
}
