import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart';

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
/// two spectral streams fed those beats. Version 1.
class NightResumePart {
  NightResumePart({
    required this.tag,
    required this.corrector,
    required this.nn,
    required this.nnTimesMs,
    required this.hrv,
    required this.resp,
    required this.spectralFed,
  });

  final NightFoldTag tag;
  final Map<String, dynamic> corrector;
  final List<double> nn;
  final List<double> nnTimesMs;
  final Map<String, dynamic>? hrv;
  final Map<String, dynamic>? resp;

  /// Settled beats the two streams above have been fed (<= [nn].length).
  final int spectralFed;

  /// A deep copy of live state; the caller's objects stay untouched.
  factory NightResumePart.capture({
    required NightFoldTag tag,
    required RrCorrector corrector,
    required List<double> nn,
    required List<double> nnTimesMs,
    required HrvFreqStream? hrv,
    required RsaRespStream? resp,
    required int spectralFed,
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
      };

  /// Throws [FormatException] on anything malformed, including a corrector or
  /// stream payload analytics rejects and a tag that disagrees with the
  /// corrector it describes.
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
      // Constructing validates it; the tag must describe what it folded.
      if (RrCorrector.fromJson(corrector).toJson()['n'] != count) {
        throw const FormatException('night part: tag disagrees with corrector');
      }
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
        HrvFreqStream.fromJson(hrv);
        RsaRespStream.fromJson(resp);
        fed = f;
      }
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
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed night part: $e');
    }
  }

  /// Fresh live objects built from this part's data (each call builds new ones).
  RrCorrector buildCorrector() => RrCorrector.fromJson(corrector);
  HrvFreqStream? buildHrv() => hrv == null ? null : HrvFreqStream.fromJson(hrv!);
  RsaRespStream? buildResp() => resp == null ? null : RsaRespStream.fromJson(resp!);
}
