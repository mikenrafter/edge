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
import 'package:collection/collection.dart' show ListEquality;

import '../gestures/pattern_transcript.dart';
import '../haptics/haptic_priority.dart';

// Not package:flutter/foundation.dart: this file and what imports it are
// plain Dart, so tool/build_haptic_vocab.dart runs under `dart run`.
bool _listEquals<T>(List<T>? a, List<T>? b) =>
    const ListEquality<Object?>().equals(a, b);

/// One band command of a plan compiled when a rule was saved: the waveform
/// slots, how often the band loops them, and the wait after the previous
/// command's "ended" event before writing it (0 for the first).
class BakedStep {
  BakedStep({
    required List<int> effects,
    required this.loop,
    required this.delayMs,
  }) : effects = List.unmodifiable(effects);

  final List<int> effects;
  final int loop;
  final int delayMs;

  Map<String, Object> toJson() => {
    'effects': effects,
    'loop': loop,
    'delayMs': delayMs,
  };

  factory BakedStep.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('A baked step is a map');
    }
    final effects = json['effects'];
    final loop = json['loop'];
    final delay = json['delayMs'];
    if (effects is! List ||
        effects.isEmpty ||
        effects.any((v) => v is! int) ||
        loop is! int ||
        loop < 1 ||
        delay is! int ||
        delay < 0) {
      throw const FormatException(
        'A baked step needs effects, a loop of at least 1 and a delay',
      );
    }
    return BakedStep(effects: effects.cast<int>(), loop: loop, delayMs: delay);
  }

  @override
  bool operator ==(Object other) =>
      other is BakedStep &&
      _listEquals(other.effects, effects) &&
      other.loop == loop &&
      other.delayMs == delayMs;

  @override
  int get hashCode => Object.hash(Object.hashAll(effects), loop, delayMs);

  @override
  String toString() => 'BakedStep($effects x$loop, +${delayMs}ms)';
}

class BuzzSequence {
  static const maxBuzzes = 8;
  static const minGapMs = 1;
  static const maxGapMs = 2000;

  /// The most commands a baked plan holds: the compiler's own limit, so a
  /// stored plan can never be longer than one it could have produced.
  static const maxBakedSteps = 8;

  /// Offsets describe press starts; durations preserve the time held down.
  BuzzSequence(
    List<int> offsetsMs, {
    List<int>? durationsMs,
    this.notes,
    this.profileId,
    this.profileVersion,
    List<BakedStep>? bakedSteps,
    this.bakedRuntimeMs,
    this.patternId,
    this.priority = HapticPriority.rhythm,
  }) : offsetsMs = List.unmodifiable(offsetsMs),
      durationsMs = List.unmodifiable(
        durationsMs ?? List.filled(offsetsMs.length, 0),
      ),
      bakedSteps = bakedSteps == null ? null : List.unmodifiable(bakedSteps) {
    _validate();
  }

  final List<int> offsetsMs;
  final List<int> durationsMs;

  /// The rhythm as notes (a PatternTranscript code such as
  /// "N4mf R2 N1mf"), the device profile they were made for, and the plan
  /// compiled from them when the rule was saved. All absent for a rule saved
  /// before this existed, or on a band with no measured profile.
  final String? notes;
  final String? profileId;
  final int? profileVersion;

  /// The commands compiled at save time. Delivery plays these as stored when
  /// [profileId] matches the band, so a later vocabulary update never changes
  /// a saved rule.
  final List<BakedStep>? bakedSteps;

  /// How long the baked plan is felt at its longest, in ms, as measured when
  /// it was compiled. Delivery judges the runtime cap by it. Null for a rule
  /// saved before this existed (the runtime is then worked out from the
  /// profile) and whenever there is no baked plan.
  final int? bakedRuntimeMs;

  /// The stored pattern (HapticPatternStore) this rhythm is a snapshot of,
  /// or null when it was made by hand. Delivery never reads it; editing or
  /// deleting the stored pattern rewrites the snapshots that carry it.
  final String? patternId;

  /// What the compiler gives up first when the notes cannot be played as
  /// written. Rhythm is the default and is not written to JSON.
  final HapticPriority priority;

  /// The same rhythm with the given values replaced; the others are kept.
  /// [clearPatternId] drops the pattern id (the rhythm stays). A new
  /// [bakedSteps] without a [bakedRuntimeMs] drops the old runtime: it
  /// described the plan being replaced.
  BuzzSequence copyWith({
    String? notes,
    String? profileId,
    int? profileVersion,
    List<BakedStep>? bakedSteps,
    int? bakedRuntimeMs,
    String? patternId,
    bool clearPatternId = false,
    HapticPriority? priority,
  }) => BuzzSequence(
    offsetsMs,
    durationsMs: durationsMs,
    notes: notes ?? this.notes,
    profileId: profileId ?? this.profileId,
    profileVersion: profileVersion ?? this.profileVersion,
    bakedSteps: bakedSteps ?? this.bakedSteps,
    bakedRuntimeMs: bakedSteps != null
        ? bakedRuntimeMs
        : bakedRuntimeMs ?? this.bakedRuntimeMs,
    patternId: clearPatternId ? null : patternId ?? this.patternId,
    priority: priority ?? this.priority,
  );

