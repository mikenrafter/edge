// A virtual WHOOP MG: just enough of the band's ECG stream and haptic
// queue to try a gesture idea in a test before trying it on a wrist.
//
// It is a MODEL fitted to the Device lab logs of 2026-10-02 (16:53, 18:17 and
// 20:40, one band, firmware as of that day), not a description from WHOOP. Each
// parameter says what it rests on; docs/hardware/whoop-mg-haptics-and-ecg.md
// has the evidence. When a lab run disagrees with the model, fix the model
// first (and say which log showed it), then the code.

import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';

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
    this.dcOffset = 0,
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

  /// Added to EVERY sample, touching or not. A band with a DC level on its
  /// electrode reads a constant non-zero value with no finger on it, which is
  /// no contact once contact means "the signal moves" (ecgContactMask).
  final int dcOffset;

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
      final samples = List<int>.filled(n, dcOffset);
      for (var i = 0; i < n; i++) {
        final t = end - (n - i) * 10;
        final blip = k == 1 && i >= 36 && _touchingInBlip(t);
        final on = blip || vis.any((v) => v.$1 <= t && t < v.$2);
        if (on && rnd.nextDouble() >= zeroRate) {
          samples[i] =
              dcOffset + 40 + rnd.nextInt(400) * (rnd.nextBool() ? 1 : -1);
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
  /// [playMs] is how long THIS command keeps the band busy (the write to the
  /// event 100); [busyMs] when not given.
  String? command(int atMs, {int? playMs}) {
    String? reply;
    var played = false;
    if (atMs >= _busyUntil && atMs >= _deafUntil) {
      played = true;
      reply = 'pending';
      _busyUntil = atMs + (playMs ?? busyMs);
    } else if (atMs >= _deafUntil) {
      reply = 'pending';
      _deafUntil = atMs + deafMs;
    }
    log.add((atMs, played, reply));
    return reply;
  }

  int get played => log.where((c) => c.$2).length;
}

/// What one played command does: how long the band is busy (its event 60 to
/// its event 100) and how long the wearer feels it.
class MgPlayback {
  const MgPlayback(this.envelopeMs, this.feltMs);

  /// Event 60 to event 100.
  final int envelopeMs;

  /// The felt span of the buzzes (the wearer's reading), shorter than the
  /// envelope: the band's event 100 follows the last buzz by a tail.
  final int feltMs;
}

/// A virtual WHOOP MG's haptics: the band side of [BandHapticsPort], so the
/// real [HapticsService] can be driven against it. Behaviour is parameterised
/// here in code (nothing is read from the logs at run time); the lab logs only
/// VALIDATE it (test/virtual_mg_haptics_test.dart). Evidence:
/// docs/hardware/whoop-mg-haptics-and-ecg.md (L3, L4, L6).
///
/// What it does, by the clock package (so fake_async drives it):
///  * A command written while idle plays: event 60 [writeToFiredMs] after the
///    write, event 100 when playback ends. [playback] gives the length.
///  * A command written while it plays is answered "pending" and NOT played;
///    the next command is then ignored (no reply) for [deafMs].
///  * A command written after the 100 plays, even 30 ms after; one written
///    20 ms before it is dropped.
///  * [jitterSeed]: pick each length inside its measured range with a seeded
///    generator instead of the midpoint.
///  * [backlogAfterMs]: after each played command, deliver a burst of OLD 60
///    and 100 events (the band replays events late, in bursts).
///  * gen4 ([generation] 'gen4'): a short pulse, no events at all, so a caller
///    that waits for event 100 must fall back to its own playback time.
class VirtualMgBand implements BandHapticsPort {
  VirtualMgBand({
    String generation = 'gen5',
    int deafMs = 1100,
    this.writeToFiredMs = 15,
    this.jitterSeed,
    this.backlogAfterMs,
    this.onEvent,
  })  : _gen = generation,
        _core = VirtualMgHaptics(deafMs: deafMs),
        _jitter = jitterSeed == null ? null : Random(jitterSeed),
        _origin = clock.now();

  /// Time from an accepted write to the band's event 60 (L3: ~15 ms).
  final int writeToFiredMs;
  final int? jitterSeed;
  final int? backlogAfterMs;

  /// Where the band's events go; a test wires this to HapticsService.onBandEvent.
  void Function(StrapEvent e)? onEvent;

  final VirtualMgHaptics _core;
  final Random? _jitter;
  final DateTime _origin;
  String _gen;
  bool connected = true;

  @override
  bool get isConnected => connected;

  @override
  String? get generation => _gen;
  set generation(String? g) => _gen = g ?? 'gen4';

  bool get _gen5 => _gen == 'gen5';

  /// Every command the band was given, in order.
  final List<MgWrite> writes = [];

  /// Only the ones it played.
  List<MgWrite> get played => [for (final w in writes) if (w.played) w];

  /// Every event the band sent, live ones and backlog, with its send time.
  final List<(int, StrapEvent)> events = [];

  /// Milliseconds since this band was made.
  int get nowMs => clock.now().difference(_origin).inMilliseconds;

  // Measured event envelopes (event 60 to 100) of one slot, ms (L4): 47 alone
  // 0.77-1.03 s, 14 alone 0.53-0.91 s, 1 alone 0.22-0.61 s, and the pair
  // 47+152 1.07-1.36 s, which puts a 152 slot at 0.30-0.33 s. Listed slots
  // add up.
  static const Map<int, (int, int)> _slotEnvelope = {
    47: (770, 1030),
    14: (530, 910),
    1: (220, 610),
    152: (300, 330),
  };
  static const (int, int) _otherSlot = (400, 800);

  // What a loop byte above 1 adds to the envelope (L4): a single effect plays
  // barely longer, a pair about 1.96 s at 2 and 2.0 s at 3 (NOT a whole
  // repeat).
  static const Map<int, int> _loopExtraSingle = {2: 200, 3: 300};
  static const Map<int, int> _loopExtraMulti = {2: 745, 3: 785};

  // The wearer's felt span in sixteenths (min, max) of the commands measured
  // in L6, by "effects|loop". Anything else falls back to the envelope less a
  // 400 ms tail.
  static const Map<String, (int, int)> _felt = {
    '47|1': (4, 4),
    '14|1': (3, 4),
    '1|1': (2, 2),
    '47,152|1': (6, 7),
    '47|2': (6, 6),
    '47|3': (8, 8),
    '14|2': (6, 6),
    '14|3': (8, 8),
    '1|2': (3, 3),
    '1|3': (3, 3),
    '47,152|2': (10, 10),
    '47,152|3': (15, 15),
    '47,152,47,152|1': (15, 15),
    '47,152,47,152,47,152|1': (22, 22),
    '47,152,47|1': (13, 13),
    '14,152,14|1': (11, 11),
    '1,152,1|1': (8, 8),
    '47,152,47,152,47|1': (20, 20),
    '14,152,14,152,14|1': (18, 18),
    '1,152,1,152,1|1': (13, 13),
  };

  static const int _unitMs = 125;

  /// The playback of a command. Midpoints, or a draw inside each range when
  /// [jitter] is given.
  static MgPlayback playbackOf(List<int> effects, int loop, {Random? jitter}) {
    int pick(int lo, int hi) =>
        jitter == null ? (lo + hi) ~/ 2 : lo + jitter.nextInt(hi - lo + 1);
    var env = 0;
    for (final e in effects) {
      final r = _slotEnvelope[e] ?? _otherSlot;
      env += pick(r.$1, r.$2);
    }
    final l = loop.clamp(1, 3);
    if (l > 1) {
      env += (effects.length > 1 ? _loopExtraMulti : _loopExtraSingle)[l]!;
    }
    final f = _felt['${effects.join(',')}|$l'];
    final felt = f == null
        ? (env - 400).clamp(100, env)
        : pick(f.$1 * _unitMs, f.$2 * _unitMs);
    return MgPlayback(env, felt);
  }

  @override
  Future<bool> buzzBand({int holdMs = 0}) async {
    if (!connected) return false;
    if (_gen5) {
      // The engine's gen5 buzz: effect 47 then 152, overall loop 2 for a
      // hold of 500 ms or more.
      _submit(const [47, 152], holdMs >= 500 ? 2 : 1);
    } else {
      // gen4: one short pulse, no events. Its length is an assumption (not
      // measured): short enough that the per-tap rhythm's taps all play.
      _submit(const [0], 1, gen4Pulse: true);
    }
    return true;
  }

  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) async {
    if (!connected || !_gen5) return false;
    _submit(effects, loop);
    return true;
  }

  void _submit(List<int> effects, int loop, {bool gen4Pulse = false}) {
    final at = nowMs;
    final pb = gen4Pulse
        ? const MgPlayback(300, 250)
        : playbackOf(effects, loop, jitter: _jitter);
    final reply = _core.command(at, playMs: writeToFiredMs + pb.envelopeMs);
    final played = _core.log.last.$2;
    writes.add(MgWrite(at, List.of(effects), loop, played, reply, pb));
    if (!played) return;
    if (!_gen5) return; // gen4 sends no haptic events
    Timer(Duration(milliseconds: writeToFiredMs), () => _emit(60));
    Timer(Duration(milliseconds: writeToFiredMs + pb.envelopeMs),
        () => _emit(100));
    final b = backlogAfterMs;
    if (b != null) Timer(Duration(milliseconds: b), deliverBacklog);
  }

  void _emit(int id, {int ageSeconds = 0}) {
    final now = clock.now();
    final e = StrapEvent(
      eventId: id,
      tsEpoch: now.millisecondsSinceEpoch ~/ 1000 - ageSeconds,
      receivedAt: now,
      hex: '',
      deviceId: 'virtual-mg',
    );
    events.add((nowMs, e));
    onEvent?.call(e);
  }

  /// The band replaying old events in a burst (L4: about 25 events 17-80 s
  /// old). They reach the phone now; they did not just happen.
  void deliverBacklog({int count = 6}) {
    for (var i = 0; i < count; i++) {
      _emit(i.isEven ? 60 : 100, ageSeconds: 17 + (i * 63) ~/ count);
    }
  }
}

/// One command the virtual band was given.
class MgWrite {
  const MgWrite(
      this.atMs, this.effects, this.loop, this.played, this.reply, this.playback);
  final int atMs;
  final List<int> effects;
  final int loop;
  final bool played;
  final String? reply;
  final MgPlayback playback;

  /// When the wearer feels it start (the event 60), ms on the band's clock.
  int firedMs(int writeToFiredMs) => atMs + writeToFiredMs;
}
