// gesture_slots.dart — gesture SLOTS and what is configured per slot.
//
// A slot is a gesture identity: the plain double tap and the counted taps
// (3..5 taps, by either counting method) each have one. The ids are stable and
// persisted (never rename): 'double', 'triple', 'quad', 'quint'. One mapping
// store serves both counting methods, so the slot for 3 taps is the slot for 2
// double taps.
//
import 'time_buzz.dart';

/// Breathing exercise: the session lengths a slot can pick (minutes), the
/// default length and the default pattern (`BreathPattern.key`).
const List<int> kBreatheMinuteChoices = [1, 2, 3, 5, 10];
const int kBreatheDefaultMinutes = 3;
const String kBreatheDefaultPattern = 'resonance';

abstract final class GestureSlots {
  static const String doubleTap = 'double';
  static const String tripleTap = 'triple';
  static const String quadTap = 'quad';
  static const String quintTap = 'quint';

  /// Tap-count order (2..5).
  static const List<String> all = [doubleTap, tripleTap, quadTap, quintTap];

  /// The only slot ECG-on-double-tap can occupy.
  static const String ecgSlot = doubleTap;

  /// The slot for [taps] taps, 2..5; ArgumentError otherwise.
  static String ofTaps(int taps) {
    if (taps < 2 || taps > 5) {
      throw ArgumentError.value(taps, 'taps', 'must be 2..5');
    }
    return all[taps - 2];
  }

  /// The tap count of [slot]; ArgumentError for an unknown slot.
  static int tapsOf(String slot) {
    final i = all.indexOf(slot);
    if (i < 0) throw ArgumentError.value(slot, 'slot', 'unknown gesture slot');
    return i + 2;
  }

  /// 'Double tap', 'Triple tap', 'Quadruple tap', 'Quintuple tap': what the
  /// overlap warning names a slot ("Also on Triple tap").
  static String nameOf(String slot) => switch (tapsOf(slot)) {
        2 => 'Double tap',
        3 => 'Triple tap',
        4 => 'Quadruple tap',
        _ => 'Quintuple tap',
      };
}

/// Per-slot, per-action options, keyed by stable `<action id>.<option id>`
/// strings (so an option can be added without a schema change). An absent key
/// means "follow the default" (for Tell the time's mode, the global
/// `gesture_time_buzz_mode`).
///
/// Persisted per slot as a JSON object string under
/// `gesture_slot_options_<slot id>`, e.g.
/// `{"tell_time.mode":"binary"}`; a slot with no options has no key.
class GestureSlotOptions {
  const GestureSlotOptions([this.values = const {}]);

  /// Tell the time's encoding for the slot: the mode's name ('count',
  /// 'binary', 'morse').
  static const String kTellTimeMode = 'tell_time.mode';

  /// Breathing exercise's pattern (`BreathPattern.key`) and length (whole
  /// minutes, as a string) for the slot.
  static const String kBreathePattern = 'breathe.pattern';
  static const String kBreatheMinutes = 'breathe.minutes';

  final Map<String, String> values;

  /// The slot's OWN Tell the time mode; null when it has none (it follows the
  /// global default).
  TimeBuzzMode? get timeBuzzMode {
    final name = values[kTellTimeMode];
    for (final m in TimeBuzzMode.values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// What [GestureSettings.trySetAction] / `trySetEcgOnDoubleTap` answered.
sealed class ActionToggleResult {
  const ActionToggleResult();

  bool get ok => this is ActionToggleOk;
}

/// Done (or already so).
class ActionToggleOk extends ActionToggleResult {
  const ActionToggleOk();
}

/// Refused and nothing changed: an active mode (ECG) cannot share a slot with
/// another action. [reason] is the text the UI shows.
class ActionToggleRefusedExclusive extends ActionToggleResult {
  const ActionToggleRefusedExclusive(this.reason);
  final String reason;
}

/// Turning ECG on for a slot that already has other actions.
const String kEcgExclusiveTurnOthersOff =
    "ECG takes over the band while it records, so it can't share a gesture "
    'with other actions. Turn the others off first.';

/// Turning another action on for a slot that has ECG.
const String kEcgExclusiveTurnEcgOff =
    "ECG takes over the band while it records, so it can't share a gesture "
    'with other actions. Turn ECG off first.';

/// Shown in the double tap's tab for a user who already has ECG on AND actions
/// mapped (their stored config is left alone): only ECG runs there.
const String kEcgOnlyRunsNote =
    'Only ECG runs on this gesture, so the actions below are paused. ECG takes '
    "over the band while it records, so it can't share a gesture with other "
    'actions. Turn the others off first.';