  int get length => offsetsMs.length;

  Duration get playTime =>
      Duration(milliseconds: offsetsMs.last + durationsMs.last);

  /// Each step is one write (no reply is waited for), so a short allowance per
  /// step on top of the time the rhythm itself takes.
  Duration get transportTimeout => playTime + Duration(seconds: 2 * length + 1);

  void _validate() {
    final plan = bakedSteps;
    if (plan != null && plan.length > maxBakedSteps) {
      throw ArgumentError.value(
        plan.length,
        'bakedSteps',
        'a baked plan has at most $maxBakedSteps commands',
      );
    }
    final runtime = bakedRuntimeMs;
    if (runtime != null && (plan == null || runtime < 0)) {
      throw ArgumentError.value(
        runtime,
        'bakedRuntimeMs',
        'must be nonnegative and come with a baked plan',
      );
    }
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

  /// The old list or map form is written unchanged; the notes and profile, and
  /// the baked 'plan' appear only when they are set. The old 'extended' flag is
  /// never written (see [fromJson]).
  Object toJson() {
    final withNotes = notes != null;
    final plan = bakedSteps;
    if (!withNotes &&
        plan == null &&
        patternId == null &&
        priority == HapticPriority.rhythm) {
      return durationsMs.every((d) => d == 0)
          ? offsetsMs
          : {'offsetsMs': offsetsMs, 'durationsMs': durationsMs};
    }
    return {
      'offsetsMs': offsetsMs,
      'durationsMs': durationsMs,
      if (withNotes) 'notes': notes,
      if (profileId != null) 'profileId': profileId,
      if (profileVersion != null) 'profileVersion': profileVersion,
      if (plan != null) 'plan': [for (final b in plan) b.toJson()],
      if (bakedRuntimeMs != null) 'bakedRuntimeMs': bakedRuntimeMs,
      if (patternId != null) 'patternId': patternId,
      if (priority != HapticPriority.rhythm) 'priority': priority.name,
    };
  }

  factory BuzzSequence.fromJson(Object? json) {
    final Object? offsets = json is Map ? json['offsetsMs'] : json;
    final Object? durations = json is Map ? json['durationsMs'] : null;
    // An 'extended' key from before the full vocabulary became the only mode
    // is not read: it parses and is dropped.
    final Object? notes = json is Map ? json['notes'] : null;
    final Object? profileId = json is Map ? json['profileId'] : null;
    final Object? profileVersion = json is Map ? json['profileVersion'] : null;
    final Object? plan = json is Map ? json['plan'] : null;
    final Object? runtime = json is Map ? json['bakedRuntimeMs'] : null;
    final Object? patternId = json is Map ? json['patternId'] : null;
    final Object? priority = json is Map ? json['priority'] : null;
    if (priority != null &&
        (priority is! String ||
            !HapticPriority.values.any((p) => p.name == priority))) {
      throw const FormatException('A buzz sequence priority is rhythm or dynamics');
    }
    if (patternId != null && patternId is! String) {
      throw const FormatException('A buzz sequence pattern id is a string');
    }
    if (notes != null && notes is! String) {
      throw const FormatException('A buzz sequence notes value is a string');
    }
    if (notes is String) {
      try {
        PatternTranscript.parseCode(notes);
      } on FormatException {
        throw const FormatException('A buzz sequence notes value must parse');
      } on ArgumentError {
        throw const FormatException('A buzz sequence notes value must parse');
      }
    }
    if (profileId != null && profileId is! String) {
      throw const FormatException('A buzz sequence profile id is a string');
    }
    if (profileVersion != null && profileVersion is! int) {
      throw const FormatException('A buzz sequence profile version is an int');
    }
    List<BakedStep>? baked;
    if (plan != null) {
      if (plan is! List || plan.isEmpty) {
        throw const FormatException('A buzz sequence plan is a list of steps');
      }
      if (plan.length > BuzzSequence.maxBakedSteps) {
        throw const FormatException(
          'A buzz sequence plan has at most ${BuzzSequence.maxBakedSteps} steps',
        );
      }
      baked = [for (final b in plan) BakedStep.fromJson(b)];
    }
    if (runtime != null && (runtime is! int || runtime < 0 || baked == null)) {
      throw const FormatException(
        'A buzz sequence plan runtime is a whole ms count and needs a plan',
      );
    }
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
        notes: notes as String?,
        profileId: profileId as String?,
        profileVersion: profileVersion as int?,
        bakedSteps: baked,
        bakedRuntimeMs: runtime as int?,
        patternId: patternId as String?,
        priority: priority == null
            ? HapticPriority.rhythm
            : HapticPriority.values.byName(priority as String),
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
      _listEquals(other.offsetsMs, offsetsMs) &&
      _listEquals(other.durationsMs, durationsMs) &&
      other.notes == notes &&
      other.profileId == profileId &&
      other.profileVersion == profileVersion &&
      other.bakedRuntimeMs == bakedRuntimeMs &&
      other.patternId == patternId &&
      other.priority == priority &&
      _sameSteps(other.bakedSteps, bakedSteps);

  static bool _sameSteps(List<BakedStep>? a, List<BakedStep>? b) =>
      a == null || b == null ? a == b : _listEquals(a, b);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(offsetsMs),
    Object.hashAll(durationsMs),
    notes,
    profileId,
    profileVersion,
    bakedSteps == null ? null : Object.hashAll(bakedSteps!),
    bakedRuntimeMs,
    patternId,
    priority,
  );

  @override
  String toString() =>
      'BuzzSequence($offsetsMs, durationsMs: $durationsMs'
      '${priority == HapticPriority.rhythm ? '' : ', priority: ${priority.name}'}'
      '${notes == null ? '' : ', notes: $notes'})';
}

/// Turns taps into a [BuzzSequence]. The first tap starts the take (and tells
/// the caller, so the phone can buzz as feedback); it ends 2 s after the last
/// release or at the [BuzzSequence.maxBuzzes]th completed press.
class BuzzRecorder {
  BuzzRecorder({this.onStart, this.onDone});

