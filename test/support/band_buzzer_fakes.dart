import 'dart:async';

import 'package:clock/clock.dart';
import 'package:openstrap_edge/ble/band_buzzer.dart';
import 'package:openstrap_edge/ble/default_band_buzzer.dart';

class WakeClock {
  WakeClock(this.at);
  DateTime at;
  final gaps = <Duration>[];
  DateTime now() => at;
  Future<void> delay(Duration gap) async {
    gaps.add(gap);
    at = at.add(gap);
  }
  Future<T> run<T>(Future<T> Function() action) =>
      withClock(Clock(now), action);
}

class WakeTransport implements BandBuzzTransport {
  WakeTransport(this.clock);
  final WakeClock clock;
  final writes = <({String kind, DateTime at})>[];
  final replies = <Object>[];
  Completer<bool>? held;
  final entered = Completer<void>();
  int active = 0;
  int maxActive = 0;

  Future<bool> _write(String kind) async {
    writes.add((kind: kind, at: clock.now()));
    if (!entered.isCompleted) entered.complete();
    active++;
    if (active > maxActive) maxActive = active;
    try {
      final hold = held;
      held = null;
      if (hold != null) return await hold.future;
      final reply = replies.isEmpty ? true : replies.removeAt(0);
      if (reply is bool) return reply;
      throw reply;
    } finally {
      active--;
    }
  }

  @override
  Future<bool> runAlarmChecked() => _write('alarm');
  @override
  Future<bool> buzzChecked() => _write('pulse');

  DefaultBandBuzzer buzzer() => DefaultBandBuzzer(
      transport: this, now: clock.now, delay: clock.delay);
}

// Drain only microtasks; held-write tests never wait on wall-clock timers.
Future<void> wakeMicrotasks() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.value();
  }
}
