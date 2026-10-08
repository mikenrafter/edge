// water_buzzer.dart — fires a strap haptic alongside the hydration reminder.
//
// The reminder is TWO things and this is the weaker half. The OS-scheduled
// notification (armed in NotificationCenter._armWaterSlots) fires even when the
// app is dead; a strap buzz needs a live BLE link AND a live Dart isolate — you
// can't buzz a band that isn't connected. So this is BEST-EFFORT: an in-memory
// timer (re-armed every app launch, since timers don't persist) that fires at
// each hydration slot and buzzes ONLY if the band is connected. A missed buzz
// costs nothing, because the notification is what actually reminds.
//
// Slot times come verbatim from NotificationCenter.waterSlotMinutes(), the same
// list the notification is armed from, so the two land at the same wall-clock
// minute.

import 'dart:async';

import 'alert_dispatcher.dart';
import 'alert_rule.dart';
import 'notification_prefs.dart';

class WaterBuzzer {
  WaterBuzzer({
    required this.buzz,
    required this.isConnected,
    AlertDispatcher? dispatcher,
    this.onSlot,
  }) : _legacyTransport = dispatcher == null,
       dispatcher =
           dispatcher ??
           AlertDispatcher(
             phone: () async => false,
             band: () async {
               await buzz();
               return true;
             },
             isConnected: isConnected,
             ledger: MemoryAlertDeliveryLedger(),
           );

  final bool _legacyTransport;
  bool _disposed = false;
  final AlertDispatcher dispatcher;

  /// Sends one short haptic to the strap (no-op if the link isn't ready).
  final Future<void> Function() buzz;

  /// Called at every hydration slot, connected or not, before the strap buzz
  /// and shielded from its failures. This is where an assumed glass is logged.
  final Future<void> Function(DateTime slot)? onSlot;

  /// Whether the strap is currently connected (checked lazily at fire time).
  final bool Function() isConnected;

  Timer? _timer;
  DateTime? _sourceTime;
  bool _enabled = false;
  List<int> _slots = const []; // minutes-from-midnight, ascending

  /// (Re)configure from the current prefs. Idempotent — cancels and re-arms.
  /// Pass `NotificationCenter.waterSlotMinutes(prefs)` as [slotMinutes].
  void configure({required bool enabled, required List<int> slotMinutes}) {
    _enabled = enabled;
    _slots = List<int>.from(slotMinutes)..sort();
    _reschedule();
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return;
    if (!_enabled || _slots.isEmpty) return;

    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;

    // Resolve local calendar time so DST days do not acquire a fixed 24-hour
    // delay. The source instant stays attached to this scheduled occurrence.
    final later = _slots.where((slot) => slot > nowMin);
    final slot = later.isEmpty ? _slots.first : later.first;
    _sourceTime = DateTime(
      now.year,
      now.month,
      now.day + (later.isEmpty ? 1 : 0),
      slot ~/ 60,
      slot % 60,
    );
    final delay = _sourceTime!.difference(now);
    _timer = Timer(delay, _fire);
  }

  Future<void> _fire() async {
    final sourceTime = _sourceTime ?? DateTime.now();
    if (_enabled) {
      try {
        await onSlot?.call(sourceTime);
      } catch (_) {
        /* a failed log must not stop the buzz or the next slot */
      }
    }
    if (_enabled && isConnected()) {
      try {
        final rule = _legacyTransport
            ? const AlertRule(
                id: 'water',
                kind: 'water',
                destinations: 2,
                executionMode: AlertExecutionMode.phoneLive,
                channelPolicyId: 'water',
              )
            : (await NotificationPrefs.load()).alertRule('water');
        await dispatcher.dispatch(
          rule,
          eventId: 'water:${sourceTime.millisecondsSinceEpoch}',
          sourceTime: sourceTime,
          historical: false,
          transportTargets: const {'band'},
        );
      } catch (_) {
        /* link dropped mid-write — best effort */
      }
    }
    _reschedule(); // arm the next slot
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
