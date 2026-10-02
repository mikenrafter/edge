// wake_settings.dart — the Natural Wake / Gradual Wake settings model, the
// timeline built from it, and the Gradual schedule. Pure: no DB, no BLE, no
// clock. (The UI-facing API is WakeController, in wake_controller.dart.)
//
// Two independent features replace the single Smart Wake window:
//   * Natural Wake — an early haptic during estimated REM inside [T-N, T).
//   * Gradual Wake — an escalating haptic cadence beginning at T-G.
// T is the must-be-up-by time. The fixed native band alarm at T is armed in
// every configuration (neither, Natural, Gradual, both); nothing here can move
// or remove it.

import '../notify/buzz_sequence.dart';

// ── windows ──────────────────────────────────────────────────────────────────

const int kWakeWindowStepMinutes = 15;
const int kWakeWindowMaxMinutes = 120;

/// 0 (off) or 15..120 in 15-minute steps.
bool isValidWakeWindow(int minutes) =>
    minutes == 0 ||
    (minutes >= kWakeWindowStepMinutes &&
        minutes <= kWakeWindowMaxMinutes &&
        minutes % kWakeWindowStepMinutes == 0);

/// Nearest valid window (ties round up), clamped to 0..120. A positive value
/// never normalises to 0: someone who had a window keeps one. For migrating
/// legacy Smart Wake minutes, which were not constrained to steps.
int normalizeWakeWindow(int minutes) {
  if (minutes <= 0) return 0;
  final steps = (minutes / kWakeWindowStepMinutes).round();
  final clamped = steps.clamp(1, kWakeWindowMaxMinutes ~/ kWakeWindowStepMinutes);
  return clamped * kWakeWindowStepMinutes;
}

// ── Gradual pattern / cadence ───────────────────────────────────────────────

enum GradualPattern {
  /// One buzz at the first step, escalating to a few buzzes by the last.
  ramp,

  /// One buzz at every step.
  steady;

  static GradualPattern parse(Object? name) =>
      GradualPattern.values.where((p) => p.name == name).firstOrNull ??
      GradualPattern.ramp;
}

const int kGradualCadenceMinSec = 60;
const int kGradualCadenceMaxSec = 900;
const int kGradualCadenceStepSec = 60;
const int kGradualCadenceDefaultSec = 180;

bool isValidGradualCadence(int seconds) =>
    seconds >= kGradualCadenceMinSec &&
    seconds <= kGradualCadenceMaxSec &&
    seconds % kGradualCadenceStepSec == 0;

// ── configuration / upgrade state ───────────────────────────────────────────

enum WakeConfiguration { neither, naturalOnly, gradualOnly, both }

WakeConfiguration wakeConfigurationOf({
  required int naturalMinutes,
  required int gradualMinutes,
}) {
  final n = naturalMinutes > 0, g = gradualMinutes > 0;
  if (n && g) return WakeConfiguration.both;
  if (n) return WakeConfiguration.naturalOnly;
  if (g) return WakeConfiguration.gradualOnly;
  return WakeConfiguration.neither;
}

/// Where a user stands on the Smart Wake -> Natural Wake change.
///
/// [pending]: they had Smart Wake on, the explanation has not been shown, and
/// estimated-REM behaviour must NOT run yet (the old light-sleep heuristic
/// keeps working until they acknowledge). [none]: nothing to explain.
enum WakeUpgradeState { none, pending, acknowledged }

// ── collection lead ─────────────────────────────────────────────────────────

/// The causal stager's own warm-up (40 usable 30 s epochs).
const int kNaturalWarmupMinutes = 20;

/// Slack so collection is already flowing, not just starting, when warm-up
/// must begin.
const int kNaturalCollectionMarginMinutes = 10;

/// How long before T high-frequency collection must be running so a stage
/// history exists by T-N: the window itself, plus warm-up, plus margin.
Duration naturalCollectionLead(int naturalMinutes) => Duration(
    minutes: naturalMinutes +
        kNaturalWarmupMinutes +
        kNaturalCollectionMarginMinutes);

// ── timeline ────────────────────────────────────────────────────────────────

