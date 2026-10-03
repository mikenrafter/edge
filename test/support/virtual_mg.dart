// A virtual WHOOP MG (8V): just enough of the band's ECG stream and haptic
// queue to try a gesture idea in a test before trying it on a wrist.
//
// It is a MODEL fitted to the Device lab logs of 2026-10-02 (16:53, 18:17 and
// 20:40, one band, firmware as of that day), not a description from WHOOP. Each
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
    this.touchLatencyMs = 1900,
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

  /// MEASURED (20:40, replacing the earlier "re-acquire hold after a lift"
  /// fit, which the longer-lift touches contradicted): a touch becomes visible
  /// ~1.9 s after the finger lands (2.2–2.4 s after the cue, reaction
  /// included), REGARDLESS of how long the lift before it was (0.4–2.5 s).
  /// Lifts show within ~0.3 s. A touch that lifts before the check lands never
  /// shows (300 ms taps never did).
  final int touchLatencyMs;

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
  ///
  /// The band checks for a finger on a 100 ms grid (MEASURED, five contact
  /// starts: samples 6, 16, 46, 56, 66 of their packets, i.e. every sample
  /// ≡ 6 mod 10, which is every time ≡ 70 mod 100 here). A touch [a, b) shows
  /// from the first grid point at or after a + [touchLatencyMs], and not at
  /// all when that is at or after b. The first touch, when the finger is
  /// already on as the stream starts, shows at the settle time instead.
  List<(int, int)> get visible {
    final out = <(int, int)>[];
    final settled = _firstSampleMs + settleMs;
    for (var i = 0; i < touches.length; i++) {
      final (a, b) = touches[i];
      final start =
          (i == 0 && a <= settled) ? settled : _nextCheck(a + touchLatencyMs);
      if (start < b) out.add((start, b));
    }
    return out;
  }

  /// The first check at or after [t]: sample 6 of a packet, every 100 ms (time
  /// ≡ 70 mod 100 from the second 100-sample packet on).
  int _nextCheck(int t) {
    final c = t - (t - 70) % 100 + ((t - 70) % 100 == 0 ? 0 : 100);
    return max(c, 1070);
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

/// The band's haptic command handling. FITTED to the 2026-10-02 logs (16:53,
/// 18:17, and 20:40, which replaced the earlier "queue of two" reading):
///  * a command written while the band is IDLE plays (event 60 ~15 ms later)
///    and the band is busy for [busyMs] (its event 100 comes 1.08–1.50 s
///    after the 60). One command is felt as ONE "bzz-bzz".
///  * a command written while it plays (before the 100) is answered "pending"
///    and NOT played (no 60) — it is swallowed — and the band then ignores the
///    next command entirely (no reply, not played) for [deafMs]: 0.95 s later
///    ignored, 1.27 s later played.
///  * a command written after the 100 plays, even 0.4 s after it.
/// 20:40 timings it must reproduce: writes at 0, 1236, 2505 play the first and
/// third; 0, 1875, 3400 play all three.
class VirtualMgHaptics {
  VirtualMgHaptics({this.busyMs = 1500, this.deafMs = 1100});

  /// How long a played command keeps the band busy (the 60 to 100 gap).
  final int busyMs;

  /// How long the band ignores everything after it swallowed a command.
  final int deafMs;

  int _busyUntil = 0;
  int _deafUntil = 0;

  /// Every command: when it arrived (ms), whether the band played it, and what
  /// it answered.
  final List<(int, bool, String?)> log = [];

  /// The band's reply: 'pending' (it answered; played or swallowed) or null
  /// (it said nothing: it was deaf). Whether it PLAYED is in [log]/[played].
  String? command(int atMs) {
    String? reply;
    var played = false;
    if (atMs >= _busyUntil && atMs >= _deafUntil) {
      played = true;
      reply = 'pending';
      _busyUntil = atMs + busyMs;
    } else if (atMs >= _deafUntil) {
      reply = 'pending';
      _deafUntil = atMs + deafMs;
    }
    log.add((atMs, played, reply));
    return reply;
  }

  int get played => log.where((c) => c.$2).length;
}
