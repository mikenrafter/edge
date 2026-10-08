// Synthetic 1 Hz day signals and the two comparison baselines for the spectral
// archive experiment. SYNTHETIC: no repo fixture holds a real day of 1 Hz HR,
// accel or skin temperature (test/fixtures/two_device_day.json is a few rows;
// day_stream_fixture.dart's synthAccel is white noise while moving). Every
// generator is seeded and takes no clock.
//
// Index = second slot of the local day; null = absent (a gap).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_edge/data/spectral_codec.dart';

import 'day_stream_fixture.dart' show synthAccel;

const int kDay = 86400;

/// Punch [gaps] runs of [minLen]..[maxLen] seconds into [v] (deterministic).
List<double?> withGaps(List<double?> v, int seed,
    {int gaps = 12, int minLen = 5, int maxLen = 1500}) {
  final rnd = math.Random(seed);
  final out = List<double?>.of(v);
  for (var g = 0; g < gaps; g++) {
    final start = rnd.nextInt(out.length);
    final len = minLen + rnd.nextInt(maxLen - minLen);
    for (var i = start; i < math.min(out.length, start + len); i++) {
      out[i] = null;
    }
  }
  return out;
}

/// Integer bpm: night at ~55 with 90-minute cycles and REM bumps, a morning
/// ramp, a daytime band 65..90 with short walks, one 25-minute workout at ~150,
/// RSA-ish +-1.5 and +-1 rounding noise.
List<double?> sleepLikeHr({int seed = 7, int length = kDay}) {
  final rnd = math.Random(seed);
  return List<double?>.generate(length, (t) {
    final h = t / 3600.0;
    double base;
    if (h < 6.5) {
      base = 54 + 4 * math.sin(2 * math.pi * h / 1.5) +
          (((h * 60).floor() % 90) > 70 ? 6 : 0);
    } else if (h < 7.5) {
      base = 54 + (h - 6.5) * 22;
    } else {
      base = 72 + 8 * math.sin(2 * math.pi * h / 3.1);
      if (h >= 17 && h < 17.42) base = 150 + 6 * math.sin(t / 40.0);
      if ((t ~/ 600) % 7 == 3) base += 18;
    }
    final v = base + 1.5 * math.sin(2 * math.pi * t / 4.0) +
        (rnd.nextDouble() - 0.5) * 2.0;
    return v.roundToDouble();
  });
}

/// The harder, more honest HR: no pure sinusoid. The same circadian/workout
/// shape as [sleepLikeHr] plus coloured (AR(1), phi 0.8, sigma ~1.6 bpm)
/// beat-to-beat variability, rounded to integer bpm. Broadband, so a sparse
/// transform cannot hide it in two coefficients.
List<double?> broadbandHr({int seed = 17, int length = kDay}) {
  final rnd = math.Random(seed);
  final base = sleepLikeHr(seed: seed, length: length);
  var ar = 0.0;
  return List<double?>.generate(length, (t) {
    ar = 0.8 * ar + (rnd.nextDouble() + rnd.nextDouble() - 1) * 1.7;
    // sleepLikeHr already holds rounded values with its own small noise; add
    // the coloured part and re-round.
    return (base[t]! + ar).roundToDouble();
  });
}

/// Gravity-vector component: posture holds for minutes (steps), tiny jitter
/// while still, correlated (AR(1)) swings while moving. [axis] 0..2.
List<double?> correlatedAccel(int axis, {int seed = 11, int length = kDay}) {
  final rnd = math.Random(seed + axis * 101);
  final out = List<double?>.filled(length, null);
  var posture = [0.3, 0.8, 0.5][axis];
  var swing = 0.0;
  var moving = false;
  var left = 300;
  for (var t = 0; t < length; t++) {
    if (--left <= 0) {
      moving = rnd.nextDouble() < 0.35;
      left = 30 + rnd.nextInt(900);
      if (!moving) posture = (rnd.nextDouble() - .5) * 1.6;
    }
    swing = moving ? 0.92 * swing + 0.25 * (rnd.nextDouble() - .5) : 0.0;
    out[t] = double.parse(
        (posture + swing + (rnd.nextDouble() - .5) * 0.01).toStringAsFixed(3));
  }
  return out;
}

/// 0.01 C resolution: slow circadian drift, a cooler night, +-0.02 noise.
List<double?> skinTemp({int seed = 3, int length = kDay}) {
  final rnd = math.Random(seed);
  return List<double?>.generate(length, (t) {
    final v = 33.2 +
        1.2 * math.sin(2 * math.pi * (t / 3600.0 - 14) / 24) -
        (t < 6.5 * 3600 ? 0.4 : 0) +
        (rnd.nextDouble() - .5) * 0.04;
    return double.parse(v.toStringAsFixed(2));
  });
}

/// The existing repo fixture generator, read as a worst case: it is white noise
/// while moving and zeros mark "no vector" (turned into null here).
List<double?> whiteNoiseAccel(int axis, {int seed = 5, int length = kDay}) {
  final a = synthAccel(seed, 0, length);
  final src = [a.ax, a.ay, a.az][axis];
  final out = List<double?>.filled(length, null);
  for (var i = 0; i < a.length; i++) {
    final t = a.tsSec[i];
    final zero = a.ax[i] == 0 && a.ay[i] == 0 && a.az[i] == 0;
    out[t] = zero ? null : double.parse(src[i].toStringAsFixed(3));
  }
  return out;
}

