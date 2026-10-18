// Shared data for the streaming RR / day-curve checkpoint tests: real-shaped
// beats and accelerometer seconds, the plain `Substrate` the batch functions
// read, and the database rows the engine reads. Deterministic (seeded), no wall
// clock. Ported from analytics-incr-research/tool/incremental/synth.dart.
//
// Real-shaped means what the app really feeds `correctRr`: integer-millisecond
// RR, end-of-beat stamps quantised to WHOLE seconds (`rr_ts_ms = rec_ts * 1000`,
// several beats can share one stamp), ectopic pairs, missed and extra beats,
// multi-beat noise runs, sensor dropouts (no beats for seconds to minutes),
// and an optional burst of irregular rhythm that makes the screen flag.
import 'dart:math' as math;

import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';

class Beats {
  Beats(this.rr, this.ts);
  final List<double> rr;

  /// Epoch ms, whole seconds.
  final List<double> ts;
  int get length => rr.length;

  /// Beats whose second is in `[loSec, hiSec)`.
  Beats between(int loSec, int hiSec) {
    final rr2 = <double>[], ts2 = <double>[];
    for (var i = 0; i < length; i++) {
      final s = ts[i] ~/ 1000;
      if (s >= loSec && s < hiSec) {
        rr2.add(rr[i]);
        ts2.add(ts[i]);
      }
    }
    return Beats(rr2, ts2);
  }
}

class SynthBeats {
  const SynthBeats({
    this.seed = 1,
    this.seconds = 4 * 3600,
    this.startSec = 1760000000,
    this.ectopicPerMin = 0.3,
    this.missedPerMin = 0.1,
    this.extraPerMin = 0.1,
    this.noiseRunPerMin = 0.05,
    this.gapPerHour = 1.5,
    this.backwardsPerHour = 0.0,
    this.irregularBurst,
    this.irregularRangeMs = (400, 1200),
  });
  final int seed, seconds, startSec;
  final double ectopicPerMin, missedPerMin, extraPerMin, noiseRunPerMin;
  final double gapPerHour, backwardsPerHour;

  /// `(fromSecond, toSecond)` after the start: beats there are drawn at random
  /// over [irregularRangeMs] (sustained irregular rhythm).
  final (int, int)? irregularBurst;

  /// The interval range (ms) of that burst.
  final (int, int) irregularRangeMs;
}

/// Physiologically flavoured RR (drift + RSA at 0.25 Hz + LF + jitter) with the
/// artefacts above injected.
Beats synthBeats(SynthBeats c) {
  final rnd = math.Random(c.seed);
  final rr = <double>[], ts = <double>[];
  final endT = c.seconds.toDouble();
  var t = 0.0;
  final phase = rnd.nextDouble() * 6.28;
  void emit(double interval) {
    final v = interval.roundToDouble();
    t += v / 1000.0;
    rr.add(v);
    ts.add((c.startSec + t).floorToDouble() * 1000.0);
  }

  while (t < endT) {
    final bout = (math.sin(t / 1900.0 + c.seed) + 1) / 2;
    final bpm = 62 + 40 * bout * bout;
    final base = 60000.0 / bpm;
    final burst = c.irregularBurst;
    if (burst != null && t >= burst.$1 && t < burst.$2) {
      final (lo, hi) = c.irregularRangeMs;
      emit(lo + rnd.nextInt(hi - lo).toDouble());
      continue;
    }
    final v = base +
        30 * math.sin(2 * math.pi * 0.26 * t + phase) +
        28 * math.sin(2 * math.pi * 0.1 * t) +
        8 * (rnd.nextDouble() - .5) * 2;
    final beatMin = v / 60000.0;
    final u = rnd.nextDouble();
    var p = c.noiseRunPerMin * beatMin;
    if (u < p) {
      final len = 3 + rnd.nextInt(10);
      for (var k = 0; k < len; k++) {
        emit(250 + rnd.nextInt(2100).toDouble());
      }
      continue;
    }
    p += c.ectopicPerMin * beatMin;
    if (u < p) {
      emit(v * (0.55 + 0.15 * rnd.nextDouble()));
      emit(v * (1.3 + 0.2 * rnd.nextDouble()));
      continue;
    }
    p += c.missedPerMin * beatMin;
    if (u < p) {
      emit(v * (1.9 + 0.2 * rnd.nextDouble()));
      continue;
    }
    p += c.extraPerMin * beatMin;
    if (u < p) {
      final f = 0.35 + 0.3 * rnd.nextDouble();
      emit(v * f);
      emit(v * (1 - f));
      continue;
    }
    p += c.gapPerHour * beatMin / 60.0;
    if (u < p) {
      t += 5 + rnd.nextInt(896).toDouble();
      continue;
    }
    p += c.backwardsPerHour * beatMin / 60.0;
    if (u < p && ts.isNotEmpty) {
      emit(v);
      ts[ts.length - 1] = ts.last - 1000.0 * (1 + rnd.nextInt(3));
      continue;
    }
    emit(v);
  }
  return Beats(rr, ts);
}

class Accel {
  Accel(this.tsSec, this.ax, this.ay, this.az);
  final List<int> tsSec;
  final List<double> ax, ay, az;
  int get length => tsSec.length;
}

