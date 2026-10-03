// A virtual WHOOP MG (8V): just enough of the band's ECG stream and haptic
// queue to try a gesture idea in a test before trying it on a wrist.
//
// It is a MODEL fitted to the Device lab logs of 2026-10-02 (16:53 and 18:17,
// one band, firmware as of that day), not a description from WHOOP. Each
// parameter says what it rests on; docs/hardware/whoop-mg-haptics-and-ecg.md
// has the evidence. When a lab run disagrees with the model, fix the model
// first (and say which log showed it), then the code.

import 'dart:math';

import 'ecg_trace.dart';

/// The live ECG stream after a start command, as packets with receipt times.
///
/// [touches] are the wearer's finger-on intervals, in ms since the stream's
/// first packet on the strap clock ([strapStart]).
class VirtualMgEcg {
  VirtualMgEcg({
    required this.touches,
    this.strapStart = 1790990000,
    this.strapAheadOfPhoneMs = 820,
    this.latencyMs = 150,
    this.settleMs = 2350,
    this.reacquireHoldMs = 1500,
    this.checkIndex = 76,
    this.zeroRate = 0.02,
    this.seed = 7,
  });

  final List<(int, int)> touches;

  /// Strap seconds of the first (empty) packet.
  final int strapStart;

  /// MEASURED, varies: the strap clock ran ~0.82 s ahead of the phone at
  /// 18:17 and ~0.15 s behind at 16:53. The gesture code must not care.
  final int strapAheadOfPhoneMs;

  /// MEASURED: packets reach the phone ~0.13–0.19 s after their newest sample.
  final int latencyMs;

  /// MEASURED: a finger already on the sensor shows from ~2.35 s after the
  /// stream's first sample (sample 86 of the third sampled packet), after a
  /// 13-sample blip at samples 36–48 of the first (49-sample) packet and a
  /// fully zero second packet.
  final int settleMs;

  /// FITTED (two re-touches): after a lift at L, a finger that came back at T
  /// shows at the first lead-on check at or after max(T, L + hold). The lab
  /// bounds hold to (1.16, 1.96] s; the wearers' real re-touch times were not
  /// logged.
  final int reacquireHoldMs;

  /// MEASURED (two re-touches): a returning finger shows at sample 76 of its
  /// packet, i.e. the band checks once per packet, 240 ms before its end.
  final int checkIndex;

  /// MEASURED: 96–100 of 100 samples are non-zero while touching (the trace
  /// crosses zero).
  final double zeroRate;
  final int seed;

  /// Packet k's newest-sample time, ms after the first packet. Packet 0 has
  /// no samples, packet 1 has 49, then 100 each, 1 s apart (MEASURED).
  static int _endMs(int k) => k == 0 ? 0 : 1010 + (k - 1) * 1000;
  static int _count(int k) => k == 0 ? 0 : k == 1 ? 49 : 100;

  int get _firstSampleMs => _endMs(1) - 490;

  /// When each touch becomes visible, or null when it never does.
  List<(int, int)> get visible {
    final out = <(int, int)>[];
    final settled = _firstSampleMs + settleMs;
    for (var i = 0; i < touches.length; i++) {
      final (a, b) = touches[i];
      int start;
      if (i == 0) {
        start = a <= settled ? settled : _nextCheck(a);
      } else {
        final lift = touches[i - 1].$2;
        start = _nextCheck(max(a, lift + reacquireHoldMs));
      }
      if (start < b) out.add((start, b));
    }
    return out;
  }

  /// The first lead-on check at or after [t]: sample [checkIndex] of a packet.
  int _nextCheck(int t) {
    for (var k = 2;; k++) {
      final c = _endMs(k) - (100 - checkIndex) * 10;
      if (c >= t) return c;
    }
  }

  bool _touchingInBlip(int t) =>
      touches.any((iv) => iv.$1 <= t && t < iv.$2);

  /// [seconds] of stream (packet 0 at time 0).
  List<TracePacket> packets(int seconds, {String tag = 'virtual'}) {
    final rnd = Random(seed);
    final vis = visible;
    final out = <TracePacket>[];
    for (var k = 0; _endMs(k) <= seconds * 1000; k++) {
      final n = _count(k);
      final end = _endMs(k);
      final samples = List<int>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        final t = end - (n - i) * 10;
        final blip = k == 1 && i >= 36 && _touchingInBlip(t);
        final on = blip || vis.any((v) => v.$1 <= t && t < v.$2);
        if (on && rnd.nextDouble() >= zeroRate) {
          samples[i] = 40 + rnd.nextInt(400) * (rnd.nextBool() ? 1 : -1);
        }
      }
      final strapMs = strapStart * 1000 + end;
      out.add(TracePacket(
        tag,
        DateTime.fromMillisecondsSinceEpoch(
            strapMs - strapAheadOfPhoneMs + latencyMs),
        r17(
          strapSeconds: strapMs ~/ 1000,
          subseconds: ((strapMs % 1000) * 32768 / 1000).round(),
          samples: samples,
          sequence: k,
        ),
      ));
    }
    return out;
  }
}

/// The band's haptic command queue. FITTED to the 2026-10-02 logs: the band
/// takes a command when idle and starts a busy window of [busyMs]; inside it,
/// it takes [queueDepth] - 1 more (played after the first: two pulses 300 ms
/// apart are felt as two) and drops the rest without a reply. A command
/// written ~1.25 s after the first of a pair was dropped, one written ~2.0 s
/// after played: busyMs lies between those.
class VirtualMgHaptics {
  VirtualMgHaptics({this.busyMs = 1500, this.queueDepth = 2});
  final int busyMs;
  final int queueDepth;

  int? _busySince;
  int _taken = 0;

  /// Every command: when it arrived (ms) and whether the band took it.
  final List<(int, bool)> log = [];

  bool command(int atMs) {
    final since = _busySince;
    bool ok;
    if (since == null || atMs - since >= busyMs) {
      _busySince = atMs;
      _taken = 1;
      ok = true;
    } else if (_taken < queueDepth) {
      _taken++;
      ok = true;
    } else {
      ok = false;
    }
    log.add((atMs, ok));
    return ok;
  }

  int get played => log.where((c) => c.$2).length;
}