class WakeTimelinePart {
  const WakeTimelinePart({
    required this.id,
    required this.at,
    required this.bandNative,
    required this.requiresPhone,
    this.until,
  });

  /// 'collection' | 'natural' | 'gradual' | 'fallback'.
  final String id;
  final DateTime at;
  final DateTime? until;

  /// Runs on the band alone, without the phone.
  final bool bandNative;

  /// Needs a connected phone running Edge.
  final bool requiresPhone;
}

/// The exact schedule for one wake, for the UI to draw and for tests to pin.
/// Offsets before T are ELAPSED time (a window crossing a DST change is N real
/// minutes, not N wall-clock minutes); T itself is the absolute instant the
/// local alarm schedule resolved to.
class WakeTimeline {
  const WakeTimeline._(
      this.wakeAt, this.naturalMinutes, this.gradualMinutes);

  factory WakeTimeline.compute({
    required DateTime wakeAt,
    required int naturalMinutes,
    required int gradualMinutes,
  }) =>
      WakeTimeline._(wakeAt, naturalMinutes, gradualMinutes);

  final DateTime wakeAt;
  final int naturalMinutes;
  final int gradualMinutes;

  WakeConfiguration get configuration => wakeConfigurationOf(
      naturalMinutes: naturalMinutes, gradualMinutes: gradualMinutes);

  DateTime? get naturalStart => naturalMinutes > 0
      ? wakeAt.subtract(Duration(minutes: naturalMinutes))
      : null;
  DateTime? get gradualStart => gradualMinutes > 0
      ? wakeAt.subtract(Duration(minutes: gradualMinutes))
      : null;
  DateTime? get collectionStart => naturalMinutes > 0
      ? wakeAt.subtract(naturalCollectionLead(naturalMinutes))
      : null;

  /// In time order. The 'fallback' part is always present.
  List<WakeTimelinePart> get parts {
    final out = <WakeTimelinePart>[
      if (collectionStart != null)
        WakeTimelinePart(
            id: 'collection',
            at: collectionStart!,
            until: wakeAt,
            bandNative: false,
            requiresPhone: true),
      if (naturalStart != null)
        WakeTimelinePart(
            id: 'natural',
            at: naturalStart!,
            until: wakeAt,
            bandNative: false,
            requiresPhone: true),
      if (gradualStart != null)
        WakeTimelinePart(
            id: 'gradual',
            at: gradualStart!,
            until: wakeAt,
            bandNative: false,
            requiresPhone: true),
      WakeTimelinePart(
          id: 'fallback', at: wakeAt, bandNative: true, requiresPhone: false),
    ];
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }
}

// ── Gradual schedule ────────────────────────────────────────────────────────

class GradualStep {
  const GradualStep(this.index, this.at, this.sequence);
  final int index;
  final DateTime at;
  final BuzzSequence sequence;
}

abstract final class GradualWakeSchedule {
  /// Gap between buzzes inside one escalated step.
  static const int _buzzGapMs = 600;
  static const int _maxBuzzes = 5;

  /// A step every [cadenceSec] from T-G, each strictly before T (the native
  /// alarm owns T). Empty when [windowMinutes] is 0.
  static List<GradualStep> steps({
    required DateTime wakeAt,
    required int windowMinutes,
    required int cadenceSec,
    required GradualPattern pattern,
  }) {
    if (windowMinutes <= 0 || cadenceSec <= 0) return const [];
    final start = wakeAt.subtract(Duration(minutes: windowMinutes));
    final total = windowMinutes * 60;
    final count = (total / cadenceSec).ceil();
    return [
      for (var i = 0; i < count; i++)
        GradualStep(
          i,
          start.add(Duration(seconds: i * cadenceSec)),
          BuzzSequence([
            for (var b = 0; b < _buzzesFor(pattern, i, count); b++) b * _buzzGapMs,
          ]),
        ),
    ];
  }

  static int _buzzesFor(GradualPattern pattern, int index, int count) =>
      pattern == GradualPattern.steady
          ? 1
          : 1 + (index * (_maxBuzzes - 1)) ~/ count;
}