/// 1 Hz gravity vector over `[fromSec, toSec)`: long still stretches (|g| within
/// 0.02 g of 1) and motion bouts, now and then a second with no vector (all
/// zeros: the band's "absent" marker) and gaps with no row at all.
Accel synthAccel(int seed, int fromSec, int toSec,
    {double stillFraction = 0.6,
    double gapPerHour = 2.0,
    int boutMaxSec = 1500,
    int stillBoutMinSec = 30,
    int moveBoutMinSec = 30}) {
  final rnd = math.Random(seed);
  final ts = <int>[], ax = <double>[], ay = <double>[], az = <double>[];
  var still = true;
  var left = 60 + rnd.nextInt(1200);
  var s = fromSec;
  while (s < toSec) {
    if (rnd.nextDouble() < gapPerHour / 3600.0) {
      s += 5 + rnd.nextInt(300);
      continue;
    }
    if (--left <= 0) {
      still = rnd.nextDouble() < stillFraction;
      left = (still ? stillBoutMinSec : moveBoutMinSec) + rnd.nextInt(boutMaxSec);
    }
    double x, y, z;
    if (rnd.nextDouble() < 0.0008) {
      x = y = z = 0;
    } else if (still) {
      final jitter = (rnd.nextDouble() - .5) * (rnd.nextDouble() < 0.1 ? .08 : .01);
      x = 0.3 + (rnd.nextDouble() - .5) * .002;
      y = 0.8 + (rnd.nextDouble() - .5) * .002;
      z = math.sqrt(math.max(0.0, 1 - x * x - y * y)) + jitter;
    } else {
      x = (rnd.nextDouble() - .5) * 2.4;
      y = (rnd.nextDouble() - .5) * 2.4;
      z = 1 + (rnd.nextDouble() - .5) * 2.0;
    }
    ts.add(s);
    ax.add(x);
    ay.add(y);
    az.add(z);
    s++;
  }
  return Accel(ts, ax, ay, az);
}

/// The plain substrate the batch day functions read. Heart rate is a constant
/// plausible 70 (the curves under test never read it).
Substrate substrateOf(Beats b, Accel a, {String family = 'gen4'}) => Substrate(
      tsSec: a.tsSec,
      hr: List.filled(a.length, 70),
      rrTsMs: b.ts,
      rrMs: b.rr,
      ax: a.ax,
      ay: a.ay,
      az: a.az,
      spo2Red: List.filled(a.length, 1),
      spo2Ir: List.filled(a.length, 1),
      skinTemp: List.filled(a.length, 3000),
      skinContact: List.filled(a.length, 1),
      deviceFamily: family,
    );

/// The day-so-far of the fixture: beats with a second below [throughSec] and
/// accelerometer rows below it (what a database holding the data up to there
/// would give).
Substrate prefixSubstrate(Beats b, Accel a, int throughSec,
    {int lowSec = 0, String family = 'gen4'}) {
  final cut = a.tsSec.where((t) => t < throughSec).length;
  return substrateOf(
    b.between(lowSec, throughSec),
    Accel(a.tsSec.sublist(0, cut), a.ax.sublist(0, cut), a.ay.sublist(0, cut),
        a.az.sublist(0, cut)),
    family: family,
  );
}

/// Writes the fixture's seconds `[fromSec, toSec)` as the band's rows: one
/// `decoded_onehz` row per accelerometer second and every beat of those seconds
/// in `decoded_rr` (beats of a second share its `ts_ms`, `beat_index` counting
/// them). Heart rate 0 (the band's "no heart rate" marker) on purpose: the
/// stager then finds no sleep window, so the day has no night whose RR the
/// engine must read for the sleep window, and what these tests measure is the
/// day path alone. Any heart rate at all, still or moving, got a 2 hour "night"
/// staged out of a three hour daytime fixture.
Future<void> writeSeconds(Beats b, Accel a, int fromSec, int toSec,
    {int counterBase = 0}) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var i = 0; i < a.length; i++) {
    final ts = a.tsSec[i];
    if (ts < fromSec || ts >= toSec) continue;
    batch.rawInsert(
      'INSERT OR REPLACE INTO decoded_onehz '
      '(device_id, ts_ms, rec_ts, counter, hr, ax, ay, az, spo2_red_raw, '
      "spo2_ir_raw, skin_temp_raw, device_family) VALUES ('', ?, ?, ?, ?, ?, ?, ?, 1, 1, 3000, 'gen4')",
      [ts * 1000, ts, counterBase + ts, 0, a.ax[i], a.ay[i], a.az[i]],
    );
  }
  var lastSec = -1, idx = 0;
  for (var i = 0; i < b.length; i++) {
    final sec = b.ts[i] ~/ 1000;
    if (sec < fromSec || sec >= toSec) continue;
    idx = sec == lastSec ? idx + 1 : 0;
    lastSec = sec;
    batch.rawInsert(
      'INSERT OR REPLACE INTO decoded_rr '
      '(device_id, ts_ms, rec_ts, beat_index, rr_ts_ms, rr_ms) '
      "VALUES ('', ?, ?, ?, ?, ?)",
      [sec * 1000, sec, idx, b.ts[i].round(), b.rr[i].round()],
    );
  }
  await batch.commit(noResult: true);
}

/// JSON text of a curve as persisted ('t' and 'v' exactly), for bit-for-bit
/// comparison.
String curveText(List<Map<String, num>> c) =>
    c.map((m) => m.entries.map((e) => '${e.key}=${e.value}').join(',')).join(';');
