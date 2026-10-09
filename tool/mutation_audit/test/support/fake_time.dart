import 'dart:async';

import 'package:mutation_audit/mutation_audit.dart';

/// Wall clock and timers that move only when a test says so: `now` is the
/// injected clock, [alarm] the injected timer, [advance] lets time pass and
/// fires every alarm that falls due on the way, in order.
class FakeTime {
  FakeTime([DateTime? start]) : _now = start ?? DateTime.utc(2026, 10, 9, 8);

  DateTime _now;
  final List<_Alarm> _alarms = [];

  DateTime now() => _now;

  /// Alarms set and neither fired nor cancelled.
  int get pending => _alarms.where((a) => !a.settled).length;

  Alarm alarm(Duration after) {
    final a = _Alarm(_now.add(after));
    _alarms.add(a);
    return a;
  }

  /// Moves the clock forward by [by]; alarms due on the way fire at their own
  /// moment (the clock reads that moment while they run) and the listeners
  /// get to run before time moves on.
  Future<void> advance(Duration by) async {
    final target = _now.add(by);
    while (true) {
      final due = _alarms.where((a) => !a.settled && !a.due.isAfter(target)).toList()
        ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      _now = due.first.due;
      due.first.fire();
      await settle();
    }
    _now = target;
    await settle();
  }
}

/// Lets scheduled microtasks and zero timers run.
Future<void> settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Alarm implements Alarm {
  _Alarm(this.due);
  final DateTime due;
  final Completer<void> _c = Completer<void>();
  bool settled = false;

  @override
  Future<void> get fired => _c.future;

  void fire() {
    if (settled) return;
    settled = true;
    _c.complete();
  }

  @override
  void cancel() => settled = true;
}
