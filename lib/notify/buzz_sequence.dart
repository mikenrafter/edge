// buzz_sequence.dart — a notification's buzz rhythm, as the user taps it.
//
// The band takes one fixed single-buzz command; a "pattern" here is that
// command repeated at chosen offsets, so a rhythm is just a list of
// milliseconds-from-the-first-buzz. Everything else (the recorder that turns
// taps into offsets, the player that writes them) lives here and is pure
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
  static const minGapMs = 150;
  static const maxGapMs = 2000;

  /// 1–[maxBuzzes] entries, first 0, each gap in [[minGapMs], [maxGapMs]].
  BuzzSequence(List<int> offsetsMs)
      : offsetsMs = List.unmodifiable(_validated(offsetsMs));

  final List<int> offsetsMs;

  int get length => offsetsMs.length;

  /// From the first write to the last one's start.
  Duration get playTime => Duration(milliseconds: offsetsMs.last);

  /// How long a dispatcher should wait for the whole rhythm to be written:
  /// its play time plus room for the last write to be acknowledged.
  Duration get transportTimeout => playTime + const Duration(seconds: 5);

  static List<int> _validated(List<int> o) {
    if (o.isEmpty || o.length > maxBuzzes) {
      throw ArgumentError.value(o.length, 'offsetsMs', 'need 1–$maxBuzzes buzzes');
    }
    if (o.first != 0) {
      throw ArgumentError.value(o.first, 'offsetsMs', 'first buzz must be at 0');
    }
    for (var i = 1; i < o.length; i++) {
      final gap = o[i] - o[i - 1];
      if (gap < minGapMs || gap > maxGapMs) {
        throw ArgumentError.value(
            gap, 'offsetsMs', 'gap must be $minGapMs–$maxGapMs ms');
      }
    }
    return o;
  }

  List<int> toJson() => offsetsMs;

  factory BuzzSequence.fromJson(Object? json) {
    if (json is! List || json.any((v) => v is! int)) {
      throw const FormatException('A buzz sequence is a list of whole ms');
    }
    try {
      return BuzzSequence(json.cast<int>());
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
      other is BuzzSequence && listEquals(other.offsetsMs, offsetsMs);

  @override
  int get hashCode => Object.hashAll(offsetsMs);

  @override
  String toString() => 'BuzzSequence($offsetsMs)';
}

/// Turns taps into a [BuzzSequence]. The first tap starts the take (and tells
/// the caller, so the phone can buzz as feedback); it ends 2 s after the last
/// accepted tap or at the [BuzzSequence.maxBuzzes]th tap.
class BuzzRecorder {
  BuzzRecorder({this.onStart, this.onDone});

  final VoidCallback? onStart;
  final void Function(BuzzSequence)? onDone;

  static const _idle = Duration(seconds: 2);

  final List<int> _offsets = [];
  DateTime? _first;
  Timer? _timer;
  BuzzSequence? _result;

  bool get recording => _first != null && _result == null;
  BuzzSequence? get result => _result;

  void tap() {
    if (_result != null) return;
    final now = clock.now();
    final first = _first;
    if (first == null) {
      _first = now;
      _offsets.add(0);
      onStart?.call();
    } else {
      final at = now.difference(first).inMilliseconds;
      if (at - _offsets.last < BuzzSequence.minGapMs) return;
      _offsets.add(at);
    }
    _timer?.cancel();
    if (_offsets.length >= BuzzSequence.maxBuzzes) {
      _finish();
    } else {
      _timer = Timer(_idle, _finish);
    }
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    final r = _result = BuzzSequence(_offsets);
    onDone?.call(r);
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _first = null;
    _offsets.clear();
    _result = null;
  }

  void dispose() => _timer?.cancel();
}

/// Writes [s] as single buzzes, step i at `offsetsMs[i]` after the call (not
/// after the previous write). A lost link, a refused write or a throw stops
/// the rest and returns false; never throws. True only if every step landed.
Future<bool> playBuzzSequence(
  BuzzSequence s, {
  required Future<bool> Function() buzz,
  required bool Function() isConnected,
}) async {
  final watch = clock.stopwatch()..start();
  try {
    for (var i = 0; i < s.length; i++) {
      final wait = s.offsetsMs[i] - watch.elapsedMilliseconds;
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      if (!isConnected()) return false;
      if (!await buzz()) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}