  final void Function()? onStart;
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

/// What a band buzz delivery may have done to the band, for deciding whether a
/// durable alert claim can be given back (review finding H).
///
/// Only [rejected] is safe to retry: nothing could have reached the band. After
/// [partial] a retry would replay the pulses that already played; after
/// [unknown] a queued write may still land, so a retry would buzz twice.
enum BuzzDelivery {
  /// Every step was written.
  complete,

  /// Nothing was (or could have been) written: not connected, or the first
  /// write definitively failed.
  rejected,

  /// At least one step was written and a later one was not.
  partial,

  /// A step did not answer in time. Its write may still land.
  unknown,
}

/// Preserve the hold and release gap even when command acknowledgement is slow.
/// Failed or disconnected deliveries stop the remaining steps. Without a
/// duration-aware [buzzForDuration], a held press plays as a short buzz (the
/// rhythm is kept; it never fails the sequence).
///
/// A step whose write does not answer within [stepTimeout] ends the sequence as
/// [BuzzDelivery.unknown] and no later step is sent: the dispatcher gives up on a
/// slow band at its own deadline, and a stuck write finishing late must not then
/// play the rest of the rhythm after the caller has already moved on. The stuck
/// write itself may still land, which is why that is NOT [BuzzDelivery.rejected].
Future<BuzzDelivery> deliverBuzzSequence(
  BuzzSequence s, {
  required Future<bool> Function() buzz,
  Future<bool> Function(int holdMs)? buzzForDuration,
  required bool Function() isConnected,
  Duration stepTimeout = const Duration(seconds: 5),
}) async {
  final watch = clock.stopwatch()..start();
  var written = 0;
  BuzzDelivery failed() =>
      written > 0 ? BuzzDelivery.partial : BuzzDelivery.rejected;
  try {
    for (var i = 0; i < s.length; i++) {
      if (!isConnected()) return failed();
      final start = watch.elapsedMilliseconds;
      final bool ok;
      try {
        ok = await (buzzForDuration == null
                ? buzz()
                : buzzForDuration(s.durationsMs[i]))
            .timeout(stepTimeout);
      } on TimeoutException {
        return BuzzDelivery.unknown;
      }
      if (!ok) return failed();
      written++;
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
    return BuzzDelivery.complete;
  } catch (_) {
    return failed();
  }
}

/// [deliverBuzzSequence] reduced to "was every step written". Callers that
/// decide anything durable on the result (an alert claim) must use
/// [deliverBuzzSequence]: `false` here does not say whether the band buzzed.
Future<bool> playBuzzSequence(
  BuzzSequence s, {
  required Future<bool> Function() buzz,
  Future<bool> Function(int holdMs)? buzzForDuration,
  required bool Function() isConnected,
  Duration stepTimeout = const Duration(seconds: 5),
}) async =>
    await deliverBuzzSequence(
      s,
      buzz: buzz,
      buzzForDuration: buzzForDuration,
      isConnected: isConnected,
      stepTimeout: stepTimeout,
    ) ==
    BuzzDelivery.complete;
