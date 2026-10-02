// lab_log.dart — what the Device lab remembers: band events with both clocks,
// and the ECG tap counter's step-by-step trace. RAM only, bounded, never
// persisted (nothing here is a measurement).

import 'package:flutter/foundation.dart';

import 'device_action.dart';
import 'gesture_dispatcher.dart';
import 'strap_event.dart';

/// One band event as the lab shows it: when it happened (the band's clock when
/// believable), when the phone got it, and which actions ran.
class DeviceLabEntry {
  const DeviceLabEntry({
    required this.eventId,
    required this.eventTime,
    required this.receivedAt,
    required this.live,
    this.actions = const [],
  });

  factory DeviceLabEntry.fromEvent(StrapEvent e,
          {List<GestureOutcome> outcomes = const []}) =>
      DeviceLabEntry(
        eventId: e.eventId,
        eventTime: e.effectiveTime,
        receivedAt: e.receivedAt,
        live: e.isLive,
        actions: [
          for (final o in outcomes)
            if (o.status == GestureStatus.ran) o.action.id,
        ],
      );

  final int eventId;
  final DateTime eventTime;
  final DateTime receivedAt;
  final bool live;

  /// Ids of the actions that ran for this event.
  final List<String> actions;

  Duration get delay => receivedAt.difference(eventTime);

  /// Seconds to a tenth: "1.2 s".
  String get delayLabel =>
      '${(delay.inMilliseconds / 1000).toStringAsFixed(1)} s';
}

/// Local `HH:mm:ss.SSS`.
String labClock(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}.'
      '${l.millisecond.toString().padLeft(3, '0')}';
}

/// The newest-first rolling log the Device lab screen reads.
class DeviceLabLog extends ChangeNotifier {
  static const int maxEntries = 60;
  static const int maxSteps = 120;

  final List<DeviceLabEntry> _entries = [];
  final List<String> _steps = [];

  /// Newest first.
  List<DeviceLabEntry> get entries => List.unmodifiable(_entries);

  /// Newest first, each already prefixed with its clock time.
  List<String> get steps => List.unmodifiable(_steps);

  void addEntry(DeviceLabEntry e) {
    _entries.insert(0, e);
    if (_entries.length > maxEntries) _entries.removeLast();
    notifyListeners();
  }

  void addStep(String line, {DateTime? at}) {
    _steps.insert(0, '${labClock(at ?? DateTime.now())}  $line');
    if (_steps.length > maxSteps) _steps.removeLast();
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    _steps.clear();
    notifyListeners();
  }
}
