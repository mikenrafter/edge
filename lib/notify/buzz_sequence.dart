// buzz_sequence.dart — a notification's buzz rhythm, as the user taps it.
//
// A pattern preserves press starts and hold durations. The recorder and
// player live here and are pure
// timing: no BLE, no storage, no widgets.
//
// Playback runs inside ONE AlertDispatcher delivery (the sequence is the band
// transport), so the dispatcher's claim covers the whole rhythm and a
// re-dispatch of the same event plays nothing.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show VoidCallback, listEquals;

class BuzzSequence {
  static const maxBuzzes = 8;
  static const minGapMs = 1;
  static const maxGapMs = 2000;

  /// Offsets describe press starts; durations preserve the time held down.
  BuzzSequence(List<int> offsetsMs, {List<int>? durationsMs})
    : offsetsMs = List.unmodifiable(offsetsMs),
      durationsMs = List.unmodifiable(
        durationsMs ?? List.filled(offsetsMs.length, 0),
      ) {
    _validate();
  }

  final List<int> offsetsMs;
  final List<int> durationsMs;

  int get length => offsetsMs.length;

  Duration get playTime =>
      Duration(milliseconds: offsetsMs.last + durationsMs.last);

  /// Each step is one write (no reply is waited for), so a short allowance per
  /// step on top of the time the rhythm itself takes.
  Duration get transportTimeout => playTime + Duration(seconds: 2 * length + 1);

  void _validate() {
    if (offsetsMs.isEmpty ||
        offsetsMs.length > maxBuzzes ||
        durationsMs.length != offsetsMs.length) {
      throw ArgumentError('Need 1–$maxBuzzes matching offsets and durations');
    }
    if (offsetsMs.first != 0 || durationsMs.any((d) => d < 0)) {
      throw ArgumentError(
        'First offset must be zero and durations nonnegative',
      );
    }
    for (var i = 1; i < length; i++) {
      final gap = offsetsMs[i] - offsetsMs[i - 1] - durationsMs[i - 1];
      if (gap < minGapMs || gap > maxGapMs) {
        throw ArgumentError.value(
          gap,
          'offsetsMs',
          'release gap must be $minGapMs–$maxGapMs ms',
        );
      }
    }
  }

  Object toJson() => durationsMs.every((d) => d == 0)
      ? offsetsMs
      : {'offsetsMs': offsetsMs, 'durationsMs': durationsMs};

  factory BuzzSequence.fromJson(Object? json) {
    final Object? offsets = json is Map ? json['offsetsMs'] : json;
    final Object? durations = json is Map ? json['durationsMs'] : null;
    if (offsets is! List ||
        offsets.any((v) => v is! int) ||
        (json is Map &&
            (durations is! List || durations.any((v) => v is! int)))) {
      throw const FormatException('A buzz sequence needs whole-ms lists');
    }
    try {
      return BuzzSequence(
        offsets.cast<int>(),
        durationsMs: durations == null ? null : (durations as List).cast<int>(),
      );
    } on ArgumentError catch (e) {
      throw FormatException('Invalid buzz sequence: ${e.message}');
    }
  }

  /// The default for the rule at registry [index]: nine distinct rhythms,
  /// count-major (1–3 buzzes) over gaps of 0.5, 1 and 1.5 s, then repeating.
  static BuzzSequence defaultFor(int index) {
    if (index < 0) throw ArgumentError.value(index, 'index', 'must be >= 0');
    final i = index % 9;
    final count = i % 3 + 1;
    final gap = const [500, 1000, 1500][i ~/ 3];
    return BuzzSequence([for (var k = 0; k < count; k++) k * gap]);
  }

  @override
  bool operator ==(Object other) =>
      other is BuzzSequence &&
      listEquals(other.offsetsMs, offsetsMs) &&
      listEquals(other.durationsMs, durationsMs);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(offsetsMs), Object.hashAll(durationsMs));

  @override
  String toString() => 'BuzzSequence($offsetsMs, durationsMs: $durationsMs)';
}

/// Turns taps into a [BuzzSequence]. The first tap starts the take (and tells
/// the caller, so the phone can buzz as feedback); it ends 2 s after the last
/// release or at the [BuzzSequence.maxBuzzes]th completed press.
class BuzzRecorder {
  BuzzRecorder({this.onStart, this.onDone});

