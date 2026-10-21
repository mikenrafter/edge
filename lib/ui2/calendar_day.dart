// The one shared calendar-date refresh for every header: it says when the
// LOCAL date changes (a timer to the next local midnight, and an app resume)
// so a date shown under a title, and the "Synced through" day comparison, are
// never a day stale. Owner of the timer: this class; headers only listen.
//
// The delay is wall-calendar arithmetic (local midnight minus now), never
// 86400 s: a DST day is 23 or 25 hours long. The timer runs only while
// something listens, and not while the app is in the background.
import 'dart:async';

import 'package:clock/clock.dart' as pc;
import 'package:flutter/widgets.dart';

import '../data/day_label.dart' show todayLabel;

class CalendarDay extends ChangeNotifier with WidgetsBindingObserver {
  CalendarDay._();
  static final instance = CalendarDay._();

  Timer? _timer;
  String? _id;

  /// Today's local day label, read from the clock now (not cached).
  String get todayId => todayLabel(pc.clock.now());

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_timer == null && _id == null) {
      _id = todayId;
      WidgetsBinding.instance.addObserver(this);
      _arm();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _stop();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _id = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// The wait until the next local midnight from [now]. Calendar arithmetic:
  /// `DateTime(y, m, d + 1)` is the next local midnight whatever the day's
  /// length.
  static Duration untilMidnight(DateTime now) =>
      DateTime(now.year, now.month, now.day + 1).difference(now);

  void _arm() {
    _timer?.cancel();
    _timer = Timer(untilMidnight(pc.clock.now()), _check);
  }

  void _check() {
    if (!hasListeners) return;
    final id = todayId;
    if (id != _id) {
      _id = id;
      notifyListeners();
    }
    _arm();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!hasListeners) return;
    if (state == AppLifecycleState.resumed) {
      _check();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }
}
