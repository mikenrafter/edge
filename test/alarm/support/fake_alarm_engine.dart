// A BleEngine that only counts alarm writes, for driving the REAL AppState arm
// path (single flight, grace retry, early event 56) without a radio.

import 'package:openstrap_edge/ble/ble_engine.dart';

class FakeAlarmEngine extends BleEngine {
  FakeAlarmEngine() : super(onRecord: (_, _) async {}, onState: (_) {}) {
    state.connection = 'connected';
  }

  /// Every SET_ALARM that went out, in order.
  final List<DateTime> sets = [];
  int disables = 0;

  /// Writes in progress right now, and the most there ever were at once.
  int inFlight = 0, maxInFlight = 0;

  /// Runs while the write is "on the wire"; a test holds it to interleave.
  Future<void> Function(DateTime when, int index)? onSet;

  /// The band refuses the alarm (null reply).
  bool refuse = false;

  /// Refuse only the n-th write (1-based).
  bool Function(int n)? refuseIf;

  List<int> get setEpochs => [
    for (final w in sets) w.millisecondsSinceEpoch ~/ 1000,
  ];

  @override
  Future<DateTime?> setAlarm(
    DateTime when, {
    int index = 0,
    List<int>? haptics,
  }) async {
    sets.add(when);
    final n = sets.length;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await onSet?.call(when, n);
    } finally {
      inFlight--;
    }
    return refuse || (refuseIf?.call(n) ?? false) ? null : when;
  }

  @override
  Future<void> disableAlarm({int? id}) async => disables++;
}
