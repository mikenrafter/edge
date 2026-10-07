// gesture_slots.dart — gesture SLOTS and what is configured per slot.
//
// A slot is a gesture identity: the plain double tap and the counted taps
// (3..5 taps, by either counting method) each have one. The ids are stable and
// persisted (never rename): 'double', 'triple', 'quad', 'quint'. One mapping
// store serves both counting methods, so the slot for 3 taps is the slot for 2
// double taps.
//
// RED PHASE: the bodies below throw until the green phase implements them.

import 'time_buzz.dart';

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
  static String ofTaps(int taps) => throw UnimplementedError('GestureSlots.ofTaps');

  /// The tap count of [slot]; ArgumentError for an unknown slot.
  static int tapsOf(String slot) => throw UnimplementedError('GestureSlots.tapsOf');

  /// 'Double tap', 'Triple tap', 'Quadruple tap', 'Quintuple tap': what the
  /// overlap warning names a slot ("Also on Triple tap").
  static String nameOf(String slot) => throw UnimplementedError('GestureSlots.nameOf');
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

  final Map<String, String> values;

  /// The slot's OWN Tell the time mode; null when it has none (it follows the
  /// global default).
  TimeBuzzMode? get timeBuzzMode =>
      throw UnimplementedError('GestureSlotOptions.timeBuzzMode');
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