  final VoidCallback? onStart;
  final void Function(BuzzSequence)? onDone;
  static const _idle = Duration(seconds: 2);
  final List<int> _offsets = [];
  final List<int> _durations = [];
  DateTime? _first;
  DateTime? _pressed;
  DateTime? _lastRelease;
  Timer? _timer;
  BuzzSequence? _result;

  bool get recording => (_first != null || _pressed != null) && _result == null;
  BuzzSequence? get result => _result;

  /// Accessibility actions have no measured hold duration.
  void tap({DateTime? at}) {
    final now = at ?? clock.now();
    pressStart(at: now);
    pressEnd(at: now);
  }

  void pressStart({DateTime? at}) {
    if (_result != null || _pressed != null) return;
    final now = at ?? clock.now();
    final release = _lastRelease;
    if (release != null &&
        now.difference(release).inMilliseconds > BuzzSequence.maxGapMs) {
      _finish();
      return;
    }
    if (_first != null &&
        now.difference(_first!).inMilliseconds -
                _offsets.last -
                _durations.last <
            BuzzSequence.minGapMs) {
      return;
    }
    _timer?.cancel();
    _pressed = now;
    if (_first == null) onStart?.call();
  }

  void pressEnd({DateTime? at}) {
    final start = _pressed;
    if (start == null || _result != null) return;
    _pressed = null;
    final now = at ?? clock.now();
    _first ??= start;
    _offsets.add(start.difference(_first!).inMilliseconds);
    _durations.add(now.difference(start).inMilliseconds.clamp(0, 1 << 31));
    _lastRelease = now;
    _scheduleFinish(now);
  }

  void pressCancel({DateTime? at}) {
    if (_pressed == null) return;
    _pressed = null;
    if (_offsets.isNotEmpty) _scheduleFinish(at ?? clock.now());
  }

  void _scheduleFinish(DateTime now) {
    _timer?.cancel();
    // A cancelled contact does not extend the completed take's idle window.
    final remaining = _lastRelease!.add(_idle).difference(now);
    if (_offsets.length >= BuzzSequence.maxBuzzes || remaining <= Duration.zero) {
      _finish();
    } else {
      _timer = Timer(remaining, _finish);
    }
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    if (_offsets.isEmpty || _result != null) return;
    final r = _result = BuzzSequence(_offsets, durationsMs: _durations);
    onDone?.call(r);
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _first = null;
    _pressed = null;
    _lastRelease = null;
    _offsets.clear();
    _durations.clear();
    _result = null;
  }

  void dispose() => _timer?.cancel();
}

/// Preserve the hold and release gap even when command acknowledgement is slow.
/// Failed or disconnected deliveries stop the remaining steps. Without a
/// duration-aware [buzzForDuration], a held press plays as a short buzz (the
/// rhythm is kept; it never fails the sequence).
///
/// A step whose write does not answer within [stepTimeout] fails the sequence
/// and no later step is sent: the dispatcher gives up on a slow band at its own
/// deadline, and a stuck write finishing late must not then play the rest of the
/// rhythm after the caller has already moved on.
Future<bool> playBuzzSequence(
  BuzzSequence s, {
  required Future<bool> Function() buzz,
  Future<bool> Function(int holdMs)? buzzForDuration,
  required bool Function() isConnected,
  Duration stepTimeout = const Duration(seconds: 5),
}) async {
  final watch = clock.stopwatch()..start();
  try {
    for (var i = 0; i < s.length; i++) {
      if (!isConnected()) return false;
      final start = watch.elapsedMilliseconds;
      final ok = await (buzzForDuration == null
              ? buzz()
              : buzzForDuration(s.durationsMs[i]))
          .timeout(stepTimeout);
      if (!ok) return false;
      final remainingHold =
          start + s.durationsMs[i] - watch.elapsedMilliseconds;
      if (remainingHold > 0) {
        await Future<void>.delayed(Duration(milliseconds: remainingHold));
      }
      if (i + 1 < s.length) {
        final gap = s.offsetsMs[i + 1] - s.offsetsMs[i] - s.durationsMs[i];
        final nextStart = start + s.durationsMs[i] + gap;
        // A late reply still gets the full release interval after completion.
        final wait = watch.elapsedMilliseconds > nextStart
            ? gap
            : nextStart - watch.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}