/// The named day set both the codec tests and the experiment harness use.
Map<String, List<double?>> fixtureDay({bool gaps = true}) {
  List<double?> g(List<double?> v, int s) => gaps ? withGaps(v, s) : v;
  return {
    'hr': g(sleepLikeHr(), 1),
    'ax': g(correlatedAccel(0), 2),
    'ay': g(correlatedAccel(1), 3),
    'az': g(correlatedAccel(2), 4),
    'skin_temp_c': g(skinTemp(), 5),
  };
}

// ── measuring ────────────────────────────────────────────────────────────────

class Err {
  const Err(this.rms, this.max);
  final double rms, max;
}

/// Error of [recon] against [orig] over the positions valid in [orig].
Err errorOf(List<double?> orig, List<double?> recon) {
  var n = 0;
  var sq = 0.0, mx = 0.0;
  for (var i = 0; i < orig.length; i++) {
    final o = orig[i];
    if (o == null) continue;
    final r = recon[i];
    final d = (r == null) ? double.infinity : (r - o).abs();
    sq += d * d;
    if (d > mx) mx = d;
    n++;
  }
  return Err(n == 0 ? 0 : math.sqrt(sq / n), mx);
}

int validCount(List<double?> v) => v.where((e) => e != null).length;

// ── baselines ────────────────────────────────────────────────────────────────

void _varint(BytesBuilder b, int v) {
  var z = (v << 1) ^ (v >> 63); // zigzag
  while (z >= 0x80) {
    b.addByte((z & 0x7f) | 0x80);
    z >>= 7;
  }
  b.addByte(z);
}

int _deflated(Uint8List raw) => ZLibCodec(level: 9).encode(raw).length;

/// The validity mask as run lengths, deflated: what ANY scheme that keeps gaps
/// honest pays. Charged to the baselines so the comparison is fair.
int maskBytes(List<double?> v) {
  final b = BytesBuilder();
  var cur = false;
  var run = 0;
  for (final e in v) {
    if ((e != null) == cur) {
      run++;
    } else {
      _varint(b, run);
      cur = !cur;
      run = 1;
    }
  }
  _varint(b, run);
  return _deflated(b.toBytes());
}

/// Lossless at the signal's native resolution [quantum]: deflate of zigzag
/// varint first-differences of the valid values, plus the mask.
int losslessBytes(List<double?> v, double quantum) {
  final b = BytesBuilder();
  var prev = 0;
  for (final e in v) {
    if (e == null) continue;
    final q = (e / quantum).round();
    _varint(b, q - prev);
    prev = q;
  }
  return _deflated(b.toBytes()) + maskBytes(v);
}

/// Keep-every-Nth baseline over the dense valid sequence, linear interpolation
/// between kept samples (interpolation is the BASELINE's reconstruction only;
/// the codec never interpolates). Returns the smallest N in the ladder whose
/// error meets the bounds, its bytes, and N (null when even N=1 is the answer).
({int n, int bytes}) keepEveryNth(
    List<double?> v, double quantum, double maxRms, double maxAbs) {
  final dense = [for (final e in v) if (e != null) e];
  var best = (n: 1, bytes: losslessBytes(v, quantum));
  for (final n in const [2, 4, 8, 16, 32, 64, 128, 256]) {
    if (dense.length < n + 1) break;
    final kept = <int>[
      for (var i = 0; i < dense.length; i += n) i,
      if ((dense.length - 1) % n != 0) dense.length - 1,
    ];
    var sq = 0.0, mx = 0.0;
    for (var k = 0; k + 1 < kept.length; k++) {
      final a = kept[k], b = kept[k + 1];
      for (var i = a; i <= b; i++) {
        final r = dense[a] + (dense[b] - dense[a]) * (i - a) / (b - a);
        final d = (r - dense[i]).abs();
        sq += d * d;
        if (d > mx) mx = d;
      }
    }
    final rms = math.sqrt(sq / dense.length);
    if (rms > maxRms || mx > maxAbs) break;
    final b = BytesBuilder();
    var prev = 0;
    for (final i in kept) {
      final q = (dense[i] / quantum).round();
      _varint(b, q - prev);
      prev = q;
    }
    best = (n: n, bytes: _deflated(b.toBytes()) + maskBytes(v));
  }
  return best;
}

String fmtRow(String signal, int nValid, int lossless, int nth, int nthBytes,
    SpectralStats s) {
  String r(num a) => a.toStringAsFixed(1);
  return '${signal.padRight(12)} valid=${nValid.toString().padLeft(6)}  '
      'lossless=${lossless.toString().padLeft(7)}B  '
      'every-${nth.toString().padRight(3)}=${nthBytes.toString().padLeft(7)}B  '
      'spectral=${s.bytes.toString().padLeft(7)}B  '
      'ratio-vs-lossless=${r(lossless / s.bytes)}x  '
      'rms=${s.rmsErr.toStringAsFixed(3)} max=${s.maxErr.toStringAsFixed(3)}  '
      'coeffs=${s.coefficientCount}';
}

